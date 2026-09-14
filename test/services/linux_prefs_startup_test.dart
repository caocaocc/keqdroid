import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/core/app_logger.dart';
import 'package:keqdroid/main.dart' as app;
import 'package:keqdroid/services/desktop_background_service.dart';
import 'package:keqdroid/services/linux_background_service.dart';
// Use path_provider's already locked test interface to also intercept the
// Linux Dart/XDG implementation, not only its MethodChannel fallback.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  final String supportPath;
  _TestPaths(this.supportPath);

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

class _PrimarySocket extends Fake implements Socket {
  final List<String> messages;
  _PrimarySocket(this.messages);

  @override
  void add(List<int> data) => messages.add(utf8.decode(data));

  @override
  Future<void> flush() async {}

  @override
  void destroy() {}
}

void _expectPrimaryAddress(dynamic address, int port) {
  expect(address, isA<InternetAddress>());
  expect((address as InternetAddress).type, InternetAddressType.unix);
  expect(address.address, startsWith('@keqdroid-'));
  expect(port, 0);
}

Future<ServerSocket> _primaryLockHeld(
  dynamic address,
  int port, {
  int backlog = 0,
  bool v6Only = false,
  bool shared = false,
}) async {
  _expectPrimaryAddress(address, port);
  expect(shared, isFalse);
  throw const SocketException(
    'The primary instance holds the lock',
    osError: OSError('Address already in use', 98),
  );
}

class _InterceptedExit implements Exception {
  @override
  String toString() => 'Intercepted Linux secondary exit';
}

// Run the actual entrypoint through its secondary-instance exit. Only the
// socket lock and process exit are replaced; recovery uses real files. Timers
// scheduled by desktop background startup are cancelled before teardown.
Future<void> _startSecondary(List<String> messages, File log) async {
  final exited = Completer<int>();
  final timers = <Timer>[];
  var bindAttempts = 0;
  runZoned(
    () => IOOverrides.runZoned(
      () => unawaited(app.main()),
      serverSocketBind:
          (
            dynamic address,
            int port, {
            int backlog = 0,
            bool v6Only = false,
            bool shared = false,
          }) async {
            bindAttempts++;
            return _primaryLockHeld(
              address,
              port,
              backlog: backlog,
              v6Only: v6Only,
              shared: shared,
            );
          },
      socketConnect:
          (
            dynamic address,
            int port, {
            dynamic sourceAddress,
            int sourcePort = 0,
            Duration? timeout,
          }) async {
            _expectPrimaryAddress(address, port);
            return _PrimarySocket(messages);
          },
      exit: (code) {
        exited.complete(code);
        throw _InterceptedExit();
      },
    ),
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = parent.createTimer(zone, duration, callback);
        timers.add(timer);
        return timer;
      },
      createPeriodicTimer: (self, parent, zone, duration, callback) {
        final timer = parent.createPeriodicTimer(zone, duration, callback);
        timers.add(timer);
        return timer;
      },
    ),
  );
  try {
    expect(await exited.future.timeout(const Duration(seconds: 5)), 0);
    // main's own guarded zone consumes the exit sentinel. Drain its error
    // handler before deleting the log or starting another entrypoint.
    await Future<void>.delayed(Duration.zero);
    expect(
      log.readAsStringSync(),
      contains('Intercepted Linux secondary exit'),
    );
    expect(bindAttempts, 1);
    expect(messages, ['show']);
  } finally {
    DesktopBackgroundService.dispose();
    for (final timer in timers) {
      timer.cancel();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const previous = '{"flutter.keqdis_settings":"previous"}';
  const latest = '{"flutter.keqdis_settings":"latest-primary-write"}';
  late Directory directory;
  late File prefs;
  late File backup;
  late File log;
  late PathProviderPlatform originalPaths;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('linux_prefs_startup');
    prefs = File('${directory.path}/shared_preferences.json');
    backup = File('${directory.path}/shared_preferences.backup.json');
    log = File('${directory.path}/app.log');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    AppLogger.instance.enableFileLogIn(directory);
  });
  tearDown(() {
    PathProviderPlatform.instance = originalPaths;
    // AppLogger owns a File path, not an open handle. Leave its sink inside
    // this removed test directory; a late append is caught by the logger.
    AppLogger.instance.enableFileLogIn(Directory('${directory.path}/removed'));
    directory.deleteSync(recursive: true);
  });

  test('Linux secondary instance forwards through the per-user Unix lock', () async {
    final messages = <String>[];
    final primary = await IOOverrides.runZoned(
      () => LinuxBackgroundService.instance.ensureSingleInstance(),
      serverSocketBind: _primaryLockHeld,
      socketConnect: (
        dynamic address,
        int port, {
        dynamic sourceAddress,
        int sourcePort = 0,
        Duration? timeout,
      }) async {
        _expectPrimaryAddress(address, port);
        return _PrimarySocket(messages);
      },
    );
    expect(primary, isFalse);
    expect(messages, ['show']);
  });

  // Platform.isLinux in the real main is intentional: Linux CI runs these;
  // changing Flutter's target platform would not exercise its startup branch.
  test(
    'secondary startup leaves a healthy settings backup untouched',
    () async {
      prefs.writeAsStringSync(latest);
      backup.writeAsStringSync(previous);

      await _startSecondary([], log);

      expect(prefs.readAsStringSync(), latest);
      expect(backup.readAsStringSync(), previous);
      expect(File('${backup.path}.tmp').existsSync(), isFalse);
    },
    skip: !Platform.isLinux,
  );

  for (final hasBackup in [false, true]) {
    test(
      'secondary startup preserves an in-flight settings write (backup: $hasBackup)',
      () async {
        prefs.writeAsStringSync(previous);
        if (hasBackup) backup.writeAsStringSync(previous);
        // The Linux plugin writes in place. Pause it after truncation, keeping
        // the descriptor open while another instance reaches main(). Repair
        // must not unlink the file: that would strand this write on the old
        // inode and leave a stale restored backup (or no pathname at all).
        final writing = prefs.openSync(mode: FileMode.write);
        try {
          expect(prefs.lengthSync(), 0);
          await _startSecondary([], log);
          expect(prefs.existsSync(), isTrue);
          expect(prefs.lengthSync(), 0);
          expect(backup.existsSync(), hasBackup);
          if (hasBackup) expect(backup.readAsStringSync(), previous);
          writing.writeStringSync(latest);
          writing.flushSync();
          expect(prefs.readAsStringSync(), latest);
        } finally {
          writing.closeSync();
        }
      },
      skip: !Platform.isLinux,
    );
  }
}
