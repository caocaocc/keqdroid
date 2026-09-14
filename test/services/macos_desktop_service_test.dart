import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/macos_desktop_service.dart';
import 'package:keqdroid/platform/vpn_native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacOSDesktopService.channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacOSDesktopService.channel, null),
  );

  test(
    'desktop commands and shared native bridge reach the Runner channel',
    () async {
      final runner = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      final channelName = RegExp(
        r'let desktopChannel = FlutterMethodChannel\(name: "([^"]+)"',
      ).firstMatch(runner)?.group(1);
      expect(channelName, VpnNativeBridge.channel.name);
      expect(MacOSDesktopService.channel.name, channelName);
      await VpnNativeBridge.channel.invokeMethod<void>('getPendingDeepLink');
      await MacOSDesktopService.showWindow();
      expect(calls, ['getPendingDeepLink', 'showWindow']);
    },
  );

  test('quit waits for cleanup before confirming native termination', () async {
    await MacOSDesktopService.quitAfter(() async {
      calls.add('networkRestored');
    });
    expect(calls, ['networkRestored', 'completeQuit']);
  });
  test(
    'failed restoration cancels termination and preserves the error',
    () async {
      await expectLater(
        MacOSDesktopService.quitAfter(() async {
          throw PlatformException(code: 'recoveryRequired');
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, ['cancelQuit']);
    },
  );
}
