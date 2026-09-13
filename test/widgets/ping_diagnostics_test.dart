import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/providers/ui_state_providers.dart';
import 'package:keqdroid/services/ping_service.dart';
import 'package:keqdroid/shared/ui/server_row.dart';
import 'package:keqdroid/tunnel/url_test_diagnostics.dart';

void main() {
  const diagnostic = UrlTestDiagnostics(
    stage: 'warmGet',
    elapsedMs: 800,
    budgetMs: 800,
    timingKind: 'coldFallback',
    completedRequests: 1,
    warning: 'GET probe timed out at warmGet',
    stageDurationsMs: {
      'coreStartup': 120,
      'localConnect': 2,
      'proxyConnect': 20,
      'tls': 30,
      'firstGet': 48,
      'warmGet': 700,
    },
    coreStartupBudgetMs: 3000,
  );

  test('diagnostic metadata round trips and older results may omit it', () {
    expect(
      UrlTestDiagnostics.fromMap(diagnostic.toMap())?.timingKind,
      'coldFallback',
    );
    expect(UrlTestDiagnostics.fromMap(null), isNull);
    final restored = UrlTestDiagnostics.fromMap(diagnostic.toMap())!;
    expect(restored.stageDurationsMs, diagnostic.stageDurationsMs);
    expect(restored.coreStartupBudgetMs, 3000);
    final legacy = UrlTestDiagnostics.fromMap({
      'stage': 'firstGet',
      'elapsedMs': 10,
      'budgetMs': 500,
    })!;
    expect(legacy.stageDurationsMs, isEmpty);
    expect(legacy.coreStartupBudgetMs, isNull);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(pingDiagnosticsProvider.notifier);
    notifier.set('server', diagnostic);
    expect(container.read(pingDiagnosticsProvider)['server'], same(diagnostic));
    notifier.clear(['server']);
    expect(container.read(pingDiagnosticsProvider), isEmpty);
  });

  test('adding core startup timing leaves the network budget separate', () {
    const network = UrlTestDiagnostics(
      stage: 'firstGet',
      elapsedMs: 60,
      budgetMs: 500,
      completedRequests: 1,
      stageDurationsMs: {'localConnect': 10, 'firstGet': 50},
    );
    final combined = UrlTestDiagnostics.fromMap(
      network.withCoreStartup(elapsedMs: 200, budgetMs: 1000).toMap(),
    )!;
    expect(combined.elapsedMs, 60);
    expect(combined.budgetMs, 500);
    expect(combined.coreStartupBudgetMs, 1000);
    expect(combined.completedRequests, 1);
    expect(combined.stageDurationsMs, {
      'coreStartup': 200,
      'localConnect': 10,
      'firstGet': 50,
    });
    expect(network.stageDurationsMs, {'localConnect': 10, 'firstGet': 50});
  });

  testWidgets(
    'first successful request fallback is visible and explains the failed warm stage',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: ServerRow(
              server: ServerItem(
                id: 'server',
                type: ServerItemType.manual,
                config: 'vless://test@192.0.2.1:443?security=none&type=tcp',
              ),
              pingMs: 123,
              pingColorType: PingType.url,
              pingDiagnostics: diagnostic,
            ),
          ),
        ),
      );
      expect(find.textContaining('First request'), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('warmGet'));
      expect(tooltip.message, contains('800'));
      expect(tooltip.message, contains('coreStartup: 120 ms / 3000 ms'));
      expect(tooltip.message, contains('tls: 30 ms'));
      expect(tooltip.message, contains('warmGet: 700 ms'));
    },
  );
}
