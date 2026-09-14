import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/ephemeral_xray_ping.dart';
import 'package:keqdroid/tunnel/url_test_diagnostics.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';

void main() {
  test(
    'core startup reports a process exit without waiting for its full deadline',
    () async {
      final process = Platform.isWindows
          ? await Process.start('cmd', ['/c', 'exit', '7'])
          : await Process.start('/bin/sh', ['-c', 'exit 7']);
      addTearDown(() {
        process.kill();
      });
      final result = await EphemeralXrayPing.waitForCorePort(
        process: process,
        port: 0,
      );
      expect(result.ready, isFalse);
      expect(result.exitCode, 7);
    },
  );

  test(
    'signal termination is an exit, not the old negative timeout sentinel',
    () async {
      final process = await Process.start('/bin/sleep', ['10']);
      addTearDown(() {
        process.kill();
      });
      process.kill(ProcessSignal.sigkill);
      final result = await EphemeralXrayPing.waitForCorePort(
        process: process,
        port: 0,
      );
      expect(result.ready, isFalse);
      expect(result.exitCode, -ProcessSignal.sigkill.signalNumber);
    },
    skip: Platform.isWindows,
  );

  const failed = (
    success: false,
    latencyMs: null,
    error: 'GET probe failed at proxyConnect',
    httpStatus: null,
    diagnostics: null,
  );
  const ready = (
    success: true,
    latencyMs: 17,
    error: '',
    httpStatus: 204,
    diagnostics: UrlTestDiagnostics(
      stage: 'firstGet',
      elapsedMs: 17,
      budgetMs: 400,
    ),
  );

  test('mihomo early rejection retries within one request budget', () async {
    final budgets = <int>[];
    final result = await EphemeralXrayPing.probeWhileCoreWakesUp(
      core: VpnBackend.mihomo,
      timeoutMs: 800,
      coreExited: () => false,
      probe: (remaining) async {
        budgets.add(remaining);
        return budgets.length == 1 ? failed : ready;
      },
    );
    expect(result.success, isTrue);
    expect(result.latencyMs, ready.latencyMs);
    expect(result.diagnostics!.stage, 'firstGet');
    expect(result.diagnostics!.budgetMs, 800);
    expect(result.diagnostics!.elapsedMs, greaterThanOrEqualTo(200));
    expect(
      result.diagnostics!.stageDurationsMs['coreWakeup'],
      greaterThanOrEqualTo(200),
    );
    expect(budgets, hasLength(2));
    expect(budgets.first, 800);
    expect(budgets.last, lessThanOrEqualTo(600));
    expect(budgets.last, greaterThan(0));
  });

  test(
    'retry consuming remaining deadline never receives another budget',
    () async {
      final budgets = <int>[];
      final result = await EphemeralXrayPing.probeWhileCoreWakesUp(
        core: VpnBackend.mihomo,
        timeoutMs: 600,
        coreExited: () => false,
        probe: (remaining) async {
          budgets.add(remaining);
          if (budgets.length > 1) {
            await Future<void>.delayed(Duration(milliseconds: remaining));
          }
          return failed;
        },
      );
      expect(result, failed);
      expect(budgets, hasLength(2));
      expect(budgets.last, lessThanOrEqualTo(400));
    },
  );

  test('xray or an exited core is not retried', () async {
    for (final scenario in [
      (VpnBackend.xray, false),
      (VpnBackend.mihomo, true),
    ]) {
      var calls = 0;
      final result = await EphemeralXrayPing.probeWhileCoreWakesUp(
        core: scenario.$1,
        timeoutMs: 800,
        coreExited: () => scenario.$2,
        probe: (_) async {
          calls++;
          return failed;
        },
      );
      expect(result, failed);
      expect(calls, 1);
    }
  });

  test(
    'successful first measurement never repeats during wakeup grace',
    () async {
      var calls = 0;
      final result = await EphemeralXrayPing.probeWhileCoreWakesUp(
        core: VpnBackend.mihomo,
        timeoutMs: 800,
        coreExited: () => false,
        probe: (_) async {
          calls++;
          return ready;
        },
      );
      expect(result, ready);
      expect(calls, 1);
    },
  );
}
