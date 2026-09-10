import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';
import 'package:keqdroid/tunnel/macos_tunnel_backend.dart';
import 'package:keqdroid/tunnel/macos_network_context.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/tunnel_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.keqdroid.macos.network');
  const desktop = MethodChannel('test.keqdroid.macos.desktop');
  late MacOSTunnelBackend backend;
  late List<MethodCall> calls;
  late Map<String, dynamic> service;
  Map<String, dynamic> snapshot = {'status': 'disconnected'};
  setUp(() {
    calls = [];
    service = {
      'installed': true,
      'authorized': false,
      'proxyWithoutElevation': true,
      'protocolVersion': 1,
    };
    snapshot = {'status': 'disconnected'};
    backend = MacOSTunnelBackend(
      channel: channel,
      desktop: desktop,
      enablePolling: false,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'getServiceStatus':
              return service;
            case 'authorize':
              return {...service, 'authorized': true};
            case 'prepareNetworkContext':
              return {
                'contextId': 'test-network',
                'interfaceName': 'en0',
                'dnsServers': ['192.168.1.1'],
              };
            case 'startProxySession':
            case 'startSession':
              final args = call.arguments as Map;
              snapshot = {
                'status': 'connected',
                'sessionId': args['sessionId'],
                'connectionMode': args['connectionMode'],
                'apiPort': args['apiPort'],
                'apiSecret': args['apiSecret'],
                'pids': {'keqrnel': 123},
              };
              return snapshot;
            case 'stopSession':
              snapshot = {'status': 'disconnected'};
              return snapshot;
            case 'getSession':
              return snapshot;
          }
          throw MissingPluginException(call.method);
        });
  });
  tearDown(() {
    backend.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(desktop, null);
  });

  test(
    'proxy sends a fixed core contract and cleans up its own session',
    () async {
      await backend.startSession(
        const TunnelSessionRequest(
          mode: ConnectionMode.proxy,
          xrayConfig: '{"outbounds":[]}',
        ),
      );
      expect((await backend.getCurrentState()).status, VpnStatus.connected);
      final start =
          calls
                  .singleWhere((call) => call.method == 'startProxySession')
                  .arguments
              as Map;
      expect(start['core'], 'keqrnel');
      expect(start['systemProxy'], isTrue);
      expect(calls.any((call) => call.method == 'authorize'), isFalse);
      expect(calls.any((call) => call.method == 'startSession'), isFalse);
      expect(start['configurations'], contains('keqrnel'));
      expect(start.containsKey('executablePath'), isFalse);
      expect(
        calls.any((call) => call.method == 'prepareNetworkContext'),
        isFalse,
      );
      await backend.stopSession();
      final stop =
          calls.lastWhere((call) => call.method == 'stopSession').arguments
              as Map;
      expect(stop['sessionId'], start['sessionId']);
      expect((await backend.getCurrentState()).status, VpnStatus.disconnected);
    },
  );

  test(
    'login Proxy needs a matching helper, while login TUN needs its grant',
    () {
      expect(
        MacOSTunnelBackend.canConnectWithoutPrompt(
          service,
          ConnectionMode.proxy,
        ),
        isTrue,
      );
      expect(
        MacOSTunnelBackend.canConnectWithoutPrompt(service, ConnectionMode.tun),
        isFalse,
      );
      service['authorized'] = true;
      expect(
        MacOSTunnelBackend.canConnectWithoutPrompt(service, ConnectionMode.tun),
        isTrue,
      );
      service.remove('proxyWithoutElevation');
      expect(
        MacOSTunnelBackend.canConnectWithoutPrompt(
          service,
          ConnectionMode.proxy,
        ),
        isFalse,
      );
      service['protocolVersion'] = 0;
      expect(
        MacOSTunnelBackend.canConnectWithoutPrompt(service, ConnectionMode.tun),
        isFalse,
      );
    },
  );

  test(
    'old helper cannot fall back to administrator authorization for proxy',
    () async {
      service.remove('proxyWithoutElevation');
      await expectLater(
        backend.startSession(
          const TunnelSessionRequest(
            mode: ConnectionMode.proxy,
            xrayConfig: '{"outbounds":[]}',
          ),
        ),
        throwsException,
      );
      expect(calls.map((call) => call.method), ['getServiceStatus']);
      expect(backend.currentState.errorMessage, contains('updated'));
    },
  );

  test(
    'TUN still requires authorization before preparing system DNS',
    () async {
      await backend.startSession(
        TunnelSessionRequest(
          mode: ConnectionMode.tun,
          xrayConfig: '{"outbounds":[]}',
          singboxConfig: SingBoxTunConfigGen.generate(
            localSocksPort: 2080,
            socksUsername: 'test-user',
            socksPassword: 'test-password',
            serverIpToExclude: '192.0.2.1',
            settings: const AppSettings(),
            windows: false,
            macos: true,
          ),
        ),
      );
      final methods = calls.map((call) => call.method).toList();
      expect(methods.indexOf('authorize'), greaterThanOrEqualTo(0));
      expect(
        methods.indexOf('authorize'),
        lessThan(methods.indexOf('prepareNetworkContext')),
      );
      expect(methods, contains('startSession'));
      expect(methods, isNot(contains('startProxySession')));
    },
  );

  test('declined TUN permission cannot prepare DNS or start a core', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getServiceStatus' || call.method == 'authorize') {
            return service;
          }
          throw StateError('Unexpected operation: ${call.method}');
        });
    await expectLater(
      backend.startSession(
        const TunnelSessionRequest(
          mode: ConnectionMode.tun,
          xrayConfig: '{"outbounds":[]}',
        ),
      ),
      throwsException,
    );
    expect(calls.map((call) => call.method), ['getServiceStatus', 'authorize']);
  });

  test('invalid native success cannot be presented as connected', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getServiceStatus') {
            return {
              'installed': true,
              'authorized': false,
              'proxyWithoutElevation': true,
              'protocolVersion': 1,
            };
          }
          return {'status': 'unknown'};
        });
    await expectLater(
      backend.startSession(
        const TunnelSessionRequest(
          mode: ConnectionMode.proxy,
          xrayConfig: '{"outbounds":[]}',
        ),
      ),
      throwsException,
    );
    expect(backend.currentState.status, VpnStatus.error);
  });

  test('stop during service lookup never starts a core', () async {
    final lookup = Completer<Map<String, dynamic>>();
    final entered = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getServiceStatus') {
            entered.complete();
            return lookup.future;
          }
          return {'status': 'disconnected'};
        });
    final start = backend.startSession(
      const TunnelSessionRequest(
        mode: ConnectionMode.proxy,
        xrayConfig: '{"outbounds":[]}',
      ),
    );
    await entered.future;
    final stop = backend.stopSession();
    lookup.complete({
      'installed': true,
      'authorized': false,
      'protocolVersion': 1,
    });
    await Future.wait([start, stop]);
    expect(calls.any((call) => call.method == 'startProxySession'), isFalse);
    expect(calls.any((call) => call.method == 'authorize'), isFalse);
    expect(backend.currentState.status, VpnStatus.disconnected);
  });

  test(
    'a poll started before connect cannot overwrite the new session',
    () async {
      final poll = Completer<Map<String, dynamic>>();
      final entered = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getSession') {
              entered.complete();
              return poll.future;
            }
            if (call.method == 'getServiceStatus') {
              return service;
            }
            if (call.method == 'startProxySession') {
              final args = call.arguments as Map;
              return {
                'status': 'connected',
                'sessionId': args['sessionId'],
                'connectionMode': 'proxy',
              };
            }
            return {'status': 'disconnected'};
          });
      final oldPoll = backend.getCurrentState();
      await entered.future;
      await backend.startSession(
        const TunnelSessionRequest(
          mode: ConnectionMode.proxy,
          xrayConfig: '{"outbounds":[]}',
        ),
      );
      poll.complete({'status': 'disconnected'});
      await oldPoll;
      expect(backend.currentState.status, VpnStatus.connected);
    },
  );

  test(
    'restored TUN gives temporary cores original DNS and clears it on stop',
    () async {
      snapshot = {
        'status': 'connected',
        'sessionId': 'restored-session',
        'connectionMode': 'tun',
        'networkContext': {
          'contextId': 'original',
          'interfaceName': 'en0',
          'dnsServers': ['192.168.1.1'],
        },
      };
      await backend.getCurrentState();
      expect(MacOSNetworkContext.active?.bootstrapEnvironment, {
        'KEQDIS_BOOTSTRAP_DNS': '["192.168.1.1"]',
        'KEQDIS_BOOTSTRAP_INTERFACE': 'en0',
      });
      await backend.stopSession();
      expect(MacOSNetworkContext.active, isNull);
    },
  );

  test(
    'app enumeration and icons stay on the ordinary desktop channel',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(desktop, (call) async {
            if (call.method == 'getInstalledApps') {
              expect((call.arguments as Map)['includeSystem'], isTrue);
              return [
                {
                  'packageName': '/Applications/App.app/Contents/MacOS/App',
                  'appName': 'App',
                },
              ];
            }
            expect(call.method, 'getAppIcon');
            expect(
              (call.arguments as Map)['path'],
              '/Applications/App.app/Contents/MacOS/App',
            );
            return 'base64-icon';
          });
      final apps = await backend.getInstalledApps(includeSystem: true);
      expect(apps.single['appName'], 'App');
      expect(
        await backend.getAppIcon(apps.single['packageName'] as String),
        'base64-icon',
      );
      expect(calls, isEmpty);
    },
  );

  test('network replacement requests one full reconnect', () async {
    snapshot = {
      'status': 'error',
      'sessionId': 'changed-network',
      'connectionMode': 'tun',
      'requiresReconnect': true,
      'errorCode': 'network_changed',
      'error': 'Physical network changed',
    };
    await backend.getCurrentState();
    expect(backend.takeNetworkChangeRequest(), isTrue);
    await backend.getCurrentState();
    expect(backend.takeNetworkChangeRequest(), isFalse);
    expect(backend.currentState.status, VpnStatus.error);
  });

  test(
    'failed restoration stays recoverable without claiming disconnected',
    () async {
      snapshot = {
        'status': 'connected',
        'sessionId': 'restore-failure',
        'connectionMode': 'proxy',
      };
      await backend.getCurrentState();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'stopSession') {
              throw PlatformException(code: 'restoreFailed');
            }
            return {'status': 'disconnected'};
          });
      await expectLater(backend.stopSession(), throwsException);
      expect(backend.currentState.status, VpnStatus.error);
      // The helper can finish recovery later. A failed stop must not leave the
      // backend permanently in disconnecting, where polling is suspended.
      expect((await backend.getCurrentState()).status, VpnStatus.disconnected);
    },
  );
}
