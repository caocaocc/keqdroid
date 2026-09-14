import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/macos_app_routing.dart';
import 'package:keqdroid/services/macos_app_routing_store.dart';
import 'package:keqdroid/tunnel/app_routing_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'native entries preserve helper paths and round-trip independently',
    () async {
      const main = '/Applications/Chat.app/Contents/MacOS/Chat';
      const helper =
          '/Applications/Chat.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper';
      final entry = MacOSAppEntry.fromNative({
        'packageName': main,
        'appName': 'Chat',
        'bundlePath': '/Applications/Chat.app',
        'bundleId': 'example.chat',
        'executablePaths': [main, helper],
      });
      await MacOSAppRoutingStore.save(
        MacOSAppRoutingSettings(
          mode: AppRoutingMode.onlySelected,
          apps: [entry],
        ),
      );
      final loaded = await MacOSAppRoutingStore.load();
      expect(loaded.mode, AppRoutingMode.onlySelected);
      expect(loaded.processPaths, [main, helper]);
      expect(loaded.processPaths, isNot(contains('example.chat')));
    },
  );

  test('invalid paths and corrupted settings fail closed', () async {
    expect(
      isMacOSExecutablePath('/Applications/Firefox.app/Contents/MacOS/firefox'),
      isTrue,
    );
    for (final path in ['relative', '/tmp/../Applications/App', '/tmp/a,b']) {
      expect(
        () => MacOSAppEntry.fromNative({'packageName': path}),
        throwsFormatException,
      );
    }
    expect(
      () => MacOSAppEntry.fromNative({
        'packageName': '/Applications/Chat.app/Contents/MacOS/Chat',
        'bundlePath': '/Applications/Chat.app',
        'executablePaths': ['/Applications/Other.app/Contents/MacOS/Other'],
      }),
      throwsFormatException,
    );
    SharedPreferences.setMockInitialValues({
      MacOSAppRoutingStore.storageKey: '{broken',
    });
    await expectLater(MacOSAppRoutingStore.load(), throwsFormatException);
  });

  test(
    'updated bundles refresh helper paths and missing apps are rejected',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'macos_app_paths_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final bundle = '${temp.path}/Chat.app';
      final main = File('$bundle/Contents/MacOS/Chat');
      final helper = File(
        '$bundle/Contents/XPCServices/Search.xpc/Contents/MacOS/Search',
      );
      await main.parent.create(recursive: true);
      await helper.parent.create(recursive: true);
      await main.writeAsString('fixture');
      await helper.writeAsString('fixture');
      final old = MacOSAppEntry.fromNative({
        'packageName': main.path,
        'bundlePath': bundle,
      });
      final settings = MacOSAppRoutingSettings(
        mode: AppRoutingMode.allExceptSelected,
        apps: [old],
      );
      expect(
        await MacOSAppRoutingStore.resolvePaths(settings, [
          {
            'packageName': main.path,
            'bundlePath': bundle,
            'executablePaths': [main.path, helper.path],
          },
        ]),
        [main.path, helper.path],
      );
      await main.delete();
      await expectLater(
        MacOSAppRoutingStore.resolvePaths(settings, []),
        throwsFormatException,
      );
    },
  );
}
