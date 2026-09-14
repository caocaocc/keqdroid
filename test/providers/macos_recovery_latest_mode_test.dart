import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/services/vpn_engine.dart';
import 'package:keqdroid/tunnel/desktop_recovery_status.dart';
import 'package:keqdroid/tunnel/macos_tunnel_backend.dart';
import '../helpers/test_storage.dart';

class _HeldStopBackend extends MacOSTunnelBackend {
  _HeldStopBackend({required super.channel}) : super(enablePolling: false);
  Completer<void>? holdStop;
  Completer<void>? enteredStop;
  @override
  Future<void> stopSession() async {
    enteredStop?.complete();
    enteredStop = null;
    await holdStop?.future;
    return super.stopSession();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'waiting recovery uses the latest mode after two changes during cleanup',
    () async {
      const channel = MethodChannel('macos-latest-mode-regression');
      var online = false;
      var starts = 0;
      var time = DateTime(2026);
      Map<String, dynamic> session = {'status': 'disconnected'};
      final backend = _HeldStopBackend(channel: channel);
      final engine = VpnEngine.withBackend(backend);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Future<Object?> handler(MethodCall call) async {
        switch (call.method) {
          case 'getServiceStatus':
            return {
              'installed': true,
              'authorized': true,
              'protocolVersion': 1,
              'proxyWithoutElevation': true,
              'helperEpoch': 'test-helper',
              'recoveryRequired': false,
              'busy': false,
              'networkStatus': {
                'revision': online ? 'ready' : 'offline',
                'proxy': {
                  'state': online ? 'ready' : 'wait',
                  'reason': 'physicalNetworkUnavailable',
                },
                'tun': {
                  'state': online ? 'blocked' : 'wait',
                  'reason': online
                      ? 'vpnRouteConflict'
                      : 'physicalNetworkUnavailable',
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
            if (!online) {
              throw PlatformException(
                code: 'physicalNetworkUnavailable',
                message: 'Synthetic offline state',
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
      }

      messenger.setMockMethodCallHandler(channel, handler);
      messenger.setMockMethodCallHandler(
        MacOSTunnelBackend.networkChannel,
        handler,
      );
      final storage = await buildStorageService();
      final original = AppSettings.fromJson({'connectionMode': 'proxy'});
      await storage.saveSettings(original);
      final node = ServerItem(
        id: 'latest-mode-node',
        type: ServerItemType.manual,
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
        ],
      );
      addTearDown(() {
        container.dispose();
        backend.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(
          MacOSTunnelBackend.networkChannel,
          null,
        );
      });
      container.read(serversProvider);
      await container.read(vpnStateProvider.future);
      await container.read(settingsNotifierProvider.future);
      await container.read(vpnStateProvider.notifier).connect();
      final initialStarts = starts;
      backend.holdStop = Completer<void>();
      backend.enteredStop = Completer<void>();
      final entered = backend.enteredStop!.future;
      await container
          .read(settingsNotifierProvider.notifier)
          .save(original.copyWith(connectionMode: 'tun'));
      await entered;
      await container
          .read(settingsNotifierProvider.notifier)
          .save(original.copyWith(connectionMode: 'proxy'));
      backend.holdStop!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      backend.holdStop = null;
      online = true;
      for (var i = 0; i < 8; i++) {
        time = time.add(const Duration(seconds: 1));
        await engine.getCurrentState();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        starts,
        initialStarts + 1,
        reason:
            'Latest mode is Proxy, so a TUN-only route conflict cannot pause recovery. ${desktopRecoveryStatus.value?.reason}',
      );
      expect(
        container.read(vpnStateProvider).value?.status,
        VpnStatus.connected,
      );
      expect(
        container.read(vpnStateProvider).value?.activeMode,
        ConnectionMode.proxy,
      );
    },
  );
}
