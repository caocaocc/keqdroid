//
// Explicit macOS registration for the locked plugins.
// Firebase, camera scanning and Workmanager remain Android-only.
// Keep in sync with Podfile and verify after dependency updates.
//

import FlutterMacOS
import Foundation

import dynamic_color
import file_picker
import flutter_local_notifications
import package_info_plus
import screen_retriever_macos
import share_plus
import shared_preferences_foundation
import tray_manager
import url_launcher_macos
import window_manager

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  DynamicColorPlugin.register(with: registry.registrar(forPlugin: "DynamicColorPlugin"))
  FilePickerPlugin.register(with: registry.registrar(forPlugin: "FilePickerPlugin"))
  FlutterLocalNotificationsPlugin.register(with: registry.registrar(forPlugin: "FlutterLocalNotificationsPlugin"))
  FPPPackageInfoPlusPlugin.register(with: registry.registrar(forPlugin: "FPPPackageInfoPlusPlugin"))
  ScreenRetrieverMacosPlugin.register(with: registry.registrar(forPlugin: "ScreenRetrieverMacosPlugin"))
  SharePlusMacosPlugin.register(with: registry.registrar(forPlugin: "SharePlusMacosPlugin"))
  SharedPreferencesPlugin.register(with: registry.registrar(forPlugin: "SharedPreferencesPlugin"))
  TrayManagerPlugin.register(with: registry.registrar(forPlugin: "TrayManagerPlugin"))
  UrlLauncherPlugin.register(with: registry.registrar(forPlugin: "UrlLauncherPlugin"))
  WindowManagerPlugin.register(with: registry.registrar(forPlugin: "WindowManagerPlugin"))
}
