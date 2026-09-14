import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_recovery_controller.dart';

Map<String, dynamic> service({
  String network = 'ready',
  String revision = 'wifi',
  bool recovery = false,
  String? recoveryCode,
  bool busy = false,
  bool authorized = true,
}) => {
  'installed': true,
  'protocolVersion': 1,
  'authorized': authorized,
  'proxyWithoutElevation': true,
  'helperEpoch': 'daemon-1',
  'busy': busy,
  'recoveryRequired': recovery,
  'recoveryErrorCode': recoveryCode,
  'networkStatus': {
    'revision': revision,
    for (final mode in ['proxy', 'tun'])
      mode: {
        'state': network,
        'reason': network == 'blocked'
            ? 'vpnRouteConflict'
            : 'physicalNetworkUnavailable',
      },
  },
};

void main() {
  late DateTime time;
  late MacOSRecoveryController controller;
  late List<int> attempts;
  setUp(() {
    time = DateTime(2026);
    attempts = [];
    controller = MacOSRecoveryController(
      now: () => time,
      onChanged: () {},
      attempt: (ticket) async {
        attempts.add(ticket);
      },
    );
  });
  tearDown(() => controller.dispose());
  void poll({
    Map<String, dynamic>? status,
    Map<String, dynamic>? session,
    int seconds = 1,
  }) {
    time = time.add(Duration(seconds: seconds));
    controller.observe(
      service: status ?? service(),
      session: session ?? {'status': 'disconnected'},
    );
  }

  test(
    'offline intent waits without spawning then starts once after stability',
    () async {
      controller.begin(ConnectionMode.tun);
      controller.failed('physicalNetworkUnavailable');
      for (var i = 0; i < 30; i++) {
        poll(status: service(network: 'wait'));
      }
      expect(attempts, isEmpty);
      expect(controller.retries, 0);
      poll();
      poll();
      expect(attempts, isEmpty);
      poll();
      expect(attempts, hasLength(1));
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 10; i++) {
        poll();
      }
      expect(attempts, hasLength(1));
    },
  );

  test('flapping or a different network restarts the stability interval', () {
    controller.begin(ConnectionMode.tun);
    controller.failed('network_changed');
    poll();
    poll();
    poll(status: service(network: 'wait'));
    poll();
    poll(status: service(revision: 'ethernet'));
    poll(status: service(revision: 'ethernet'));
    expect(attempts, isEmpty);
    poll(status: service(revision: 'ethernet'));
    expect(attempts, hasLength(1));
  });

  test('manual cancel invalidates intent and old observations', () {
    final old = controller.begin(ConnectionMode.proxy);
    controller.failed('physicalNetworkUnavailable');
    controller.cancel();
    for (var i = 0; i < 20; i++) {
      poll();
    }
    expect(attempts, isEmpty);
    expect(controller.wanted, isFalse);
    expect(controller.generation, greaterThan(old));
  });

  test('core failures get exactly three backoff retries', () async {
    controller.begin(ConnectionMode.proxy);
    for (var i = 0; i < 3; i++) {
      controller.failed('coreExited', occurrence: 'session-$i');
      poll();
      poll(seconds: 30);
      await Future<void>.delayed(Duration.zero);
      expect(attempts, hasLength(i + 1));
      controller.connected();
    }
    controller.failed('coreExited', occurrence: 'session-4');
    expect(controller.phase, MacOSRecoveryPhase.paused);
    expect(controller.wanted, isFalse);
  });

  test('duplicate native error does not spend budget or reset ready time', () {
    controller.begin(ConnectionMode.proxy);
    controller.connected();
    for (var i = 0; i < 3; i++) {
      poll(
        session: {
          'status': 'error',
          'sessionId': 'same',
          'errorCode': 'coreExited',
        },
      );
    }
    expect(controller.retries, 1);
    expect(attempts, hasLength(1));
  });

  test('five stable minutes replenish the fault budget', () {
    controller.begin(ConnectionMode.proxy);
    controller.failed('coreExited');
    controller.connected();
    poll(seconds: 299, session: {'status': 'connected'});
    expect(controller.retries, 1);
    poll(seconds: 1, session: {'status': 'connected'});
    expect(controller.retries, 0);
  });

  test('pending recovery blocks starts and terminal recovery pauses', () {
    controller.begin(ConnectionMode.tun);
    controller.failed('network_changed');
    for (var i = 0; i < 10; i++) {
      poll(status: service(recovery: true));
    }
    expect(attempts, isEmpty);
    expect(controller.phase, MacOSRecoveryPhase.recovering);
    poll(status: service(recovery: true, recoveryCode: 'recoveryFailed'));
    expect(controller.wanted, isFalse);
  });

  for (final code in [
    'vpnRouteConflict',
    'networkSettingsChanged',
    'unsafeConfiguration',
    'authorizationRequired',
    'protocolMismatch',
    'recoveryCorrupt',
    'ipv6ProtectionUnavailable',
  ]) {
    test('$code needs an explicit user action', () {
      controller.begin(ConnectionMode.tun);
      controller.failed(code);
      for (var i = 0; i < 5; i++) {
        poll();
      }
      expect(attempts, isEmpty);
      expect(controller.phase, MacOSRecoveryPhase.paused);
    });
  }

  test('network loss does not consume crash budget', () {
    controller.begin(ConnectionMode.proxy);
    controller.failed('coreExited');
    controller.failed('physicalNetworkUnavailable');
    for (var i = 0; i < 60; i++) {
      poll(status: service(network: 'wait'));
    }
    expect(controller.retries, 1);
  });

  test('unavailable transport never starts against stale ready data', () {
    controller.begin(ConnectionMode.tun);
    controller.connected();
    for (var i = 0; i < 40; i++) {
      poll(
        session: {
          'status': 'error',
          'transportUnavailable': true,
          'errorCode': 'serviceInterrupted',
        },
      );
    }
    expect(attempts, isEmpty);
    poll();
    poll();
    poll();
    expect(attempts, hasLength(1));
  });

  test('DNS diagnostic warnings do not disconnect a connected session', () {
    controller.begin(ConnectionMode.tun);
    controller.connected();
    poll(
      session: {
        'status': 'connected',
        'dnsDiagnostics': {'status': 'warning'},
      },
    );
    expect(attempts, isEmpty);
    expect(controller.phase, MacOSRecoveryPhase.idle);
  });

  test('changed authorization pauses without making an attempt', () {
    controller.begin(ConnectionMode.tun);
    controller.failed('network_changed');
    poll(status: service(authorized: false));
    expect(controller.wanted, isFalse);
    expect(attempts, isEmpty);
  });
}
