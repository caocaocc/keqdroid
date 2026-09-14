import 'dart:io';
import 'desktop_capabilities.dart';

import 'package:flutter/foundation.dart';

import '../services/desktop_background_service.dart';
import '../services/windows_desktop_service.dart';

/// Platform init before runApp (Windows desktop shell).
class PlatformBootstrap {
  static Future<void> initialize() async {
    if (Platform.isWindows) {
      await WindowsDesktopService.initCoreProcessGuard();
      await DesktopBackgroundService.init();
    }
  }

  /// Тесты гоняются на Windows, и без подмены раскладку телефона там не
  /// проверить.
  @visibleForTesting
  static bool? debugIsDesktopOverride;

  static bool get isDesktop =>
      debugIsDesktopOverride ??
      DesktopCapabilities.current.isDesktop;
}
