import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/services/vpn_engine.dart';
import 'package:keqdroid/tunnel/macos_tunnel_backend.dart';
import 'package:keqdroid/tunnel/desktop_recovery_status.dart';
import 'package:keqdroid/tunnel/macos_recovery_controller.dart';
import '../helpers/test_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('macos-recovery-provider-tests');
  late ProviderContainer container;
  late MacOSTunnelBackend backend;
  late VpnEngine engine;
  late DateTime time;
  late bool online;
  late int starts;
  late Map<String, dynamic> session;
  Completer<void>? holdStart;
  Completer<void>? enteredStart;
  final server = ServerItem(
    id: 'recovery-node',
    type: ServerItemType.manual,
    config:
        'vless://00000000-0000-4000-8000-000000000000@198.51.100.10:443?type=tcp&security=none#test',
  );

  setUp(() async {
    online = false;
    starts = 0;
    time = DateTime(2026);
    holdStart = null;
    enteredStart = null;
    session = {'status': 'disconnected'};
    backend = MacOSTunnelBackend(channel: channel, enablePolling: false);
    engine = VpnEngine.withBackend(backend);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getServiceStatus':
              return {
                'installed': true,
                'authorized': true,
                'protocolVersion': 1,
                'proxyWithoutElevation': true,
                'helperEpoch': 'test-daemon',
                'recoveryRequired': false,
                'busy': false,
                'networkStatus': {
                  'revision': online ? 'online' : 'offline',
                  'proxy': {
                    'state': online ? 'ready' : 'wait',
                    'reason': 'physicalNetworkUnavailable',
                  },
                  'tun': {
                    'state': online ? 'ready' : 'wait',
                    'reason': 'physicalNetworkUnavailable',
                  },
                },
              };
            case 'getSession':
              return session;
            case 'stopSession':
              session = {'status': 'disconnected'};
              return session;
            case 'startProxySession':
              starts++;
              enteredStart?.complete();
              if (holdStart != null) await holdStart!.future;
              if (!online) {
                throw PlatformException(
                  code: 'physicalNetworkUnavailable',
                  message: 'No physical network',
                );
              }
              session = {
                'status': 'connected',
                'sessionId': (call.arguments as Map)['sessionId'],
                'connectionMode': 'proxy',
              };
              return session;
            default:
              throw StateError('Unexpected method ${call.method}');
          }
        });
    final storage = await buildStorageService();
    await storage.saveSettings(
      AppSettings.fromJson({'connectionMode': 'proxy'}),
    );
    await storage.saveServers([server]);
    await storage.setActiveServerId(server.id);
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        vpnEngineProvider.overrideWithValue(engine),
        macOSRecoveryClockProvider.overrideWithValue(() => time),
      ],
    );
    container.read(serversProvider);
    await container.read(vpnStateProvider.future);
  });
  tearDown(() {
    container.dispose();
    backend.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> poll([int seconds = 1]) async {
    time = time.add(Duration(seconds: seconds));
    await engine.getCurrentState();
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (container.read(vpnStateProvider).value?.status == VpnStatus.connected) {
        return;
      }
    }
  }

  test(
    'offline startup remains waiting and a later ready poll rebuilds once',
    () async {
      await container.read(vpnStateProvider.notifier).connect();
      expect(
        desktopRecoveryStatus.value?.phase,
        MacOSRecoveryPhase.waitingNetwork,
      );
      final initialStarts = starts;
      for (var i = 0; i < 5; i++) {
        await poll();
      }
      expect(starts, initialStarts);
      online = true;
      await poll();
      await poll();
      await poll();
      await settle();
      expect(starts, initialStarts + 1);
      expect(
        container.read(vpnStateProvider).value?.status,
        VpnStatus.connected,
      );
    },
  );

  test(
    'manual disconnect while waiting prevents network recovery starting',
    () async {
      await container.read(vpnStateProvider.notifier).connect();
      await container.read(vpnStateProvider.notifier).disconnect();
      final count = starts;
      online = true;
      for (var i = 0; i < 5; i++) {
        await poll();
      }
      expect(starts, count);
      expect(
        container.read(vpnStateProvider).value?.status,
        VpnStatus.disconnected,
      );
    },
  );

  test('cancel during native startup stops the late session', () async {
    online = true;
    holdStart = Completer<void>();
    enteredStart = Completer<void>();
    final connecting = container.read(vpnStateProvider.notifier).connect();
    await enteredStart!.future;
    final stopping = container.read(vpnStateProvider.notifier).disconnect();
    holdStart!.complete();
    await connecting;
    await stopping;
    await poll();
    expect(session['status'], 'disconnected');
    expect(
      container.read(vpnStateProvider).value?.status,
      VpnStatus.disconnected,
    );
    expect(desktopRecoveryStatus.value, isNull);
  });
}
