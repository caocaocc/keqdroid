import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/platform/desktop_capabilities.dart';

void main() {
  test('Mac exposes implemented integrations and excludes LAN listeners', () {
    final mac = DesktopCapabilities.forPlatform('macos');
    expect(
      mac.isDesktop &&
          mac.tun &&
          mac.applicationRouting &&
          mac.globalHotkeys &&
          mac.loginStartup,
      isTrue,
    );
    expect(mac.lanSharing, isFalse);
  });
  test('desktop additions preserve mobile and Linux capability boundaries', () {
    expect(DesktopCapabilities.forPlatform('android').isDesktop, isFalse);
    expect(DesktopCapabilities.forPlatform('ios').loginStartup, isFalse);
    expect(DesktopCapabilities.forPlatform('linux').globalHotkeys, isFalse);
    expect(DesktopCapabilities.forPlatform('windows').globalHotkeys, isTrue);
  });
}
