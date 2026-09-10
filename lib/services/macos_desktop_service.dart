import 'dart:io';

import 'package:flutter/services.dart';

import '../models/app_settings.dart';

class MacOSDesktopService {
  MacOSDesktopService._();

  static const channel = MethodChannel('keqdis_vpn_channel');

  static Future<void> initialize() async {
    if (Platform.isMacOS) await channel.invokeMethod<void>('initializeDesktop');
  }

  static Future<void> applySettings(
    AppSettings settings, {
    bool updateLoginItem = false,
  }) async {
    if (!Platform.isMacOS) return;
    await channel.invokeMethod<void>('applyDesktopSettings', {
      'minimizeToTray': settings.minimizeToTray,
      if (updateLoginItem) 'launchAtStartup': settings.launchAtStartup,
    });
  }

  static Future<bool> isAutostartLaunch() async =>
      await channel.invokeMethod<bool>('isAutostartLaunch') ?? false;

  static Future<Map<String, dynamic>> loginStatus() async =>
      await channel.invokeMapMethod<String, dynamic>('getLoginStatus') ?? {};

  static Future<void> toggleWindow() =>
      channel.invokeMethod<void>('toggleWindow');

  static Future<void> completeQuit() =>
      channel.invokeMethod<void>('completeQuit');

  static Future<void> quitAfter(Future<void> Function()? cleanup) async {
    try {
      await cleanup?.call();
      await completeQuit();
    } catch (_) {
      await channel.invokeMethod<void>('cancelQuit');
      rethrow;
    }
  }
}
