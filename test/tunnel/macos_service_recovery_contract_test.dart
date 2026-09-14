import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_recovery_controller.dart';
import 'package:keqdroid/tunnel/macos_service_observation.dart';
import 'package:keqdroid/tunnel/macos_tunnel_backend.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/tunnel_state.dart';

/// These observations mirror the native identity gate after helper restart:
/// getServiceStatus remains readable while the old journal owner makes
/// getSession fail with busy. No installed helper or sockets are used.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> readyService() => {
    'installed': true,
    'protocolVersion': 1,
    'authorized': true,
    'proxyWithoutElevation': true,
    'helperEpoch': 'new-helper',
    'busy': false,
    'recoveryRequired': false,
    'networkStatus': {
      'revision': 'physical-network',
      'proxy': {'state': 'ready', 'reason': 'ready'},
      'tun': {'state': 'ready', 'reason': 'ready'},
    },
  };

  test('native cleanup status takes priority over inaccessible old owner', () {
    final controller = MacOSRecoveryController(
      attempt: (_) async => fail('Cleanup must finish before reconnecting'),
      onChanged: () {},
    );
    addTearDown(controller.dispose);
    controller.begin(ConnectionMode.tun);
    controller.connected();
    controller.observe(
      service: {
        ...readyService(),
        'busy': true,
        'recoveryRequired': true,
        'recoveryErrorCode': 'recoveryRequired',
      },
      session: {
        'status': 'error',
        'transportUnavailable': true,
        'errorCode': 'busy',
      },
    );
    expect(controller.wanted, isTrue);
    expect(controller.phase, MacOSRecoveryPhase.recovering);
    expect(controller.retries, 0);
  });

  test('native serviceUnavailable transport error has a finite retry path', () {
    final controller = MacOSRecoveryController(
      attempt: (_) async =>
          fail('A transport failure is not service readiness'),
      onChanged: () {},
    );
    addTearDown(controller.dispose);
    controller.begin(ConnectionMode.proxy);
    controller.connected();
    controller.observe(
      service: readyService(),
      session: {
        'status': 'error',
        'transportUnavailable': true,
        'errorCode': 'serviceUnavailable',
      },
    );
    expect(controller.wanted, isTrue);
    expect(controller.phase, MacOSRecoveryPhase.backoff);
    expect(controller.retries, 1);
  });

  for (final status in ['connected', 'error']) {
    test('terminal cleanup beats a stale $status session', () {
      final controller = MacOSRecoveryController(
        attempt: (_) async => fail('Terminal cleanup cannot retry'),
        onChanged: () {},
      );
      addTearDown(controller.dispose);
      controller.begin(ConnectionMode.tun);
      controller.connected();
      controller.observe(
        service: {
          ...readyService(),
          'recoveryRequired': true,
          'recoveryErrorCode': 'recoveryFailed',
        },
        session: {
          'status': status,
          'transportUnavailable': true,
          'errorCode': 'busy',
        },
      );
      expect(controller.wanted, isFalse);
      expect(controller.reason, 'recoveryFailed');
      expect(controller.retries, 0);
    });
  }

  group('native start outcome contract', () {
    const channel = MethodChannel('test.keqdroid.macos.recovery.contract');
    const request = TunnelSessionRequest(
      mode: ConnectionMode.proxy,
      xrayConfig: '{"outbounds":[]}',
    );
    late MacOSTunnelBackend backend;
    late List<String> calls;
    late Map<String, dynamic> service;
    late Map<String, dynamic> snapshot;
    late String startError;
    String? stopError;
    void Function()? afterStart;
    late bool readsUnavailable;
    setUp(() {
      calls = [];
      service = readyService();
      snapshot = {'status': 'disconnected'};
      startError = 'requestOutcomeUnknown';
      stopError = null;
      afterStart = null;
      readsUnavailable = false;
      backend = MacOSTunnelBackend(channel: channel, enablePolling: false);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'getServiceStatus') {
              if (readsUnavailable) {
                throw PlatformException(code: 'serviceUnavailable');
              }
              return service;
            }
            if (call.method == 'getSession') return snapshot;
            if (call.method == 'startProxySession') {
              final args = call.arguments as Map;
              snapshot = {
                ...snapshot,
                'sessionId': args['sessionId'],
                'connectionMode': 'proxy',
                'helperEpoch': service['helperEpoch'],
              };
              afterStart?.call();
              throw PlatformException(code: startError);
            }
            if (call.method == 'stopSession') {
              if (stopError != null) throw PlatformException(code: stopError!);
              return {'status': 'disconnected'};
            }
            throw StateError('Unexpected operation: ${call.method}');
          });
    });
    tearDown(() {
      backend.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    for (final automatic in [false, true]) {
      for (final code in ['recoveryRequired', 'recoveryFailed']) {
        test(
          '$code never resets cleanup after ${automatic ? "automatic" : "manual"} start',
          () async {
            startError = code;
            await expectLater(
              backend.startSession(request, allowPermissionPrompt: !automatic),
              throwsA(predicate((error) => macOSFailureCode(error!) == code)),
            );
            expect(calls, isNot(contains('stopSession')));
          },
        );
      }
    }
    test('automatic preflight preserves terminal cleanup code', () async {
      service.addAll({
        'recoveryRequired': true,
        'recoveryErrorCode': 'recoveryFailed',
      });
      await expectLater(
        backend.startSession(request, allowPermissionPrompt: false),
        throwsA(
          predicate((error) => macOSFailureCode(error!) == 'recoveryFailed'),
        ),
      );
      expect(calls, ['getServiceStatus']);
    });
    test(
      'manual recovery preflight leaves explicit residual cleanup without a false session ID',
      () async {
        service.addAll({
          'recoveryRequired': true,
          'recoveryErrorCode': 'recoveryFailed',
        });
        await expectLater(
          backend.startSession(request),
          throwsA(
            predicate((error) => macOSFailureCode(error!) == 'recoveryFailed'),
          ),
        );
        expect(calls, ['getServiceStatus']);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'stopSession');
              expect((call.arguments as Map).containsKey('sessionId'), isFalse);
              return {'status': 'disconnected'};
            });
        await backend.stopSession();
      },
    );
    test(
      'lost start reply accepts only confirmed matching connected session',
      () async {
        snapshot = {'status': 'connected'};
        await backend.startSession(request);
        expect(backend.currentState.status, VpnStatus.connected);
        expect(calls, [
          'getServiceStatus',
          'startProxySession',
          'getServiceStatus',
          'getSession',
        ]);
      },
    );
    test(
      'uncertain connecting session is retained without stop or replay',
      () async {
        snapshot = {'status': 'connecting'};
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            backend.startSession(request, allowPermissionPrompt: false),
            throwsA(
              predicate(
                (error) => macOSFailureCode(error!) == 'requestOutcomeUnknown',
              ),
            ),
          );
        }
        expect(
          calls.where((method) => method == 'startProxySession'),
          hasLength(1),
        );
        expect(calls, isNot(contains('stopSession')));
        snapshot['status'] = 'connected';
        expect((await backend.getCurrentState()).status, VpnStatus.connected);
      },
    );
    for (final mismatch in ['epoch', 'session']) {
      test('lost start reply rejects a connected $mismatch mismatch', () async {
        snapshot = {'status': 'connected'};
        afterStart = () {
          if (mismatch == 'epoch') {
            service['helperEpoch'] = 'different-helper';
          } else {
            snapshot['sessionId'] = 'different-session';
          }
        };
        await expectLater(
          backend.startSession(request),
          throwsA(
            predicate(
              (error) => macOSFailureCode(error!) == 'requestOutcomeUnknown',
            ),
          ),
        );
        expect(backend.currentState.status, isNot(VpnStatus.connected));
        expect(calls, isNot(contains('stopSession')));
      });
    }
    test(
      'reconciliation reports terminal recovery without querying old owner',
      () async {
        afterStart = () => service.addAll({
          'busy': true,
          'recoveryRequired': true,
          'recoveryErrorCode': 'recoveryFailed',
        });
        await expectLater(
          backend.startSession(request),
          throwsA(
            predicate((error) => macOSFailureCode(error!) == 'recoveryFailed'),
          ),
        );
        expect(calls, [
          'getServiceStatus',
          'startProxySession',
          'getServiceStatus',
        ]);
      },
    );
    test(
      'a confirmed disconnected outcome permits a later fresh start',
      () async {
        await expectLater(
          backend.startSession(request),
          throwsA(
            predicate(
              (error) => macOSFailureCode(error!) == 'requestOutcomeUnknown',
            ),
          ),
        );
        snapshot = {'status': 'connected'};
        await backend.startSession(request, allowPermissionPrompt: false);
        expect(backend.currentState.status, VpnStatus.connected);
        expect(
          calls.where((method) => method == 'startProxySession'),
          hasLength(2),
        );
        expect(calls, isNot(contains('stopSession')));
      },
    );
    test(
      'unavailable reconciliation cannot replay an uncertain start',
      () async {
        snapshot = {'status': 'connecting'};
        await expectLater(backend.startSession(request), throwsException);
        readsUnavailable = true;
        await expectLater(
          backend.startSession(request, allowPermissionPrompt: false),
          throwsA(
            predicate(
              (error) => macOSFailureCode(error!) == 'requestOutcomeUnknown',
            ),
          ),
        );
        expect(
          calls.where((method) => method == 'startProxySession'),
          hasLength(1),
        );
        expect(calls, isNot(contains('stopSession')));
      },
    );
    test(
      'cleanup failure takes priority over the original start error',
      () async {
        startError = 'coreExited';
        stopError = 'recoveryFailed';
        await expectLater(
          backend.startSession(request),
          throwsA(
            predicate((error) => macOSFailureCode(error!) == 'recoveryFailed'),
          ),
        );
        expect(calls.where((method) => method == 'stopSession'), hasLength(1));
      },
    );
  });
}
