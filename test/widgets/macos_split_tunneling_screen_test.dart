import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/macos_app_routing.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/screens/macos_split_tunneling_screen.dart';
import 'package:keqdroid/services/macos_app_routing_store.dart';
import 'package:keqdroid/tunnel/app_routing_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('keqdis_vpn_channel');
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAppIcon') return null;
          return [
            {
              'appName': 'Browser',
              'packageName': '/Applications/Browser.app/Contents/MacOS/Browser',
              'bundlePath': '/Applications/Browser.app',
              'bundleId': 'test.browser',
              'executablePaths': [
                '/Applications/Browser.app/Contents/MacOS/Browser',
                '/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper',
              ],
            },
          ];
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  testWidgets(
    'Mac screen keeps missing apps and saves exact helper paths on selection',
    (tester) async {
      await MacOSAppRoutingStore.save(
        const MacOSAppRoutingSettings(
          mode: AppRoutingMode.onlySelected,
          apps: [
            MacOSAppEntry(
              displayName: 'Missing',
              executablePath: '/opt/missing',
              executablePaths: ['/opt/missing'],
            ),
          ],
        ),
      );
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsNotifierProvider.overrideWith(_Settings.new)],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.macOS),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const MacOSSplitTunnelingScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Missing'), findsOneWidget);
      expect(find.text('Browser'), findsOneWidget);
      await tester.tap(find.text('Browser'));
      await tester.pumpAndSettle();
      final saved = await MacOSAppRoutingStore.load();
      expect(
        saved.apps.map((app) => app.displayName),
        containsAll(['Missing', 'Browser']),
      );
      expect(
        saved.processPaths,
        contains(
          '/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper',
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
