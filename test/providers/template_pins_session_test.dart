import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/models/subscription.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/services/subscription_service.dart';
import 'package:keqdroid/services/vpn_engine.dart';
import 'package:keqdroid/tunnel/macos_tunnel_backend.dart';

import '../helpers/test_storage.dart';

class _Backend extends MacOSTunnelBackend {
  _Backend() : super(enablePolling: false);
  final changes = StreamController<VpnState>.broadcast(sync: true);
  String identity = 'helper/session-a';
  VpnState value = VpnState.disconnected;
  @override
  String? get activeSessionIdentity => identity;
  @override
  Stream<VpnState> get stateStream => changes.stream;
  @override
  Future<VpnState> getCurrentState() async => value;
  void status(VpnStatus status) {
    value = VpnState(status: status);
    changes.add(value);
  }

  @override
  void dispose() {
    unawaited(changes.close());
    super.dispose();
  }
}

class _Notifier extends VpnStateNotifier {
  final calls = <(String, String)>[];
  final replies = <Completer<bool>>[];
  @override
  Future<bool> selectTemplatePin(String group, String member) {
    calls.add((group, member));
    final reply = Completer<bool>();
    replies.add(reply);
    return reply.future;
  }
}

void main() {
  final body = File(
    'test/fixtures/subscription_payloads/clash-template-main-groups.txt',
  ).readAsStringSync();
  final servers = [
    for (final config in SubscriptionService.parseBodyForTest(body))
      ServerItem.fromRaw(config, subscriptionId: 'sub'),
  ];
  late ProviderContainer container;
  late _Backend backend;
  late _Notifier notifier;

  Future<void> setup(WidgetTester tester) async {
    final storage = await buildStorageService();
    await storage.saveSettings(AppSettings.fromJson({}));
    await storage.saveServers(servers);
    await storage.setActiveServerId(servers.first.id);
    await storage.setClashTemplate('sub', body);
    await storage.saveSubscriptions([
      const Subscription(
        id: 'sub',
        name: 'fixture',
        url: 'https://example.invalid/sub',
        groupChoices: {
          '💎 Trial': '🇩🇪 Germany #1',
          '⚡ Auto': '🇳🇱 Netherlands #1',
        },
      ),
    ]);
    backend = _Backend();
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        vpnEngineProvider.overrideWithValue(VpnEngine.withBackend(backend)),
        vpnStateProvider.overrideWith(_Notifier.new),
      ],
    );
    container.read(serversProvider);
    await container.read(subscriptionsProvider.future);
    await container.read(settingsNotifierProvider.future);
    await container.read(vpnStateProvider.future);
    notifier = container.read(vpnStateProvider.notifier) as _Notifier;
    backend.status(VpnStatus.connected);
    await tester.pump();
    expect(notifier.calls, [('💎 Trial', '🇩🇪 Germany #1')]);
  }

  Future<void> finish(WidgetTester tester) async {
    container.dispose();
    backend.dispose();
    for (final reply in notifier.replies) {
      if (!reply.isCompleted) reply.complete(false);
    }
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('pins retry only failed groups in the same connected session', (
    tester,
  ) async {
    await setup(tester);
    notifier.replies[0].complete(false);
    await tester.pump();
    expect(notifier.calls.last, ('⚡ Auto', '🇳🇱 Netherlands #1'));
    notifier.replies[1].complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(notifier.calls, [
      ('💎 Trial', '🇩🇪 Germany #1'),
      ('⚡ Auto', '🇳🇱 Netherlands #1'),
      ('💎 Trial', '🇩🇪 Germany #1'),
    ]);
    notifier.replies[2].complete(true);
    await tester.pump(const Duration(seconds: 3));
    expect(notifier.calls, hasLength(3));
    await finish(tester);
  });

  for (final change in ['generation', 'session', 'server', 'disconnect']) {
    testWidgets('late pin result cannot continue after $change changes', (
      tester,
    ) async {
      await setup(tester);
      switch (change) {
        case 'generation':
          notifier.beginConnectionChange();
        case 'session':
          backend.identity = 'helper/session-b';
        case 'server':
          await container.read(serversProvider.notifier).setActive(servers[1]);
        case 'disconnect':
          backend.status(VpnStatus.disconnected);
      }
      notifier.replies[0].complete(false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(notifier.calls, hasLength(1));
      await finish(tester);
    });
  }

  testWidgets('old retry cannot write pins after a new session connects', (
    tester,
  ) async {
    await setup(tester);
    notifier.replies[0].complete(false);
    await tester.pump();
    notifier.replies[1].complete(false);
    await tester.pump(); // Old attempt is sleeping before its retry.
    notifier.beginConnectionChange();
    backend.status(VpnStatus.disconnected);
    backend.identity = 'helper/session-b';
    backend.status(VpnStatus.connected);
    await tester.pump();
    expect(notifier.calls, hasLength(3));
    notifier.replies[2].complete(true);
    await tester.pump();
    notifier.replies[3].complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(notifier.calls, hasLength(4));
    await finish(tester);
  });
}
