import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_recovery_controller.dart';

void main() {
  late MacOSRecoveryController recovery;
  late DateTime now;
  late int attempts;
  const service = <String, dynamic>{
    'installed': true,
    'authorized': true,
    'proxyWithoutElevation': true,
    'protocolVersion': 1,
    'helperEpoch': 'same-running-daemon',
    'recoveryRequired': false,
    'busy': false,
    'networkStatus': {
      'revision': 'same-physical-network',
      'proxy': {'state': 'ready'},
      'tun': {'state': 'ready'},
    },
  };
  setUp(() {
    now = DateTime(2026);
    attempts = 0;
    recovery = MacOSRecoveryController(
      now: () => now,
      onChanged: () {},
      attempt: (_) async {
        attempts++;
        recovery.connected();
      },
    );
    recovery.begin(ConnectionMode.proxy);
    recovery.connected();
  });
  tearDown(() => recovery.dispose());
  Future<void> poll(Map<String, dynamic> session, [int seconds = 1]) async {
    now = now.add(Duration(seconds: seconds));
    recovery.observe(service: service, session: session);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'separate unexpected disconnects under one helper spend separate retries',
    () async {
      const first = {'status': 'disconnected', 'sessionId': 'first-session'};
      await poll(first);
      await poll(first, 10);
      expect(attempts, 1);
      expect(recovery.phase, MacOSRecoveryPhase.idle);
      const second = {'status': 'disconnected', 'sessionId': 'second-session'};
      await poll(second);
      await poll(second, 10);
      expect(
        attempts,
        2,
        reason:
            'The second session is a new failure, even though its helper has not restarted.',
      );
      expect(recovery.retries, 2);
    },
  );

  test(
    'native serviceUnavailable transport code receives bounded retry',
    () async {
      await poll({
        'status': 'error',
        'sessionId': 'session',
        'transportUnavailable': true,
        'errorCode': 'serviceUnavailable',
      });
      expect(recovery.wanted, isTrue);
      expect(recovery.phase, MacOSRecoveryPhase.backoff);
      expect(attempts, 0);
      await poll({'status': 'disconnected'}, 10);
      await poll({'status': 'disconnected'}, 3);
      expect(attempts, 1);
    },
  );

  test(
    'second independent XPC interruption for one session is not deduplicated',
    () async {
      const interrupted = {
        'status': 'error',
        'sessionId': 'same-session',
        'transportUnavailable': true,
        'errorCode': 'serviceInterrupted',
      };
      await poll(interrupted);
      expect(recovery.retries, 1);
      // A recovered reply confirms the original core still lives.
      await poll({'status': 'connected', 'sessionId': 'same-session'});
      expect(recovery.phase, MacOSRecoveryPhase.idle);
      await poll(interrupted);
      expect(
        recovery.phase,
        MacOSRecoveryPhase.backoff,
        reason:
            'A newly lost transport after confirmed recovery is a new occurrence.',
      );
      expect(recovery.retries, 2);
    },
  );
}
