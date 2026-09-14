import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/models/subscription.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/services/core_dial_failures.dart';
import 'package:keqdroid/services/ping_service.dart';
import 'package:keqdroid/services/vpn_engine.dart';
import 'package:keqdroid/tunnel/macos_tunnel_backend.dart';
import '../helpers/test_storage.dart';

typedef _Counters = ({int down, int up});

class _Backend extends MacOSTunnelBackend {
  _Backend() : super(enablePolling: false);
  String identity = 'helper/session-1';
  final changes = StreamController<VpnState>.broadcast(sync: true);
  VpnState value = const VpnState(status: VpnStatus.connected);
  _Counters counters = (down: 100, up: 100);
  Future<_Counters?> Function()? delayed;
  int samples = 0;
  @override
  String? get activeSessionIdentity => identity;
  @override
  Stream<VpnState> get stateStream => changes.stream;
  @override
  Future<VpnState> getCurrentState() async => value;
  @override
  Future<_Counters?> sessionTrafficCounters() {
    samples++;
    return delayed?.call() ?? Future.value(counters);
  }

  void status(VpnStatus status) {
    value = VpnState(status: status);
    changes.add(value);
  }

  @override
  void dispose() {
    changes.close();
    super.dispose();
  }
}

class _Notifier extends VpnStateNotifier {
  int probes = 0;
  int reconnects = 0;
  Completer<List<PingResult>>? pending;
  void Function(PingResult)? result;
  @override
  Future<List<PingResult>> probeAutoSelectCandidates(
    List<ServerItem> servers,
    AppSettings settings, {
    required String testUrl,
    required void Function(PingResult) onResult,
  }) {
    probes++;
    result = onResult;
    pending = Completer<List<PingResult>>();
    return pending!.future;
  }

  @override
  Future<void> reconnectToActiveServer({
    int? expectedGeneration,
    Future<void> Function()? afterDisconnect,
  }) async {
    reconnects++;
  }

  void completeVerdict() {
    const failed = PingResult(
      serverId: 'one',
      serverName: 'one',
      success: false,
      pingType: PingType.url,
    );
    const alive = PingResult(
      serverId: 'two',
      serverName: 'two',
      success: true,
      latencyMs: 10,
      pingType: PingType.url,
    );
    result!(failed);
    result!(alive);
    pending!.complete([failed, alive]);
  }
}

void main() {
  final servers = ['one', 'two']
      .map(
        (id) => ServerItem(
          id: id,
          type: ServerItemType.subscription,
          subscriptionId: 'sub',
          config:
              'vless://00000000-0000-4000-8000-000000000000@198.51.100.10:443?type=tcp&security=none#$id',
        ),
      )
      .toList();
  late ProviderContainer container;
  late _Backend backend;
  late _Notifier notifier;
  var ownsContainer = false;

  void check(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        if (ownsContainer) container.dispose();
        ownsContainer = false;
        backend.dispose();
        await tester.pump();
      }
    });
  }

  Future<void> setup(WidgetTester tester) async {
    backend = _Backend();
    final storage = await buildStorageService();
    await storage.saveSettings(
      AppSettings.fromJson({'connectionMode': 'proxy'}),
    );
    await storage.saveServers(servers);
    await storage.setActiveServerId('one');
    await storage.saveSubscriptions([
      const Subscription(
        id: 'sub',
        name: 'test',
        url: 'https://example.invalid',
        autoSelect: true,
      ),
    ]);
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        vpnEngineProvider.overrideWithValue(VpnEngine.withBackend(backend)),
        vpnStateProvider.overrideWith(_Notifier.new),
      ],
    );
    ownsContainer = true;
    container.read(serversProvider);
    await container.read(subscriptionsProvider.future);
    await container.read(settingsNotifierProvider.future);
    await container.read(vpnStateProvider.future);
    await tester.pump();
    notifier = container.read(vpnStateProvider.notifier) as _Notifier;
  }

  Future<void> tick(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  Future<void> beginProbe(WidgetTester tester) async {
    await tick(tester); // failure/counter baseline
    CoreDialFailures.add(1);
    await tick(tester);
    expect(notifier.probes, 1);
  }

  check('current failed node and live neighbour switch exactly once', (
    tester,
  ) async {
    await setup(tester);
    await beginProbe(tester);
    notifier.completeVerdict();
    await tester.pump();
    await tester.pump();
    expect(container.read(serversProvider).activeServerId, 'two');
    expect(notifier.reconnects, 1);
  });

  check('early switch saves completed verdict before the batch finishes', (
    tester,
  ) async {
    await setup(tester);
    await beginProbe(tester);
    notifier.result!(
      const PingResult(
        serverId: 'one',
        serverName: 'one',
        success: false,
        pingType: PingType.url,
      ),
    );
    notifier.result!(
      const PingResult(
        serverId: 'two',
        serverName: 'two',
        success: true,
        latencyMs: 10,
        pingType: PingType.url,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(notifier.pending!.isCompleted, false);
    expect(container.read(serversProvider).activeServerId, 'two');
    expect(container.read(serversProvider).byId['one']!.lastPingType, 'url');
    expect(container.read(serversProvider).byId['two']!.pingMs, 10);
    expect(notifier.reconnects, 1);
    notifier.pending!.complete([
      const PingResult(
        serverId: 'two',
        serverName: 'two',
        success: true,
        latencyMs: 999,
        pingType: PingType.url,
      ),
    ]);
    await tester.pump();
    expect(container.read(serversProvider).byId['two']!.pingMs, 10);
  });

  check('Auto off while judging rejects late verdict and ping writes', (
    tester,
  ) async {
    await setup(tester);
    await beginProbe(tester);
    await container.read(subscriptionsProvider.notifier).handAutoSelectTo(null);
    notifier.completeVerdict();
    await tester.pump();
    expect(container.read(serversProvider).activeServerId, 'one');
    expect(container.read(serversProvider).byId['two']!.pingMs, isNull);
    expect(notifier.reconnects, 0);
  });

  check('manual desktop selection hands ownership back before old verdict', (
    tester,
  ) async {
    await setup(tester);
    await beginProbe(tester);
    await notifier.selectServerManually(servers[1]);
    expect(
      container.read(subscriptionsProvider).value!.single.autoSelect,
      false,
    );
    notifier.completeVerdict();
    await tester.pump();
    expect(container.read(serversProvider).activeServerId, 'two');
    expect(notifier.reconnects, 0);
  });

  check('changed settings reject old measurements without applying cooldown', (
    tester,
  ) async {
    await setup(tester);
    await beginProbe(tester);
    final settings = await container.read(settingsNotifierProvider.future);
    await container
        .read(settingsNotifierProvider.notifier)
        .save(settings.copyWith(httpPort: 3099));
    notifier.completeVerdict();
    await tester.pump();
    expect(container.read(serversProvider).activeServerId, 'one');
    expect(container.read(serversProvider).byId['two']!.pingMs, isNull);
    expect(notifier.reconnects, 0);
    await tick(tester);
    CoreDialFailures.add(1);
    await tick(tester);
    expect(notifier.probes, 2);
    notifier.pending!.complete([]);
    await tester.pump();
  });

  check('pending judge stays single across new failure samples', (
    tester,
  ) async {
    await setup(tester);
    await beginProbe(tester);
    for (var i = 0; i < 3; i++) {
      CoreDialFailures.add(1);
      await tick(tester);
    }
    expect(notifier.probes, 1);
    notifier.completeVerdict();
    await tester.pump();
    expect(notifier.reconnects, 1);
  });

  check('disposed provider discards late judge completion', (tester) async {
    await setup(tester);
    await beginProbe(tester);
    container.dispose();
    ownsContainer = false;
    notifier.completeVerdict();
    await tester.pump();
    expect(notifier.reconnects, 0);
  });

  for (final emitDisconnect in [false, true]) {
    check(
      'same node new native session rejects verdict (disconnect=$emitDisconnect)',
      (tester) async {
        await setup(tester);
        await beginProbe(tester);
        if (emitDisconnect) backend.status(VpnStatus.disconnected);
        backend.identity = 'helper/session-2';
        if (emitDisconnect) backend.status(VpnStatus.connected);
        notifier.completeVerdict();
        await tester.pump();
        expect(container.read(serversProvider).activeServerId, 'one');
        expect(notifier.reconnects, 0);
        // An obsolete finally must not impose its 15-second quiet period.
        await tick(tester);
        CoreDialFailures.add(1);
        await tick(tester);
        expect(notifier.probes, 2);
        notifier.pending!.complete([]);
        await tester.pump();
      },
    );
  }

  check('slow sample does not overlap or overwrite replacement baseline', (
    tester,
  ) async {
    await setup(tester);
    final pending = Completer<_Counters?>();
    backend.delayed = () => pending.future;
    await tick(tester);
    await tick(tester);
    await tick(tester);
    expect(backend.samples, 1);
    backend.identity = 'helper/session-2';
    backend.delayed = null;
    backend.counters = (down: 100, up: 100);
    pending.complete((down: 100, up: 0));
    await tester.pump();
    await tick(
      tester,
    ); // must establish a new baseline, not count old->new as silence
    for (var i = 1; i <= 4; i++) {
      backend.counters = (down: 100, up: 100 + i);
      await tick(tester);
    }
    expect(notifier.probes, 0);
    backend.counters = (down: 100, up: 105);
    await tick(tester);
    expect(notifier.probes, 1); // unchanged desktop threshold: five samples
    notifier.pending!.complete([]);
    await tester.pump();
  });
}
