import 'dart:io';

/// OS integration capabilities, independent of the selected proxy protocol.
class DesktopCapabilities {
  final bool isDesktop;
  final bool tun;
  final bool applicationRouting;
  final bool globalHotkeys;
  final bool loginStartup;
  final bool lanSharing;

  const DesktopCapabilities({
    this.isDesktop = false,
    this.tun = false,
    this.applicationRouting = false,
    this.globalHotkeys = false,
    this.loginStartup = false,
    this.lanSharing = false,
  });

  static DesktopCapabilities get current =>
      forPlatform(Platform.operatingSystem);

  static DesktopCapabilities forPlatform(String platform) => switch (platform) {
    'macos' => const DesktopCapabilities(
      isDesktop: true,
      tun: true,
      applicationRouting: true,
      globalHotkeys: true,
      loginStartup: true,
      lanSharing: true,
    ),
    'windows' => const DesktopCapabilities(
      isDesktop: true,
      tun: true,
      applicationRouting: true,
      globalHotkeys: true,
      loginStartup: true,
      lanSharing: true,
    ),
    'linux' => const DesktopCapabilities(
      isDesktop: true,
      tun: true,
      applicationRouting: true,
      lanSharing: true,
    ),
    _ => const DesktopCapabilities(),
  };
}
