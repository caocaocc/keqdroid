import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_tunnel_backend.dart';
import 'package:keqdroid/tunnel/tunnel_state.dart';

typedef _Counters = ({int down, int up});

class _StatsBackend extends MacOSTunnelBackend {
  _StatsBackend({
    required super.channel,
    required super.statsNow,
    required super.statsWallNow,
  }) : super(enablePolling: false);

  Future<_Counters?> Function() response = () async => null;
  int queries = 0;
  int resets = 0;

  @override
  Future<_Counters?> queryClashTraffic(int port, {String secret = ''}) {
    queries++;
    return response();
  }

  @override
  void resetStatsHttp() {
    resets++;
    super.resetStatsHttp();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.keqdroid.macos.traffic');
  late _StatsBackend backend;
  late Duration now;
  late DateTime wallNow;
  late Map<String, dynamic> snapshot;

  Map<String, dynamic> connected(String id) => {
    'status': 'connected',
    'sessionId': id,
    'connectionMode': 'proxy',
    'apiPort': 9876,
    'apiSecret': 'test-only',
  };

  Future<void> sample(
    int down,
    int up, {
    int afterMilliseconds = 1000,
    int? wallAfterMilliseconds,
  }) async {
    now += Duration(milliseconds: afterMilliseconds);
    wallNow = wallNow.add(
      Duration(milliseconds: wallAfterMilliseconds ?? afterMilliseconds),
    );
    backend.response = () async => (down: down, up: up);
    await backend.pollTrafficStats(ConnectionMode.proxy);
  }

  void expectNoRate() {
    expect(backend.currentState.downloadSpeed, isNull);
    expect(backend.currentState.uploadSpeed, isNull);
  }

  setUp(() async {
    now = Duration.zero;
    wallNow = DateTime.utc(2026, 9, 13);
    snapshot = connected('first-session');
    backend = _StatsBackend(
      channel: channel,
      statsNow: () => now,
      statsWallNow: () => wallNow,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getSession') return snapshot;
          if (call.method == 'stopSession') {
            snapshot = {'status': 'disconnected'};
            return snapshot;
          }
          throw MissingPluginException(call.method);
        });
    await backend.getCurrentState();
  });

  tearDown(() {
    backend.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'first counters are a baseline, subsequent idle traffic is zero',
    () async {
      await sample(2000, 1000);
      expectNoRate();
      expect(backend.currentState.totalDownload, 2000);
      expect(backend.currentState.totalUpload, 1000);

      await sample(2000, 1000);
      expect(backend.currentState.downloadSpeed, 0);
      expect(backend.currentState.uploadSpeed, 0);
    },
  );

  test(
    'rates use actual monotonic elapsed time instead of a fixed second',
    () async {
      await sample(2000, 1000);
      await sample(5000, 1750, afterMilliseconds: 1500);
      expect(backend.currentState.downloadSpeed, 2000);
      expect(backend.currentState.uploadSpeed, 500);
    },
  );

  test(
    'wake or a gap above three seconds establishes a new baseline',
    () async {
      await sample(2000, 1000);
      await sample(32000, 16000, afterMilliseconds: 3001);
      expectNoRate();
      await sample(33000, 18000);
      expect(backend.currentState.downloadSpeed, 1000);
      expect(backend.currentState.uploadSpeed, 2000);
    },
  );

  test('a three second interval is still a valid measured sample', () async {
    await sample(2000, 1000);
    await sample(5000, 2500, afterMilliseconds: 3000);
    expect(backend.currentState.downloadSpeed, 1000);
    expect(backend.currentState.uploadSpeed, 500);
  });

  test(
    'deep sleep resets the baseline even when monotonic time pauses',
    () async {
      await sample(2000, 1000);
      await sample(9000, 4000, wallAfterMilliseconds: 60000);
      expectNoRate();
      await sample(10000, 4500);
      expect(backend.currentState.downloadSpeed, 1000);
      expect(backend.currentState.uploadSpeed, 500);
    },
  );

  test('a backwards wall clock invalidates only the baseline', () async {
    await sample(2000, 1000);
    await sample(9000, 4000, wallAfterMilliseconds: -1000);
    expectNoRate();
    await sample(10000, 4500);
    expect(backend.currentState.downloadSpeed, 1000);
    expect(backend.currentState.uploadSpeed, 500);
  });

  test('wall clock changes never become the rate denominator', () async {
    await sample(2000, 1000);
    await sample(
      5000,
      1750,
      afterMilliseconds: 1500,
      wallAfterMilliseconds: 500,
    );
    expect(backend.currentState.downloadSpeed, 2000);
    expect(backend.currentState.uploadSpeed, 500);
  });

  test('a counter reset resets both rates without losing new totals', () async {
    await sample(2000, 1000);
    await sample(20, 1500);
    expectNoRate();
    expect(backend.currentState.totalDownload, 20);
    expect(backend.currentState.totalUpload, 1500);
    await sample(1020, 2000);
    expect(backend.currentState.downloadSpeed, 1000);
    expect(backend.currentState.uploadSpeed, 500);
  });

  test('zero elapsed time updates only the baseline', () async {
    await sample(2000, 1000);
    await sample(5000, 2000, afterMilliseconds: 0);
    expectNoRate();
    await sample(6000, 2500);
    expect(backend.currentState.downloadSpeed, 1000);
    expect(backend.currentState.uploadSpeed, 500);
  });

  test('resume takes a baseline even after a short polling pause', () async {
    await sample(2000, 1000);
    backend.setTrafficStatsPollingEnabled(false);
    final before = backend.queries;
    await sample(6000, 2000, afterMilliseconds: 100);
    expect(backend.queries, before);
    backend.setTrafficStatsPollingEnabled(true);
    await sample(9000, 4000, afterMilliseconds: 100);
    expectNoRate();
    await sample(10000, 4500);
    expect(backend.currentState.downloadSpeed, 1000);
    expect(backend.currentState.uploadSpeed, 500);
  });

  test(
    'simultaneous public and service polling shares one stats query',
    () async {
      final pending = Completer<_Counters?>();
      backend.response = () => pending.future;
      final before = backend.queries;
      final first = backend.pollTrafficStats(ConnectionMode.proxy);
      await backend.pollTrafficStats(ConnectionMode.proxy);
      await backend.getCurrentState();
      expect(backend.queries, before + 1);
      pending.complete((down: 2000, up: 1000));
      await first;
      expectNoRate();
    },
  );

  test('disable and re-enable rejects an already pending sample', () async {
    await sample(2000, 1000);
    final pending = Completer<_Counters?>();
    backend.response = () => pending.future;
    final first = backend.pollTrafficStats(ConnectionMode.proxy);
    backend.setTrafficStatsPollingEnabled(false);
    backend.setTrafficStatsPollingEnabled(true);
    pending.complete((down: 2000000, up: 1000000));
    await first;
    expect(backend.currentState.totalDownload, 2000);
    await sample(4000, 2000);
    expectNoRate();
  });

  test('late counters cannot resurrect a manually stopped session', () async {
    final pending = Completer<_Counters?>();
    backend.response = () => pending.future;
    final first = backend.pollTrafficStats(ConnectionMode.proxy);
    await backend.stopSession();
    pending.complete((down: 2000, up: 1000));
    await first;
    expect(backend.currentState.status, VpnStatus.disconnected);
    expectNoRate();
    expect(backend.currentState.totalDownload, isNull);
  });

  test(
    'a new session rejects old counters and starts with its own baseline',
    () async {
      await sample(2000, 1000);
      final pending = Completer<_Counters?>();
      backend.response = () => pending.future;
      final first = backend.pollTrafficStats(ConnectionMode.proxy);
      snapshot = {'status': 'disconnected'};
      await backend.getCurrentState();
      snapshot = connected('second-session');
      await backend.getCurrentState();
      pending.complete((down: 2000000, up: 1000000));
      await first;
      expectNoRate();
      expect(backend.currentState.totalDownload, 0);
      await sample(100, 200);
      expectNoRate();
      await sample(200, 400);
      expect(backend.currentState.downloadSpeed, 100);
      expect(backend.currentState.uploadSpeed, 200);
    },
  );

  test(
    'error recovery with the same session cannot reuse pre-error counters',
    () async {
      await sample(2000, 1000);
      snapshot = {
        ...connected('first-session'),
        'status': 'error',
        'error': 'service unavailable',
      };
      await backend.getCurrentState();
      backend.response = () async => (down: 4000, up: 2000);
      snapshot = connected('first-session');
      now += const Duration(seconds: 1);
      await backend.getCurrentState();
      expectNoRate();
    },
  );

  test(
    'failed or invalid queries do not replace the last valid counters',
    () async {
      await sample(2000, 1000);
      backend.response = () async => null;
      await backend.pollTrafficStats(ConnectionMode.proxy);
      await sample(-1, 1000);
      expect(backend.currentState.totalDownload, 2000);
      await sample(4000, 2000);
      expect(backend.currentState.downloadSpeed, 1000);
      expect(backend.currentState.uploadSpeed, 500);
    },
  );

  testWidgets('stalled API queries expire and cannot publish a late result', (
    tester,
  ) async {
    final pending = Completer<_Counters?>();
    backend.response = () => pending.future;
    final before = backend.resets;
    final first = backend.pollTrafficStats(ConnectionMode.proxy);
    await tester.pump(const Duration(seconds: 3));
    await first;
    expect(backend.resets, before + 1);
    pending.complete((down: 2000000, up: 1000000));
    await tester.pump();
    expect(backend.currentState.totalDownload, 0);
    await sample(100, 200);
    expectNoRate();
    await sample(200, 400);
    expect(backend.currentState.downloadSpeed, 100);
    expect(backend.currentState.uploadSpeed, 200);
  });
}
