import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/macos_app_routing.dart';
import '../tunnel/app_routing_mode.dart';

class MacOSAppRoutingStore {
  MacOSAppRoutingStore._();
  static const storageKey = 'keqdis_macos_app_routing_v1';
  static Future<void> _writes = Future.value();

  static Future<MacOSAppRoutingSettings> load() async {
    await _writes;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null) return const MacOSAppRoutingSettings();
    return MacOSAppRoutingSettings.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
  }

  static Future<void> save(MacOSAppRoutingSettings settings) {
    final next = _writes.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(storageKey, jsonEncode(settings.toJson()))) {
        throw const FileSystemException(
          'Could not save macOS application routing.',
        );
      }
    });
    _writes = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  /// После обновления .app список helper executable мог измениться. Берём
  /// свежую опись того же bundle, но никогда не ищем совпадение по имени.
  static Future<List<String>> resolvePaths(
    MacOSAppRoutingSettings settings,
    List<Map<String, dynamic>> installed,
  ) async {
    if (settings.mode == AppRoutingMode.allProxy) return const [];
    if (settings.apps.isEmpty) {
      throw const FormatException(
        'Select at least one application for split tunneling.',
      );
    }
    final current = <String, MacOSAppEntry>{};
    for (final map in installed) {
      try {
        final entry = MacOSAppEntry.fromNative(map);
        current[entry.id] = entry;
      } on FormatException {
        // Запись чужого/неполного bundle не расширяет выбранное правило.
      }
    }
    final paths = <String>{};
    for (final saved in settings.apps) {
      final entry = current[saved.id] ?? saved;
      for (final path in entry.executablePaths) {
        if (!await File(path).exists()) {
          throw FormatException(
            'Application moved or was removed: ${saved.displayName}. Select it again.',
          );
        }
        paths.add(path);
      }
    }
    return paths.toList();
  }
}
