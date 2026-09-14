import 'dart:io';
import 'desktop_capabilities.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/desktop_background_service.dart';
import '../services/windows_desktop_service.dart';

class PlatformBootstrap {
  static Future<void> initialize() async {
    if (Platform.isWindows) {
      await WindowsDesktopService.initCoreProcessGuard();
      await DesktopBackgroundService.init();
    }
    if (Platform.isAndroid) {
      try {
        _isTelevision = await const MethodChannel('keqdis_vpn_channel')
                .invokeMethod<bool>('isTelevision') ??
            false;
      } on PlatformException {
        _isTelevision = false;
      }
    }
  }

  @visibleForTesting
  static bool? debugIsDesktopOverride;

  static bool get isDesktop =>
      debugIsDesktopOverride ??
      DesktopCapabilities.current.isDesktop;

  static bool _isTelevision = false;

  @visibleForTesting
  static bool? debugIsTelevisionOverride;

  static bool get isTelevision => debugIsTelevisionOverride ?? _isTelevision;
}
