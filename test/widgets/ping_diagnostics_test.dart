import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/app/app.dart';
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

  for (final layout in ServerRowLayout.values) {
    for (final succeeded in [true, false]) {
      testWidgets(
        '${layout.name} keeps ${succeeded ? 'first request fallback' : 'failed GET stage'} diagnostics',
        (tester) async {
          final result = succeeded
              ? diagnostic
              : const UrlTestDiagnostics(
                  stage: 'tls',
                  elapsedMs: 800,
                  budgetMs: 800,
                  stageDurationsMs: {
                    'coreStartup': 120,
                    'localConnect': 2,
                    'proxyConnect': 20,
                    'tls': 778,
                  },
                  coreStartupBudgetMs: 3000,
                );
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(
                ColorScheme.fromSeed(seedColor: const Color(0xFF7B61FF)),
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('en'),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.4)),
                child: child!,
              ),
              home: Scaffold(
                body: Center(
                  child: Builder(
                    builder: (context) => SizedBox(
                      width: layout == ServerRowLayout.card ? 180 : 400,
                      height: layout == ServerRowLayout.card
                          ? ServerRow.cardHeight(context) - ServerRow.cardGap
                          : ServerRow.height,
                      child: ServerRow(
                        server: ServerItem(
                          id: 'server',
                          type: ServerItemType.manual,
                          config:
                              'vless://test@192.0.2.1:443?security=none&type=tcp',
                        ),
                        layout: layout,
                        status: layout == ServerRowLayout.card
                            ? const SizedBox.square(dimension: 16)
                            : null,
                        pingMs: succeeded ? 123 : null,
                        lastTestedAt: DateTime(2026),
                        pingColorType: PingType.url,
                        pingDiagnostics: result,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(
            find.textContaining(succeeded ? 'First request' : 'N/A · tls'),
            findsOneWidget,
          );
          final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
          expect(tooltip.message, contains(result.stage));
          expect(tooltip.message, contains('800'));
          expect(tooltip.message, contains('coreStartup: 120 ms / 3000 ms'));
          expect(tooltip.message, contains('tls: ${succeeded ? 30 : 778} ms'));
          if (succeeded) {
            expect(tooltip.message, contains('warmGet: 700 ms'));
          }
        },
      );
    }
  }
}
