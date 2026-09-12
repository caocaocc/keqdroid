import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/tun_settings.dart';
import 'package:keqdroid/tunnel/app_routing_mode.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_network_context.dart';
import 'package:keqdroid/tunnel/macos_session_config.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';

void main() {
  final context = MacOSNetworkContext.fromMap({
    'contextId': 'network-1',
    'interfaceName': 'en0',
    'dnsServers': ['192.168.1.1'],
    'serviceIds': ['wifi-service'],
    'hasIpv6': false,
  });
  String tun({bool macos = true}) => SingBoxTunConfigGen.generate(
    localSocksPort: 2080,
    socksUsername: 'user',
    socksPassword: 'password',
    serverIpToExclude: '203.0.113.8',
    settings: AppSettings.fromJson({}),
    windows: false,
    macos: macos,
    routingMode: AppRoutingMode.onlySelected,
    managedProcessPaths: const ['/Applications/Chat.app/Contents/MacOS/Chat'],
  );

  test('Darwin delegates utun allocation and matches full process paths', () {
    final config = jsonDecode(tun()) as Map<String, dynamic>;
    final inbound = (config['inbounds'] as List).first as Map;
    expect(inbound.containsKey('interface_name'), isFalse);
    expect(inbound.containsKey('strict_route'), isFalse);
    final rules = (config['route'] as Map)['rules'] as List;
    expect(
      rules.whereType<Map>().any(
        (rule) =>
            (rule['process_path'] as List?)?.contains(
              '/Applications/Chat.app/Contents/MacOS/Chat',
            ) ==
            true,
      ),
      isTrue,
    );
    final linux = jsonDecode(tun(macos: false)) as Map;
    expect((linux['inbounds'] as List).first['interface_name'], 'tun-keqdis');
  });

  test('Mihomo path rules do not reduce executable paths to process names', () {
    final rules = MihomoConfigGen.buildProcessRules(
      routingMode: AppRoutingMode.onlySelected,
      managedProcessNames: const [],
      managedProcessPaths: const ['/Applications/Chat.app/Contents/MacOS/Chat'],
      appProcessName: '',
      proxyTarget: 'PROXY',
      windows: false,
    );
    expect(
      rules,
      contains('PROCESS-PATH,/Applications/Chat.app/Contents/MacOS/Chat,PROXY'),
    );
  });

  test(
    'TUN wrapper keeps endpoint domains and supplies an authenticated API',
    () {
      final request = TunnelSessionRequest(
        mode: ConnectionMode.tun,
        xrayConfig: jsonEncode({
          'inbounds': [
            {'protocol': 'socks', 'listen': '127.0.0.1', 'port': 2080},
            {'protocol': 'http', 'listen': '127.0.0.1', 'port': 2081},
          ],
          'outbounds': [
            {'protocol': 'freedom', 'tag': 'proxy'},
          ],
        }),
        singboxConfig: tun(),
      );
      final payload = MacOSSessionConfig.build(
        request: request,
        sessionId: 'session-1',
        context: context,
        apiPort: 23000,
        apiSecret: 'session-secret-123456',
      );
      expect(payload['contextId'], 'network-1');
      expect(payload['dnsAddress'], '172.19.0.2');
      final config =
          jsonDecode((payload['configurations'] as Map)['keqrnel'] as String)
              as Map;
      expect(
        config['experimental']['clash_api']['secret'],
        'session-secret-123456',
      );
      expect(config['route']['default_interface'], 'en0');
      expect(config['inbounds'].first.containsKey('interface_name'), isFalse);
    },
  );

  test('custom Mihomo DNS range determines its virtual resolver address', () {
    final request = TunnelSessionRequest(
      mode: ConnectionMode.tun,
      vpnBackend: VpnBackend.mihomo,
      xrayConfig: '',
      mihomoConfig: jsonEncode({
        'dns': {
          'enable': true,
          'fake-ip-range': '198.19.1.1/16',
          'nameserver': ['https://9.9.9.9/dns-query'],
        },
        'tun': {'enable': true, 'device': 'tun-keqdis'},
      }),
    );
    final payload = MacOSSessionConfig.build(
      request: request,
      sessionId: 'session-1',
      context: context,
      apiPort: 23000,
      apiSecret: 'session-secret-123456',
    );
    expect(payload['dnsAddress'], '198.19.1.2');
    final config =
        jsonDecode((payload['configurations'] as Map)['mihomo'] as String)
            as Map;
    expect(config['dns']['nameserver'], ['https://9.9.9.9/dns-query']);
    expect(config['tun'].containsKey('device'), isFalse);
  });

  test(
    'TUN rejects absent physical DNS and proxy does not require a context',
    () {
      expect(
        () => MacOSNetworkContext.fromMap({
          'contextId': 'bad',
          'interfaceName': 'utun0',
          'dnsServers': ['172.19.0.2'],
        }),
        throwsFormatException,
      );
      expect(
        () => MacOSNetworkContext.fromMap({
          'contextId': 'bad',
          'interfaceName': 'en0',
          'dnsServers': [],
        }),
        throwsFormatException,
      );
      final payload = MacOSSessionConfig.build(
        request: const TunnelSessionRequest(
          mode: ConnectionMode.proxy,
          xrayConfig: '{"outbounds":[]}',
        ),
        sessionId: 'proxy-1',
        apiPort: 23000,
        apiSecret: 'session-secret-123456',
      );
      expect(payload.containsKey('dnsAddress'), isFalse);
      expect(payload.containsKey('contextId'), isFalse);
    },
  );

  test('IPv6 protection cannot silently degrade to an IPv4-only session', () {
    const ipv6Context = MacOSNetworkContext(
      contextId: 'dual-stack',
      interfaceName: 'en0',
      dnsServers: ['192.168.1.1'],
      hasIpv6: true,
    );
    Map<String, dynamic> build(VpnBackend core, String tunConfig) =>
        MacOSSessionConfig.build(
          request: TunnelSessionRequest(
            mode: ConnectionMode.tun,
            vpnBackend: core,
            xrayConfig: '{"outbounds":[]}',
            mihomoConfig: '{}',
            singboxConfig: tunConfig,
            blockIpv6Leak: true,
          ),
          sessionId: 'ipv6-check',
          apiPort: 23000,
          apiSecret: 'session-secret-123456',
          context: ipv6Context,
        );
    expect(() => build(VpnBackend.mihomo, tun()), throwsFormatException);
    expect(() => build(VpnBackend.xray, tun()), throwsFormatException);
    final dualStackTun = SingBoxTunConfigGen.generate(
      localSocksPort: 2080,
      socksUsername: 'user',
      socksPassword: 'password',
      serverIpToExclude: 'node.example.com',
      windows: false,
      macos: true,
      hostHasIpv6: true,
      settings: AppSettings.fromJson({}).copyWith(
        tun: const TunSettings(blockIpv6Leak: true),
      ),
    );
    final valid = build(VpnBackend.xray, dualStackTun);
    expect(valid['blockIpv6Leak'], isTrue);
    expect(
      (valid['configurations'] as Map)['keqrnel'],
      contains('fdfe:dcba:9876::1/126'),
    );
  });

  test('raw HTTP providers remain local to the session and preserve URLs', () {
    Map<String, dynamic> build(Map<String, dynamic> provider) =>
        MacOSSessionConfig.build(
          request: TunnelSessionRequest(
            mode: ConnectionMode.proxy,
            vpnBackend: VpnBackend.mihomo,
            xrayConfig: '',
            mihomoConfig: jsonEncode({
              'proxy-providers': {'remote': provider},
            }),
          ),
          sessionId: 'raw-provider',
          apiPort: 23000,
          apiSecret: 'session-secret-123456',
        );
    final valid = build({
      'type': 'http',
      'url': 'https://provider.example/config',
      'path': 'providers/cache.yaml',
    });
    final config =
        jsonDecode((valid['configurations'] as Map)['mihomo'] as String) as Map;
    expect(
      config['proxy-providers']['remote']['url'],
      'https://provider.example/config',
    );
    for (final path in [
      '/etc/secret',
      '../outside.yaml',
      'cache/../../outside.yaml',
    ]) {
      expect(
        () => build({'type': 'http', 'path': path}),
        throwsFormatException,
      );
    }
    expect(
      () => build({'type': 'file', 'path': 'local.yaml'}),
      throwsFormatException,
    );
  });

  test(
    'raw Mihomo uses packaged Geo data and rejects unsupported databases',
    () {
      Map<String, dynamic> build(Map<String, dynamic> config) =>
          MacOSSessionConfig.build(
            request: TunnelSessionRequest(
              mode: ConnectionMode.proxy,
              vpnBackend: VpnBackend.mihomo,
              xrayConfig: '',
              mihomoConfig: jsonEncode(config),
            ),
            sessionId: 'raw-geo',
            apiPort: 23000,
            apiSecret: 'session-secret-123456',
          );
      final payload = build({
        'geo-auto-update': true,
        'geo-update-interval': 24,
        'geox-url': {'geoip': 'https://example.invalid/geoip.dat'},
        'rules': ['GEOIP,CN,DIRECT', 'GEOSITE,cn,DIRECT'],
      });
      final config =
          jsonDecode((payload['configurations'] as Map)['mihomo'] as String)
              as Map;
      expect(config['geodata-mode'], isTrue);
      expect(config['geo-auto-update'], isFalse);
      expect(config.containsKey('geo-update-interval'), isFalse);
      expect(config.containsKey('geox-url'), isFalse);
      expect(config['rules'], ['GEOIP,CN,DIRECT', 'GEOSITE,cn,DIRECT']);
      for (final unsupported in [
        {'geodata-mode': false},
        {
          'rules': ['IP-ASN,64512,DIRECT'],
        },
        {
          'sub-rules': {
            'nested': ['AND,((IP-ASN,64512)),DIRECT'],
          },
        },
      ]) {
        expect(
          () => build(unsupported),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'reason',
              contains('unsupportedGeoData'),
            ),
          ),
        );
      }
    },
  );

  test('TUN rejects proxy provider content fetched after validation', () {
    expect(
      () => MacOSSessionConfig.build(
        request: TunnelSessionRequest(
          mode: ConnectionMode.tun,
          vpnBackend: VpnBackend.mihomo,
          xrayConfig: '',
          mihomoConfig: jsonEncode({
            'proxy-providers': {
              'remote': {
                'type': 'http',
                'url': 'https://example.invalid/proxies.yaml',
                'path': 'providers/remote.yaml',
              },
            },
          }),
        ),
        sessionId: 'tun-provider',
        context: context,
        apiPort: 23000,
        apiSecret: 'session-secret-123456',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'reason',
          contains('inline proxies'),
        ),
      ),
    );
  });

  test('virtual DNS refuses public addresses and reserved listener ports', () {
    expect(
      () => MacOSSessionConfig.mihomoDnsAddress({
        'fake-ip-range': '198.18.0.1/1',
      }),
      throwsFormatException,
    );
    expect(
      () =>
          MacOSSessionConfig.mihomoDnsAddress({'fake-ip-range': '8.8.8.1/24'}),
      throwsFormatException,
    );
    expect(
      () => MacOSSessionConfig.build(
        request: const TunnelSessionRequest(
          mode: ConnectionMode.proxy,
          xrayConfig: '{"outbounds":[]}',
          socksPort: 53,
        ),
        sessionId: 'port-check',
        apiPort: 23000,
        apiSecret: 'session-secret-123456',
      ),
      throwsFormatException,
    );
  });
}
