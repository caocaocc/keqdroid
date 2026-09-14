import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';

void main() {
  test('menu bar speed is enabled for new and legacy settings', () {
    expect(const AppSettings().showMenuBarSpeed, isTrue);
    final legacy = AppSettings.fromJson({'showSpeedInNotification': false});
    expect(legacy.showMenuBarSpeed, isTrue);
    expect(legacy.showSpeedInNotification, isFalse);
  });

  test(
    'menu bar preference persists independently of Android notifications',
    () {
      final saved = const AppSettings().copyWith(showMenuBarSpeed: false);
      final restored = AppSettings.fromJson(
        jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>,
      );
      expect(restored.showMenuBarSpeed, isFalse);
      expect(restored.showSpeedInNotification, isTrue);
      expect(restored, saved);
      expect(
        restored.copyWith(appLanguageCode: 'zh').showMenuBarSpeed,
        isFalse,
      );
      expect(
        restored.copyWith(showSpeedInNotification: false).showMenuBarSpeed,
        isFalse,
      );
      expect(
        restored.copyWith(showMenuBarSpeed: true).showMenuBarSpeed,
        isTrue,
      );
    },
  );

  test('equality and hashing distinguish the menu bar preference', () {
    const enabled = AppSettings();
    final disabled = enabled.copyWith(showMenuBarSpeed: false);
    expect(disabled, isNot(enabled));
    expect({enabled, disabled}, hasLength(2));
    expect(disabled.copyWith(), disabled);
    expect(disabled.copyWith().hashCode, disabled.hashCode);
  });
}
