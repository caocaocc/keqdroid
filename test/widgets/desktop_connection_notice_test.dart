import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/shared/ui/desktop_connection_notice.dart';
import 'package:keqdroid/tunnel/desktop_dns_diagnostics.dart';
import 'package:keqdroid/tunnel/desktop_recovery_status.dart';
import 'package:keqdroid/tunnel/macos_recovery_controller.dart';
import 'package:keqdroid/tunnel/tunnel_state.dart';

class _Restoration extends VpnStateNotifier {
  int attempts = 0;

  @override
  Future<VpnState> build() async => const VpnState(status: VpnStatus.error);

  @override
  Future<void> disconnect() async {
    attempts++;
    desktopRecoveryStatus.value = null;
    state = const AsyncData(VpnState.disconnected);
  }
}

void main() {
  setUp(() {
    desktopRecoveryStatus.value = null;
    desktopDnsDiagnostics.value = null;
  });
  tearDown(() {
    desktopRecoveryStatus.value = null;
    desktopDnsDiagnostics.value = null;
  });

  Future<void> showStatus(
    WidgetTester tester, {
    VpnStatus status = VpnStatus.connected,
    VoidCallback? onJump,
    _Restoration? restoration,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (restoration != null)
            vpnStateProvider.overrideWith(() => restoration),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Center(
                child: SizedBox(
                  width: 260,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 48 * scale,
                        child: DesktopConnectionNotice(
                          status: status,
                          child: TextButton(
                            onPressed: onJump,
                            child: const Text('Connected to test node'),
                          ),
                        ),
                      ),
                      const SizedBox(key: ValueKey('server-list'), height: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('recovery uses the existing slot without moving the list', (
    tester,
  ) async {
    await showStatus(tester);
    final list = find.byKey(const ValueKey('server-list'));
    final position = tester.getTopLeft(list);
    for (final entry in {
      MacOSRecoveryPhase.waitingNetwork: 'Waiting for network to recover',
      MacOSRecoveryPhase.recovering: 'Restoring previous network settings',
      MacOSRecoveryPhase.backoff: 'Reconnecting automatically',
      MacOSRecoveryPhase.paused: 'Automatic recovery paused',
    }.entries) {
      desktopRecoveryStatus.value = DesktopRecoveryStatus(
        entry.key,
        'offline',
        'Detailed cause stays in diagnostics',
        0,
      );
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('Connected to test node'), findsNothing);
      expect(find.textContaining('Detailed cause'), findsNothing);
      expect(tester.getTopLeft(list), position);
      expect(tester.takeException(), isNull);
    }
    desktopRecoveryStatus.value = null;
    await tester.pump();
    expect(find.text('Connected to test node'), findsOneWidget);
    expect(tester.getTopLeft(list), position);
  });

  testWidgets(
    'paused cleanup keeps the explicit restoration action in details',
    (tester) async {
      final restoration = _Restoration();
      desktopRecoveryStatus.value = const DesktopRecoveryStatus(
        MacOSRecoveryPhase.paused,
        'recoveryFailed',
        'Test: original DNS could not be restored',
        3,
      );
      await showStatus(
        tester,
        status: VpnStatus.error,
        restoration: restoration,
      );
      expect(find.text('Retry network restoration'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('desktop-recovery-status')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.textContaining('original DNS could not be restored'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry network restoration'));
      await tester.pumpAndSettle();
      expect(restoration.attempts, 1);
      expect(find.text('Retry network restoration'), findsNothing);
      expect(
        find.textContaining('original DNS could not be restored'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'DNS details preserve the connected node action and header height',
    (tester) async {
      var jumps = 0;
      await showStatus(tester, onJump: () => jumps++);
      final list = find.byKey(const ValueKey('server-list'));
      final position = tester.getTopLeft(list);
      desktopDnsDiagnostics.value = const DesktopDnsDiagnostics(
        sessionId: 'test',
        status: 'warning',
        message: 'Test DNS failed',
      );
      await tester.pump();
      await tester.tap(find.text('Connected to test node'));
      expect(jumps, 1);
      expect(tester.getTopLeft(list), position);
      await tester.tap(find.byKey(const ValueKey('desktop-dns-warning')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Test DNS failed'), findsOneWidget);
      expect(jumps, 1);
      desktopDnsDiagnostics.value = const DesktopDnsDiagnostics(
        sessionId: 'test',
        status: 'ok',
        message: 'Test DNS recovered',
      );
      await tester.pump();
      expect(find.textContaining('Test DNS failed'), findsNothing);
      expect(find.textContaining('Test DNS recovered'), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-dns-warning')), findsNothing);
    },
  );

  testWidgets('recovery details keep a reason without a message', (
    tester,
  ) async {
    desktopRecoveryStatus.value = const DesktopRecoveryStatus(
      MacOSRecoveryPhase.paused,
      'serviceInterrupted',
      null,
      3,
    );
    await showStatus(tester, status: VpnStatus.error);
    await tester.tap(find.byKey(const ValueKey('desktop-recovery-status')));
    await tester.pumpAndSettle();
    expect(find.textContaining('serviceInterrupted'), findsOneWidget);
  });

  testWidgets('disconnected state never displays an old DNS warning', (
    tester,
  ) async {
    desktopDnsDiagnostics.value = const DesktopDnsDiagnostics(
      sessionId: 'old',
      status: 'warning',
      message: 'Old diagnostic',
    );
    await showStatus(tester, status: VpnStatus.disconnected);
    expect(find.byKey(const ValueKey('desktop-dns-warning')), findsNothing);
  });

  testWidgets('recovery and DNS fit a narrow status slot with larger text', (
    tester,
  ) async {
    desktopRecoveryStatus.value = const DesktopRecoveryStatus(
      MacOSRecoveryPhase.waitingNetwork,
      'offline',
      null,
      0,
    );
    await showStatus(tester, scale: 2);
    expect(find.text('Waiting for network to recover'), findsOneWidget);
    expect(tester.takeException(), isNull);
    desktopRecoveryStatus.value = null;
    desktopDnsDiagnostics.value = const DesktopDnsDiagnostics(
      sessionId: 'test',
      status: 'warning',
      message: 'Test DNS failed',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('desktop-dns-warning')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
