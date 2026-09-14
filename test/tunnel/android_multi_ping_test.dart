import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/tunnel/android_tunnel_backend.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('keqdis_vpn_channel');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidTunnelBackend backend;
  late List<MethodCall> calls;
  Object? response;

  setUp(() {
    backend = AndroidTunnelBackend();
    calls = [];
    response = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (response is PlatformException) throw response!;
      return response;
    });
  });
  tearDown(() {
    backend.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final value in [
    null,
    <Object>[],
    PlatformException(code: 'start_failed'),
  ]) {
    test(
      'native batch failure $value requests existing split fallback',
      () async {
        response = value;
        expect(
          await backend.xrayUrlTestMulti(
            config: '{}',
            probes: [('one', 31001), ('two', 31002)],
          ),
          isNull,
        );
        expect(calls.single.method, 'xrayUrlTestMulti');
      },
    );
  }

  test(
    'all individual HTTP failures remain results, not a failed batch',
    () async {
      response = [
        {
          'id': 'one',
          'success': false,
          'error': 'HTTP 503',
          'httpStatus': 503,
          'latencyMs': 20,
        },
        {'id': 'two', 'success': false, 'error': 'connection timed out'},
      ];
      final result = await backend.xrayUrlTestMulti(
        config: '{"dns":{}}',
        probes: [('one', 31001), ('two', 31002)],
        core: VpnBackend.mihomo,
        testUrl: 'https://example.test/check?q=one',
        timeoutMs: 1200,
        keepAlive: false,
        concurrency: 2,
      );
      expect(result, [
        (
          id: 'one',
          success: false,
          latencyMs: 20,
          error: 'HTTP 503',
          httpStatus: 503,
        ),
        (
          id: 'two',
          success: false,
          latencyMs: null,
          error: 'connection timed out',
          httpStatus: null,
        ),
      ]);
      expect(calls.single.arguments, {
        'config': '{"dns":{}}',
        'core': 'mihomo',
        'testUrl': 'https://example.test/check?q=one',
        'timeoutMs': 1200,
        'keepAlive': false,
        'concurrency': 2,
        'probes': [
          {'id': 'one', 'port': 31001},
          {'id': 'two', 'port': 31002},
        ],
      });
    },
  );

  test(
    'mixed success and HTTP failure preserve identities and timings',
    () async {
      response = [
        {'id': 'one', 'success': true, 'latencyMs': 12, 'httpStatus': 204},
        {'id': 'two', 'success': false, 'error': 'HTTP 502', 'httpStatus': 502},
      ];
      final result = await backend.xrayUrlTestMulti(
        config: '{}',
        probes: [('one', 31001), ('two', 31002)],
      );
      expect(result![0], (
        id: 'one',
        success: true,
        latencyMs: 12,
        error: '',
        httpStatus: 204,
      ));
      expect(result[1].id, 'two');
      expect(result[1].success, isFalse);
      expect(result[1].httpStatus, 502);
    },
  );

  test('empty input does not launch native work', () async {
    expect(await backend.xrayUrlTestMulti(config: '{}', probes: []), isEmpty);
    expect(calls, isEmpty);
  });
}
