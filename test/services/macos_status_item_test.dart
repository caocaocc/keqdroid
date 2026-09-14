import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations_en.dart';
import 'package:keqdroid/l10n/app_localizations_zh.dart';
import 'package:keqdroid/services/macos_status_item.dart';
import 'package:keqdroid/tunnel/desktop_recovery_status.dart';
import 'package:keqdroid/tunnel/macos_recovery_controller.dart';
import 'package:keqdroid/tunnel/tunnel_state.dart';

void main() {
  test('rate units, actual zero, unavailable and bounded extreme values', () {
    expect(formatMacOSMenuRate(null), '— KB/s');
    expect(formatMacOSMenuRate(-1), '— KB/s');
    expect(formatMacOSMenuRate(0), '0 KB/s');
    expect(formatMacOSMenuRate(1023), '0 KB/s');
    expect(formatMacOSMenuRate(1024), '1 KB/s');
    expect(formatMacOSMenuRate(1536), '1 KB/s');
    expect(formatMacOSMenuRate(1024 * 1024), '1 MB/s');
    expect(formatMacOSMenuRate(1024 * 1024 * 1024), '1024 MB/s');
    expect(formatMacOSMenuRate(0x7fffffffffffffff), '>9999 MB/s');
  });

  testWidgets('status-only snapshots do not flash zero or refresh stale data', (
    tester,
  ) async {
    var now = Duration.zero;
    final sent = <Map<String, Object>>[];
    final item = MacOSStatusItem(
      send: sent.add,
      labels: AppLocalizationsEn(),
      clock: () => now,
    );
    addTearDown(item.dispose);
    item.updateState(VpnState.connected);
    expect(sent.last['uploadText'], '— KB/s');
    item.updateState(
      const VpnState(
        status: VpnStatus.connected,
        uploadSpeed: 1024,
        downloadSpeed: 2048,
      ),
    );
    expect(sent.last['uploadText'], '1 KB/s');
    final count = sent.length;
    now = const Duration(seconds: 1);
    await tester.pump(const Duration(seconds: 1));
    item.updateState(VpnState.connected);
    expect(sent.length, count);
    now = const Duration(seconds: 3);
    await tester.pump(const Duration(seconds: 2));
    expect(sent.last['uploadText'], '— KB/s');
    expect(sent.last['status'], 'connected');
    item.updateState(
      const VpnState(
        status: VpnStatus.connected,
        uploadSpeed: 0,
        downloadSpeed: 0,
      ),
    );
    expect(sent.last['downloadText'], '0 KB/s');
    item.dispose();
  });

  testWidgets(
    'new samples extend expiry even when numeric rates are unchanged',
    (tester) async {
      var now = Duration.zero;
      final sent = <Map<String, Object>>[];
      final item = MacOSStatusItem(
        send: sent.add,
        labels: AppLocalizationsEn(),
        clock: () => now,
      );
      addTearDown(item.dispose);
      const sample = VpnState(
        status: VpnStatus.connected,
        uploadSpeed: 1,
        downloadSpeed: 2,
      );
      item.updateState(sample);
      now = const Duration(seconds: 2);
      await tester.pump(const Duration(seconds: 2));
      item.updateState(sample);
      now = const Duration(seconds: 3);
      await tester.pump(const Duration(seconds: 1));
      expect(sent.last['uploadText'], '0 KB/s');
      now = const Duration(seconds: 5);
      await tester.pump(const Duration(seconds: 2));
      expect(sent.last['uploadText'], '— KB/s');
    },
  );

  testWidgets(
    'disconnect, recovery and wake discard old rates; locale updates',
    (tester) async {
      final sent = <Map<String, Object>>[];
      final item = MacOSStatusItem(
        send: sent.add,
        labels: AppLocalizationsEn(),
      );
      addTearDown(item.dispose);
      const sample = VpnState(
        status: VpnStatus.connected,
        uploadSpeed: 100,
        downloadSpeed: 200,
      );
      item.updateState(sample);
      item.updateState(VpnState.disconnected);
      expect(sent.last['uploadText'], '— KB/s');
      item.updateState(VpnState.connected);
      expect(sent.last['uploadText'], '— KB/s');
      item.updateState(sample);
      item.updateRecovery(
        const DesktopRecoveryStatus(
          MacOSRecoveryPhase.waitingNetwork,
          null,
          null,
          0,
        ),
      );
      expect(sent.last['uploadText'], '— KB/s');
      expect(sent.last['status'], 'connecting');
      item.updateState(sample);
      expect(sent.last['uploadText'], '— KB/s');
      item.updateRecovery(null);
      item.updateState(sample);
      item.invalidateSample();
      expect(sent.last['uploadText'], '— KB/s');
      item.updateLabels(AppLocalizationsZh());
      expect(sent.last['statusText'], AppLocalizationsZh().trayStatusConnected);
      expect(sent.last['uploadLabel'], AppLocalizationsZh().statsUploadLabel);
      item.setShowSpeed(false);
      expect(sent.last['showSpeed'], false);
    },
  );

  testWidgets('five existing states map without exposing error details', (
    tester,
  ) async {
    final sent = <Map<String, Object>>[];
    final item = MacOSStatusItem(send: sent.add, labels: AppLocalizationsEn());
    addTearDown(item.dispose);
    for (final status in VpnStatus.values) {
      item.updateState(
        VpnState(status: status, errorMessage: 'private-node-secret'),
      );
      expect(sent.last['status'], status.name);
      expect(sent.last.toString(), isNot(contains('private-node-secret')));
    }
  });

  test('menu sampling only overrides hidden-window pause on macOS', () {
    for (final macOS in [false, true]) {
      for (final enabled in [false, true]) {
        expect(
          desktopTrafficPollingNeeded(
            visible: false,
            foreground: false,
            macOS: macOS,
            showMenuBarSpeed: enabled,
          ),
          macOS && enabled,
        );
        expect(
          desktopTrafficPollingNeeded(
            visible: true,
            foreground: true,
            macOS: macOS,
            showMenuBarSpeed: enabled,
          ),
          true,
        );
      }
    }
  });

  testWidgets('icon-only does not redraw on rates or leave expiry timers', (
    tester,
  ) async {
    final sent = <Map<String, Object>>[];
    final item = MacOSStatusItem(send: sent.add, labels: AppLocalizationsEn());
    item.setShowSpeed(false);
    item.updateState(VpnState.connected);
    final count = sent.length;
    item.updateState(
      const VpnState(
        status: VpnStatus.connected,
        uploadSpeed: 1234,
        downloadSpeed: 5678,
      ),
    );
    expect(sent.length, count);
    item.dispose();
    item.updateState(
      const VpnState(
        status: VpnStatus.connected,
        uploadSpeed: 1,
        downloadSpeed: 1,
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    expect(sent.length, count);
  });
}
