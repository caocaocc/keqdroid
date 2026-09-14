import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/routing_profile.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/models/traffic_route.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/services/rule_list_service.dart';
import 'package:keqdroid/services/vpn_engine.dart';
import 'package:keqdroid/tunnel/macos_tunnel_backend.dart';
import 'package:keqdroid/utils/rule_lists.dart';

import '../helpers/test_storage.dart';

const _url = 'https://rules.example/list';
const _otherUrl = 'https://other.example/list';
const _route = TrafficRoute(
  id: 'main',
  sites: 'old.example',
  target: RouteTarget.direct,
);
const _profile = RoutingProfile(
  id: 'work',
  name: 'Work',
  subscriptionIds: ['subscription'],
  routes: [
    TrafficRoute(
      id: 'work-route',
      sites: 'work.example',
      target: RouteTarget.direct,
    ),
  ],
);

class _HeldLists extends RuleListService {
  final entered = Completer<void>();
  final release = Completer<void>();
  var reads = 0;
  String cached = 'old-cache.example';
  RuleListStatus? refreshed;

  @override
  Future<RuleListDomains> domainsFor(AppSettings settings) async {
    final domains = ruleListUrls(settings.directRules).isEmpty
        ? RuleListDomains.none
        : RuleListDomains(direct: [cached]);
    if (reads++ == 0) {
      entered.complete();
      await release.future;
    }
    return domains;
  }

  @override
  Future<List<String>> domainsForEntries(String entries) async => [];

  @override
  Future<RuleListStatus> refresh(String url) async => refreshed!;
}

// Only avoid background downloads; exercise the real refresh result handling.
class _SeededLists extends RuleListsNotifier {
  _SeededLists(this.initial);
  final Map<String, RuleListStatus> initial;
  @override
  Map<String, RuleListStatus> build() => initial;
}

class _Fixture {
  _Fixture(this.container, this.backend, this.lists, this.starts, this.poll);
  final ProviderContainer container;
  final MacOSTunnelBackend backend;
  final _HeldLists lists;
  final List<Map<dynamic, dynamic>> starts;
  final Future<void> Function() poll;
  VpnStateNotifier get vpn => container.read(vpnStateProvider.notifier);
  String get configuration => jsonEncode(starts.single);

  Future<void> finish(Future<void> first) async {
    lists.release.complete();
    await first;
    for (var i = 0; i < 10 && starts.isEmpty; i++) {
      await poll();
    }
    expect(starts, hasLength(1));
    expect(container.read(vpnStateProvider).value?.status, VpnStatus.connected);
  }
}

Future<_Fixture> _fixture({
  List<TrafficRoute> routes = const [_route],
  List<RoutingProfile> profiles = const [],
  Map<String, RuleListStatus> statuses = const {},
}) async {
  const channel = MethodChannel('macos-routing-preparation-test');
  final backend = MacOSTunnelBackend(channel: channel, enablePolling: false);
  final engine = VpnEngine.withBackend(backend);
  final lists = _HeldLists();
  final starts = <Map<dynamic, dynamic>>[];
  var time = DateTime(2026);
  Map<String, dynamic> session = {'status': 'disconnected'};
  Future<Object?> handler(MethodCall call) async {
    switch (call.method) {
      case 'getServiceStatus':
        return {
          'installed': true,
          'authorized': true,
          'protocolVersion': 1,
          'proxyWithoutElevation': true,
          'helperEpoch': 'helper',
          'recoveryRequired': false,
          'busy': false,
          'networkStatus': {
            'revision': 'ready',
            'proxy': {'state': 'ready'},
            'tun': {'state': 'ready'},
          },
        };
      case 'getSession':
        return session;
      case 'stopSession':
        return session = {'status': 'disconnected'};
      case 'startProxySession':
        final request = call.arguments as Map;
        starts.add(request);
        return session = {
          'status': 'connected',
          'sessionId': request['sessionId'],
          'connectionMode': 'proxy',
        };
      default:
        throw StateError('Unexpected method ${call.method}');
    }
  }

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, handler);
  messenger.setMockMethodCallHandler(
    MacOSTunnelBackend.networkChannel,
    handler,
  );
  final storage = await buildStorageService();
  await storage.saveSettings(
    AppSettings.fromJson({
      'connectionMode': 'proxy',
      'directRules': '',
      'proxyRules': '',
      'blockedRules': '',
    }),
  );
  await storage.saveRoutes(routes);
  await storage.saveRoutingProfiles(profiles);
  final node = ServerItem(
    id: 'node',
    type: ServerItemType.subscription,
    subscriptionId: 'subscription',
    config:
        'vless://00000000-0000-4000-8000-000000000000@198.51.100.10:443?type=tcp&security=none#synthetic',
  );
  await storage.saveServers([node]);
  await storage.setActiveServerId(node.id);
  final container = ProviderContainer(
    overrides: [
      storageProvider.overrideWithValue(storage),
      vpnEngineProvider.overrideWithValue(engine),
      macOSRecoveryClockProvider.overrideWithValue(() => time),
      ruleListServiceProvider.overrideWithValue(lists),
      ruleListsProvider.overrideWith(() => _SeededLists(statuses)),
    ],
  );
  addTearDown(() {
    if (!lists.release.isCompleted) lists.release.complete();
    container.dispose();
    backend.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(MacOSTunnelBackend.networkChannel, null);
  });
  container.read(serversProvider);
  await container.read(settingsNotifierProvider.future);
  await container.read(routesProvider.future);
  await container.read(routingProfilesProvider.future);
  await container.read(vpnStateProvider.future);
  return _Fixture(container, backend, lists, starts, () async {
    time = time.add(const Duration(seconds: 1));
    await engine.getCurrentState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'route edit during preparation cancels old config and rebuilds',
    () async {
      final f = await _fixture();
      final first = f.vpn.connect();
      await f.lists.entered.future;
      final generation = f.vpn.connectionGeneration;
      await f.container
          .read(routesProvider.notifier)
          .upsert(_route.copyWith(sites: 'latest.example'));
      expect(f.vpn.connectionGeneration, greaterThan(generation));
      expect(f.starts, isEmpty);
      await f.finish(first);
      expect(f.lists.reads, 2);
      expect(f.configuration, contains('latest.example'));
      expect(f.configuration, isNot(contains('old.example')));
    },
  );

  for (final change in ['route', 'final outbound', 'disable', 'assignment']) {
    test('active profile $change invalidates held preparation', () async {
      final f = await _fixture(profiles: const [_profile]);
      final first = f.vpn.connect();
      await f.lists.entered.future;
      final generation = f.vpn.connectionGeneration;
      final profiles = f.container.read(routingProfilesProvider.notifier);
      switch (change) {
        case 'route':
          await profiles.upsertRoute(
            'work',
            _profile.routes.single.copyWith(sites: 'latest.example'),
          );
        case 'final outbound':
          await profiles.setFinalOutbound(
            'work',
            AppSettings.finalOutboundDirect,
          );
        case 'disable':
          await profiles.setEnabled('work', false);
        case 'assignment':
          await profiles.setSubscriptions('work', ['other']);
      }
      expect(f.vpn.connectionGeneration, greaterThan(generation));
      expect(f.starts, isEmpty);
      await f.finish(first);
      expect(f.lists.reads, 2);
      if (change == 'route') {
        expect(f.configuration, contains('latest.example'));
      }
      if (change == 'disable' || change == 'assignment') {
        expect(f.configuration, contains('old.example'));
        expect(f.configuration, isNot(contains('work.example')));
      }
    });
  }

  test(
    'profile rename, unrelated profile and shadowed main routes keep preparation',
    () async {
      final f = await _fixture(profiles: const [_profile]);
      final first = f.vpn.connect();
      await f.lists.entered.future;
      final generation = f.vpn.connectionGeneration;
      final profiles = f.container.read(routingProfilesProvider.notifier);
      await profiles.rename('work', 'Renamed');
      await profiles.add(
        const RoutingProfile(
          id: 'other',
          name: 'Other',
          subscriptionIds: ['other-sub'],
          finalOutbound: AppSettings.finalOutboundBlock,
        ),
      );
      await f.container
          .read(routesProvider.notifier)
          .upsert(_route.copyWith(sites: 'unused.example'));
      expect(f.vpn.connectionGeneration, generation);
      await f.finish(first);
      expect(f.lists.reads, 1);
      expect(f.configuration, contains('work.example'));
      expect(f.configuration, isNot(contains('unused.example')));
    },
  );

  for (final event in [
    'changed',
    'failed',
    'same stamp',
    'unused',
    'disabled',
  ]) {
    test(
      'rule-list $event only restarts when effective cached policy changed',
      () async {
        final url = event == 'unused' ? _otherUrl : _url;
        final old = RuleListStatus(
          url: url,
          domains: 1,
          updatedAt: DateTime(2000),
        );
        final f = await _fixture(
          routes: [
            TrafficRoute(
              id: 'list',
              sites: _url,
              target: RouteTarget.direct,
              enabled: event != 'disabled',
            ),
          ],
          statuses: {url: old},
        );
        final first = f.vpn.connect();
        await f.lists.entered.future;
        final generation = f.vpn.connectionGeneration;
        f.lists.cached = 'new-cache.example';
        f.lists.refreshed = RuleListStatus(
          url: url,
          domains: 1,
          updatedAt: event == 'failed' || event == 'same stamp'
              ? old.updatedAt
              : DateTime.now(),
          failure: event == 'failed' ? RuleListFailure.network : null,
        );
        await f.container.read(ruleListsProvider.notifier).refreshStale();
        if (event == 'changed') {
          expect(f.vpn.connectionGeneration, greaterThan(generation));
        } else {
          expect(f.vpn.connectionGeneration, generation);
        }
        await f.finish(first);
        expect(f.lists.reads, event == 'changed' ? 2 : 1);
        if (event == 'changed') {
          expect(f.configuration, contains('new-cache.example'));
          expect(f.configuration, isNot(contains('old-cache.example')));
        }
      },
    );
  }
}
