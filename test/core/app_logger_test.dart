import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/core/app_logger.dart';

/// На десктопе файл лога — единственный след поломки: Crashlytics только под
/// Android, а developer.log в релизе не видно нигде.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  File log() => File('${dir.path}${Platform.pathSeparator}app.log');
  File rotated() => File('${log().path}.1');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('app_logger');
    AppLogger.instance.enableFileLogIn(dir);
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('пишет строку на диск и маскирует секреты', () {
    AppLogger.instance.error(
      'Subscription failed',
      error: 'https://panel.example/sub/abcdefghijklmnop0123',
    );

    final text = log().readAsStringSync();
    expect(text, contains('[ERROR] Subscription failed'));
    expect(text, contains('***'));
    expect(text, isNot(contains('abcdefghijklmnop0123')));
  });

  test('на старте уводит переросший лог в app.log.1', () {
    log().writeAsStringSync('x' * (256 * 1024 + 1));

    AppLogger.instance.enableFileLogIn(dir);
    AppLogger.instance.info('after rotation');

    expect(rotated().lengthSync(), 256 * 1024 + 1);
    expect(log().readAsStringSync(), contains('after rotation'));
  });

  test('журнал читается вместе с прошлой половиной, старое первым', () async {
    rotated().writeAsStringSync('older line\n');
    AppLogger.instance.info('newer line');

    final text = await AppLogger.instance.readFileLog();
    expect(text.indexOf('older line'), lessThan(text.indexOf('newer line')));
  });

  test('из длинного журнала читается хвост', () async {
    AppLogger.instance.info('head ${'x' * 100}');
    AppLogger.instance.info('tail');

    final text = await AppLogger.instance.readFileLog(maxChars: 50);
    expect(text.length, 50);
    expect(text, contains('tail'));
    expect(text, isNot(contains('head')));
  });

  test('недоступный файл логгер переживает молча', () {
    dir.deleteSync(recursive: true);

    expect(() => AppLogger.instance.warn('no disk'), returnsNormally);
  });

  test('macOS startup opens the application support log', () async {
    final support = Directory('${dir.path}/support')..createSync();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async =>
        call.method == 'getApplicationSupportDirectory' ? support.path : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await AppLogger.instance.enableFileLog();
    AppLogger.instance.info('macOS startup');

    expect(File('${support.path}/app.log').readAsStringSync(),
        contains('[INFO] macOS startup'));
    expect(await AppLogger.instance.readFileLog(), contains('macOS startup'));
  }, skip: !Platform.isMacOS);
}
