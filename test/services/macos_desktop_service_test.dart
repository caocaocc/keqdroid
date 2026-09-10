import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/macos_desktop_service.dart';

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
