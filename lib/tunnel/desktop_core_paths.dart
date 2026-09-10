import 'dart:io';

import 'linux_core_paths.dart';
import 'macos_core_paths.dart';
import 'windows_core_paths.dart';

/// Одно разрешение desktop runtime для пинга, geo и диагностики.
class DesktopCorePaths {
  DesktopCorePaths._();

  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Future<String?> keqrnelExecutable() {
    if (Platform.isWindows) return WindowsCorePaths.keqrnelExecutable();
    if (Platform.isLinux) return LinuxCorePaths.keqrnelExecutable();
    if (Platform.isMacOS) return MacOSCorePaths.keqrnelExecutable();
    return Future.value(null);
  }

  static Future<String?> mihomoExecutable() {
    if (Platform.isWindows) return WindowsCorePaths.mihomoExecutable();
    if (Platform.isLinux) return LinuxCorePaths.mihomoExecutable();
    if (Platform.isMacOS) return MacOSCorePaths.mihomoExecutable();
    return Future.value(null);
  }

  static Future<String?> wireproxyExecutable() {
    if (Platform.isWindows) return WindowsCorePaths.wireproxyExecutable();
    if (Platform.isLinux) return LinuxCorePaths.wireproxyExecutable();
    if (Platform.isMacOS) return MacOSCorePaths.wireproxyExecutable();
    return Future.value(null);
  }

  static Future<String?> geoAssetDir() {
    if (Platform.isWindows) return WindowsCorePaths.geoAssetDir();
    if (Platform.isLinux) return LinuxCorePaths.geoAssetDir();
    if (Platform.isMacOS) return MacOSCorePaths.geoAssetDir();
    return Future.value(null);
  }

  static Future<Directory> sessionDir() {
    if (Platform.isMacOS) return MacOSCorePaths.sessionDir();
    if (Platform.isLinux) return LinuxCorePaths.sessionDir();
    return WindowsCorePaths.sessionDir();
  }

  static String get binariesHint {
    if (Platform.isMacOS) return MacOSCorePaths.binariesHint;
    if (Platform.isLinux) return LinuxCorePaths.binariesHint;
    return WindowsCorePaths.binariesHint;
  }
}
