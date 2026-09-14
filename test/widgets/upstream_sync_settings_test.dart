import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/app/app.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/screens/settings_tab.dart';
import 'package:keqdroid/services/macos_desktop_service.dart';
import 'package:keqdroid/services/settings_backup_service.dart';
import 'package:keqdroid/services/vpn_engine.dart';

import '../helpers/fake_tunnel_backend.dart';
import '../helpers/test_storage.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.initial);
  final AppSettings initial;
  AppSettings get current => state.requireValue;

  @override
  Future<AppSettings> build() async => initial;

  @override
  Future<void> save(AppSettings next) async => state = AsyncData(next);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<_Settings> _open(WidgetTester tester, AppSettings initial) async {
  tester.view.physicalSize = const Size(900, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final storage = await buildStorageService();
  final notifier = _Settings(initial);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        settingsNotifierProvider.overrideWith(() => notifier),
        vpnEngineProvider.overrideWithValue(
          VpnEngine.withBackend(FakeTunnelBackend()),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(
          buildPresetScheme(themePresetFor(initial), Brightness.light),
        ),
        home: const SettingsTab(),
      ),
    ),
  );
  await _frames(tester);
  return notifier;
}

Future<void> _tap(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _frames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'upstream appearance migrates without changing local desktop identity',
    () async {
      final storage = await buildStorageService();
      await storage.saveSettings(
        const AppSettings(
          launchAtStartup: true,
          launchAtStartupElevated: true,
          serverIconThemeColors: false,
          showMenuBarSpeed: false,
        ),
      );
      // An upstream backup has the new icon preference but no macOS menu field.
      await SettingsBackupService.applyBackup(
        storage,
        backup: KeqdisBackup(
          version: 1,
          exportedAt: DateTime(2026, 9, 13),
          data: {
            'appSettings': {
              'serverIconThemeColors': true,
              'launchAtStartupElevated': false,
            },
          },
        ),
        sections: {BackupSection.appSettings},
      );
      final saved = await storage.getSettings();
      expect(saved.serverIconThemeColors, isTrue);
      expect(saved.showMenuBarSpeed, isFalse);
      expect(saved.launchAtStartup, isTrue);
      expect(saved.launchAtStartupElevated, isTrue);
      expect(AppSettings.fromJson(saved.toJson()), saved);
    },
  );

  testWidgets(
    'upstream icon preference leaves menu sampling preference alone',
    (tester) async {
      final notifier = await _open(
        tester,
        const AppSettings(
          vpnCore: AppSettings.vpnCoreMihomo,
          showMenuBarSpeed: false,
          launchAtStartupElevated: true,
        ),
      );
      await _tap(tester, 'Appearance');
      expect(find.text('VPN and direct traffic separately'), findsOneWidget);
      await _tap(tester, 'Flagless server icons in theme colours');
      expect(notifier.current.serverIconThemeColors, isFalse);
      expect(notifier.current.showMenuBarSpeed, isFalse);
      expect(notifier.current.launchAtStartupElevated, isTrue);
      if (Platform.isMacOS) {
        await _tap(tester, 'Show real-time speed in the menu bar');
        expect(notifier.current.showMenuBarSpeed, isTrue);
        expect(notifier.current.serverIconThemeColors, isFalse);
      }
    },
  );

  for (final core in [AppSettings.vpnCoreXray, AppSettings.vpnCoreMihomo]) {
    testWidgets(
      '$core retains direct DNS splitting and core-specific controls',
      (tester) async {
        final notifier = await _open(tester, AppSettings(vpnCore: core));
        final dns = notifier.current.xrayCore.dnsServers;
        await _tap(tester, 'Advanced');
        await _tap(tester, 'Core settings');
        expect(find.text('Split resolver for direct domains'), findsOneWidget);
        expect(find.text('Own addresses for domains'), findsOneWidget);
        expect(find.text('Resolver for specific domains'), findsOneWidget);
        await _tap(tester, 'Split resolver for direct domains');
        expect(notifier.current.xrayCore.dnsSplitDirectDomains, isFalse);
        expect(notifier.current.xrayCore.dnsServers, dns);
        expect(
          find.text('Disable DNS cache'),
          core == AppSettings.vpnCoreXray ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('XMUX (XHTTP)'),
          core == AppSettings.vpnCoreXray ? findsOneWidget : findsNothing,
        );
        if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
          await tester.scrollUntilVisible(
            find.text('TUN mode'),
            450,
            // DNS editors have their own scrollables; move the page itself.
            scrollable: find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(find.text('TUN mode'), findsOneWidget);
        }
      },
    );
  }

  testWidgets(
    'macOS desktop changes do not reset Windows admin or recreate login item',
    (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MacOSDesktopService.channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MacOSDesktopService.channel, null),
      );
      final notifier = await _open(
        tester,
        const AppSettings(
          launchAtStartup: true,
          launchAtStartupElevated: true,
          autoConnectLastServer: false,
        ),
      );
      await _tap(tester, 'macOS');
      expect(find.text('Start with admin rights'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('Connect automatically at login'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byType(Switch),
        ),
      );
      await _frames(tester);
      expect(notifier.current.autoConnectLastServer, isTrue);
      expect(notifier.current.launchAtStartupElevated, isTrue);
      final changes = calls
          .where((call) => call.method == 'applyDesktopSettings')
          .toList();
      expect(changes, hasLength(1));
      expect(changes.single.arguments, isNot(contains('launchAtStartup')));
      await tester.tap(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('Launch at login'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byType(Switch),
        ),
      );
      await _frames(tester);
      expect(notifier.current.launchAtStartup, isFalse);
      expect(notifier.current.launchAtStartupElevated, isTrue);
      expect(calls.last.arguments['launchAtStartup'], isFalse);
    },
    skip: !Platform.isMacOS,
  );
}
