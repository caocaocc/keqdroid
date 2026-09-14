import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/screens/servers_tab.dart';
import 'package:keqdroid/services/vpn_engine.dart';
import 'package:keqdroid/ui/desktop/desktop_connection_mode.dart';

import '../helpers/fake_tunnel_backend.dart';
import '../helpers/test_storage.dart';

class _Backend extends FakeTunnelBackend {
  final changes = StreamController<VpnState>.broadcast(sync: true);
  VpnState current = VpnState.connected;
  final starts = <String?>[];
  int stops = 0;
  Completer<void>? holdStop;
  Completer<void>? holdBeforeStop;
  @override
  Stream<VpnState> get stateStream => changes.stream;
  @override
  Future<VpnState> getCurrentState() async => current;
  @override
  Future<void> startSession(TunnelSessionRequest request) async {
    starts.add(request.serverName);
    current = VpnState.connected;
    changes.add(current);
  }

  @override
  Future<void> stopSession() async {
    stops++;
    final before = holdBeforeStop;
    holdBeforeStop = null;
    await before?.future;
    current = VpnState.disconnected;
    changes.add(current);
    final gate = holdStop;
    holdStop = null;
    await gate?.future;
  }

  @override
  void dispose() {
    unawaited(changes.close());
    super.dispose();
  }
}

// Keep the real cancellation/reconnect/provider logic; record its terminal
// connect request without building configs, opening sockets or starting a core.
class _Vpn extends VpnStateNotifier {
  final connections = <String?>[];
  @override
  Future<void> connect({bool autostartTunFallback = false}) async {
    beginConnectionChange();
    connections.add(ref.read(serversProvider).activeServerId);
    state = const AsyncData(VpnState.connected);
  }
}

class _Settings extends SettingsNotifier {
  Completer<void>? hold;
  Completer<void>? entered;
  @override
  Future<void> save(AppSettings settings) async {
    await super.save(settings);
    final gate = hold;
    hold = null;
    entered?.complete();
    entered = null;
    await gate?.future;
  }
}

class _Servers extends ServersNotifier {
  Completer<void>? hold;
  Completer<void>? entered;
  @override
  Future<void> setActive(ServerItem server) async {
    await super.setActive(server);
    final gate = hold;
    hold = null;
    entered?.complete();
    entered = null;
    await gate?.future;
  }
}

class _Subscriptions extends SubscriptionsNotifier {
  Completer<void>? hold;
  @override
  Future<void> handAutoSelectTo(String? ownerId) async {
    await super.handAutoSelectTo(ownerId);
    final gate = hold;
    hold = null;
    await gate?.future;
  }
}

void main() {
  late ProviderContainer container;
  late _Backend backend;
  late _Settings settings;
  late _Servers servers;
  late BuildContext context;
  final nodes = ['One', 'Two', 'Three']
      .map(
        (name) => ServerItem(
          id: name,
          type: ServerItemType.manual,
          customName: name,
          config:
              'vless://00000000-0000-4000-8000-000000000000@198.51.100.10:443?type=tcp&security=none#$name',
        ),
      )
      .toList();

  Future<void> setup(WidgetTester tester, {bool serverPage = false}) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    backend = _Backend();
    final storage = await buildStorageService();
    await storage.saveSettings(
      AppSettings.fromJson({'connectionMode': 'proxy'}),
    );
    await storage.saveServers(nodes);
    await storage.setActiveServerId('One');
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        vpnEngineProvider.overrideWithValue(VpnEngine.withBackend(backend)),
        vpnStateProvider.overrideWith(_Vpn.new),
        settingsNotifierProvider.overrideWith(_Settings.new),
        serversProvider.overrideWith(_Servers.new),
        subscriptionsProvider.overrideWith(_Subscriptions.new),
      ],
    );
    container.read(serversProvider);
    await container.read(settingsNotifierProvider.future);
    await container.read(vpnStateProvider.future);
    settings = container.read(settingsNotifierProvider.notifier) as _Settings;
    servers = container.read(serversProvider.notifier) as _Servers;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                context = ctx;
                return serverPage ? const ServersTab() : const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  void check(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        backend.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        // The connection button's settled-shape animation has a final 200 ms
        // callback. It checks mounted and needs no live provider after unmount.
        await tester.pump(const Duration(milliseconds: 250));
      }
    });
  }

  Future<void> changeMode() => applyDesktopConnectionMode(
    context,
    DesktopModeDeps(
      vpn: container.read(vpnStateProvider.notifier),
      settings: settings,
      status: () => container.read(vpnStateProvider).value?.status,
    ),
    container.read(settingsNotifierProvider).value!,
    ConnectionMode.tun,
  );

  check('manual stop while mode save waits prevents its delayed connect', (
    tester,
  ) async {
    await setup(tester);
    final gate = settings.hold = Completer<void>();
    final entered = settings.entered = Completer<void>();
    final switching = changeMode();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      entered.isCompleted,
      true,
      reason: 'mode reached held settings save',
    );
    await container.read(vpnStateProvider.notifier).disconnect();
    gate.complete();
    await tester.pump();
    await switching;
    expect(
      (container.read(vpnStateProvider.notifier) as _Vpn).connections,
      isEmpty,
    );
    expect(
      container.read(vpnStateProvider).value!.status,
      VpnStatus.disconnected,
    );
  });

  check(
    'manual stop while server selection waits prevents its delayed reconnect',
    (tester) async {
      await setup(tester, serverPage: true);
      final gate = servers.hold = Completer<void>();
      final entered = servers.entered = Completer<void>();
      await tester.tap(find.text('Two').first);
      await tester.pump();
      await entered.future;
      await container.read(vpnStateProvider.notifier).disconnect();
      gate.complete();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        (container.read(vpnStateProvider.notifier) as _Vpn).connections,
        isEmpty,
      );
      expect(
        container.read(vpnStateProvider).value!.status,
        VpnStatus.disconnected,
      );
    },
  );

  for (final beforeDisconnect in [false, true]) {
    check('button cancels a server switch (stop phase=$beforeDisconnect)', (
      tester,
    ) async {
      await setup(tester, serverPage: true);
      final gate = Completer<void>();
      if (beforeDisconnect) {
        backend.holdBeforeStop = gate;
      } else {
        backend.holdStop = gate;
      }
      final switching = container
          .read(vpnStateProvider.notifier)
          .reconnectToActiveServer();
      await tester.pump();
      expect(
        container.read(vpnStateProvider).value!.status,
        beforeDisconnect ? VpnStatus.disconnecting : VpnStatus.disconnected,
      );
      expect(container.read(vpnServerSwitchInProgressProvider), true);
      final before = backend.stops;
      final button = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_ConnectButton',
      );
      await tester.tap(button);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        (container.read(vpnStateProvider.notifier) as _Vpn).connections,
        isEmpty,
      );
      gate.complete();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await switching;
      expect(
        (container.read(vpnStateProvider.notifier) as _Vpn).connections,
        isEmpty,
      );
      expect(backend.stops, before + 1);
    });
  }
  check('normal mode switch saves and reconnects once', (tester) async {
    await setup(tester);
    final switching = changeMode();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await switching;
    expect((container.read(vpnStateProvider.notifier) as _Vpn).connections, [
      'One',
    ]);
    expect(
      container.read(settingsNotifierProvider).value!.connectionMode,
      'tun',
    );
  });

  check('stable current-node selection leaves the connected session alone', (
    tester,
  ) async {
    await setup(tester);
    final vpn = container.read(vpnStateProvider.notifier) as _Vpn;
    final generation = vpn.connectionGeneration;
    final stops = backend.stops;
    await vpn.selectServerManually(nodes[0], reconnectIfActive: true);
    expect(vpn.connectionGeneration, generation);
    expect(backend.stops, stops);
    expect(vpn.connections, isEmpty);
    expect(container.read(vpnStateProvider).value?.status, VpnStatus.connected);
  });

  check('normal manual node change reconnects once', (tester) async {
    await setup(tester, serverPage: true);
    await tester.tap(find.text('Two').first);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect((container.read(vpnStateProvider.notifier) as _Vpn).connections, [
      'Two',
    ]);
  });

  for (final cancelLatest in [false, true]) {
    check('latest node waits for old switch (cancel=$cancelLatest)', (
      tester,
    ) async {
      await setup(tester);
      final vpn = container.read(vpnStateProvider.notifier) as _Vpn;
      final gate = backend.holdStop = Completer<void>();
      final first = vpn.selectServerManually(nodes[1], reconnectIfActive: true);
      await tester.pump();
      expect(container.read(vpnServerSwitchInProgressProvider), true);
      expect(container.read(serversProvider).activeServerId, 'Two');
      final latest = vpn.selectServerManually(
        nodes[2],
        reconnectIfActive: true,
      );
      await tester.pump();
      if (cancelLatest) await vpn.disconnect();
      gate.complete();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await Future.wait([first, latest]);
      expect(vpn.connections, cancelLatest ? isEmpty : ['Three']);
      expect(container.read(serversProvider).activeServerId, 'Three');
    });
  }

  check('new selection wins while an earlier selection save waits', (
    tester,
  ) async {
    await setup(tester);
    final vpn = container.read(vpnStateProvider.notifier) as _Vpn;
    final gate = servers.hold = Completer<void>();
    final first = vpn.selectServerManually(nodes[1], reconnectIfActive: true);
    await tester.pump();
    final latest = vpn.selectServerManually(nodes[2], reconnectIfActive: true);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    gate.complete();
    await Future.wait([first, latest]);
    expect(vpn.connections, ['Three']);
    expect(container.read(serversProvider).activeServerId, 'Three');
  });

  check('selecting the current node cancels an earlier pending choice', (
    tester,
  ) async {
    await setup(tester);
    final vpn = container.read(vpnStateProvider.notifier) as _Vpn;
    final subscriptions =
        container.read(subscriptionsProvider.notifier) as _Subscriptions;
    final gate = subscriptions.hold = Completer<void>();
    final first = vpn.selectServerManually(nodes[1], reconnectIfActive: true);
    await tester.pump();
    expect(container.read(serversProvider).activeServerId, 'One');
    final latest = vpn.selectServerManually(nodes[0], reconnectIfActive: true);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    gate.complete();
    await Future.wait([first, latest]);
    expect(vpn.connections, ['One']);
    expect(container.read(serversProvider).activeServerId, 'One');
  });

  check(
    'node selected while mode save waits keeps the active connection intent',
    (tester) async {
      await setup(tester);
      final vpn = container.read(vpnStateProvider.notifier) as _Vpn;
      final gate = settings.hold = Completer<void>();
      final entered = settings.entered = Completer<void>();
      final mode = changeMode();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(entered.isCompleted, true);
      final node = vpn.selectServerManually(nodes[2], reconnectIfActive: true);
      await tester.pump();
      gate.complete();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await Future.wait([mode, node]);
      expect(vpn.connections, ['Three']);
      expect(
        container.read(settingsNotifierProvider).value!.connectionMode,
        'tun',
      );
    },
  );
}
