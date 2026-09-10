import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/hotkey_config.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/screens/settings_tab.dart';
import 'package:keqdroid/services/hotkey_service.dart';
import 'package:keqdroid/services/vpn_engine.dart';

import '../helpers/fake_tunnel_backend.dart';
import '../helpers/test_storage.dart';

class _ImmediateSettings extends SettingsNotifier {
  _ImmediateSettings(this.initial);
  final AppSettings initial;
  final publishedDuringCapture = <bool>[];

  @override
  Future<AppSettings> build() async => initial;

  @override
  Future<void> save(AppSettings settings) async {
    publishedDuringCapture.add(HotkeyService.captureMode);
    // Match production: listeners run before persistence finishes or a frame
    // refreshes the hotkey editor's cached copy of the settings.
    state = AsyncData(settings);
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  const channel = MethodChannel('keqdis_vpn_channel');
  final registrations = <List<dynamic>>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'setGlobalHotkeys') {
            registrations.add(List<dynamic>.from(call.arguments as List));
            return <String>[];
          }
          return null;
        });
    registrations.clear();
    HotkeyService.captureMode = false;
  });

  tearDown(() async {
    HotkeyService.onPressed = null;
    HotkeyService.captureMode = false;
    await HotkeyService.apply(const {});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<_ImmediateSettings> openEditor(
    WidgetTester tester,
    Map<String, String> initial,
  ) async {
    final storage = await buildStorageService();
    final notifier = _ImmediateSettings(AppSettings(hotkeys: initial));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          settingsNotifierProvider.overrideWith(() => notifier),
          vpnEngineProvider.overrideWithValue(
            VpnEngine.withBackend(FakeTunnelBackend()),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            // This is the production desktop listener's contract: a settings
            // publication immediately registers the new bindings.
            ref.listen<AsyncValue<AppSettings>>(settingsNotifierProvider, (
              previous,
              next,
            ) {
              final bindings = next.value?.hotkeys;
              if (bindings == null ||
                  mapEquals(previous?.value?.hotkeys, bindings)) {
                return;
              }
              unawaited(
                HotkeyService.apply(HotkeyService.parseBindings(bindings)),
              );
            });
            return MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const SettingsTab(),
            );
          },
        ),
      ),
    );
    await _frames(tester);
    await tester.ensureVisible(find.text('Advanced'));
    await tester.tap(find.text('Advanced'));
    await _frames(tester);
    await tester.ensureVisible(find.text('Hotkeys'));
    await tester.tap(find.text('Hotkeys'));
    await _frames(tester);
    return notifier;
  }

  testWidgets('saving a shortcut leaves the new registration active', (
    tester,
  ) async {
    final notifier = await openEditor(tester, const {});
    await tester.tap(find.text('Not set').last);
    await _frames(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await _frames(tester);

    expect(notifier.publishedDuringCapture, [false]);
    expect(find.text('F6'), findsOneWidget);
    if (Platform.isMacOS) {
      expect(registrations.last, [
        {'action': 'toggleWindow', 'binding': 'f6'},
      ]);
    } else if (Platform.isLinux) {
      final actions = <HotkeyAction>[];
      HotkeyService.onPressed = actions.add;
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      expect(actions, [HotkeyAction.toggleWindow]);
    }
  });

  testWidgets('clearing a shortcut does not restore its old registration', (
    tester,
  ) async {
    final notifier = await openEditor(tester, const {'toggleWindow': 'f6'});
    await tester.tap(find.text('F6'));
    await _frames(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _frames(tester);

    expect(notifier.publishedDuringCapture, [false]);
    expect(find.text('F6'), findsNothing);
    if (Platform.isMacOS) {
      expect(registrations.last, isEmpty);
    } else if (Platform.isLinux) {
      final actions = <HotkeyAction>[];
      HotkeyService.onPressed = actions.add;
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      expect(actions, isEmpty);
    }
  });
}
