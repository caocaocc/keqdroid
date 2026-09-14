import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/platform/desktop_lan_state.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/screens/settings_tab.dart';
import 'package:keqdroid/services/vpn_engine.dart';
import 'package:keqdroid/shared/ui/expressive_group.dart';

import '../helpers/fake_tunnel_backend.dart';
import '../helpers/test_storage.dart';

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(lanSharing: true);
  @override
  Future<void> save(AppSettings settings) async => state = AsyncData(settings);
}

class _Connected extends VpnStateNotifier {
  @override
  Future<VpnState> build() async => const VpnState(status: VpnStatus.connected);
}

void main() {
  testWidgets(
    'LAN edits keep confirmed listeners visible until reconnect',
    (tester) async {
      final storage = await buildStorageService();
      desktopLanState.value = const DesktopLanState(
        socksPort: 11080,
        httpPort: 18080,
        addresses: ['192.168.1.8'],
      );
      addTearDown(() => desktopLanState.value = null);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageProvider.overrideWithValue(storage),
            settingsNotifierProvider.overrideWith(_Settings.new),
            vpnStateProvider.overrideWith(_Connected.new),
            vpnEngineProvider.overrideWithValue(
              VpnEngine.withBackend(FakeTunnelBackend()),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsTab(),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final title = find.text('LAN Proxy');
      await tester.ensureVisible(title);
      final card = find
          .ancestor(of: title, matching: find.byType(ExpressiveGroupTile))
          .first;
      final toggle = find.descendant(of: card, matching: find.byType(Switch));
      expect(tester.widget<Switch>(toggle).onChanged, isNotNull);
      expect(find.text('192.168.1.8:11080'), findsOneWidget);
      expect(find.text('192.168.1.8:18080'), findsOneWidget);
      await tester.tap(toggle);
      await tester.pump();
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(find.text('192.168.1.8:11080'), findsOneWidget);
      expect(
        find.descendant(
          of: card,
          matching: find.text(
            'Applies on the next connection — the running session is not restarted.',
          ),
        ),
        findsNothing,
      );
      desktopLanState.value = const DesktopLanState(
        socksPort: 11081,
        httpPort: 18081,
        addresses: ['192.168.2.8'],
      );
      await tester.pump();
      expect(find.text('192.168.2.8:11081'), findsOneWidget);
      expect(find.text('192.168.1.8:11080'), findsNothing);
    },
    skip: !Platform.isMacOS,
  );
}
