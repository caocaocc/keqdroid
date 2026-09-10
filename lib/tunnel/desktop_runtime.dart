import 'dart:io';

import '../utils/mihomo_api_session.dart';
import 'linux_tunnel_backend.dart';
import 'macos_tunnel_backend.dart';
import 'windows_tunnel_backend.dart';

/// Сервисы читают координаты живого runtime, не выбирая чужой backend
/// по правилу «не Windows значит Linux».
class DesktopRuntime {
  DesktopRuntime._();

  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static int? get clashApiPort {
    if (Platform.isWindows) {
      return WindowsTunnelBackend.activeInstance?.clashApiPort;
    }
    if (Platform.isLinux) {
      return LinuxTunnelBackend.activeInstance?.clashApiPort;
    }
    if (Platform.isMacOS) {
      return MacOSTunnelBackend.activeInstance?.clashApiPort;
    }
    return null;
  }

  static String get clashApiSecret => Platform.isMacOS
      ? MacOSTunnelBackend.activeInstance?.clashApiSecret ?? ''
      : MihomoApiSession().secret;

  static Map<String, int> get corePids {
    if (Platform.isWindows) {
      return WindowsTunnelBackend.activeInstance?.activeCorePids ?? const {};
    }
    if (Platform.isLinux) {
      return LinuxTunnelBackend.activeInstance?.activeCorePids ?? const {};
    }
    if (Platform.isMacOS) {
      return MacOSTunnelBackend.activeInstance?.activeCorePids ?? const {};
    }
    return const {};
  }
}
