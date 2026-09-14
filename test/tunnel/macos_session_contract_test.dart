import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/xray_core_settings.dart';
import 'package:keqdroid/services/tunnel_session_builder.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_core_paths.dart';
import 'package:keqdroid/tunnel/macos_network_context.dart';
import 'package:keqdroid/tunnel/macos_session_config.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/geo_dat_reader.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

void main() {
  const link =
      'trojan://test-password@node.example.com:443?sni=node.example.com';
  const awg =
      '[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nAllowedIPs = 0.0.0.0/0\nEndpoint = node.example.com:51820';
  final settings = AppSettings.fromJson({});
  const context = MacOSNetworkContext(
    contextId: 'test-network',
    interfaceName: 'en0',
    dnsServers: ['192.168.1.1'],
  );
  for (final scenario in [
    (name: 'xray', core: VpnBackend.xray, source: link),
    (name: 'mihomo', core: VpnBackend.mihomo, source: link),
    (name: 'awg', core: VpnBackend.mihomo, source: awg),
  ]) {
    final core = scenario.core;
    for (final mode in ConnectionMode.values) {
      test(
        '${scenario.name} ${mode.name} uses the real generator contract',
        () async {
          Socks5Credentials().init('test-user', 'test-password');
          final request = TunnelSessionRequest(
            mode: mode,
            vpnBackend: core,
            socksPort: settings.localPort,
            httpPort: settings.httpPort,
            xrayConfig: core == VpnBackend.xray
                ? ConfigGeneratorV2.generateConfig(
                    scenario.source,
                    settings,
                    localInboundsNoAuth: mode == ConnectionMode.proxy,
                    physicalBootstrapDns:
                        TunnelSessionBuilder.usePhysicalBootstrapDns(
                          mode,
                          isMacOS: true,
                        ),
                  )
                : '',
            mihomoConfig: core == VpnBackend.mihomo
                ? MihomoConfigGen.generate(
                    scenario.source,
                    settings,
                    socksPort: settings.localPort,
                    httpPort: settings.httpPort,
                    windows: false,
                    tun: mode == ConnectionMode.tun
                        ? const MihomoTunOptions(stack: 'gvisor')
                        : null,
                    appProcessPath:
                        '/Applications/KEQDIS.app/Contents/MacOS/KEQDIS',
                    localInboundsNoAuth: mode == ConnectionMode.proxy,
                  )
                : null,
            singboxConfig: core == VpnBackend.xray && mode == ConnectionMode.tun
                ? SingBoxTunConfigGen.generate(
                    localSocksPort: settings.localPort,
                    socksUsername: 'test-user',
                    socksPassword: 'test-password',
                    serverIpToExclude: 'node.example.com',
                    settings: settings,
                    windows: false,
                    macos: true,
                  )
                : null,
          );
          final payload = MacOSSessionConfig.build(
            request: request,
            sessionId: '${scenario.name}-${mode.name}',
            apiPort: 23000,
            apiSecret: 'test-secret-12345678',
            context: mode == ConnectionMode.tun ? context : null,
          );
          final configs = payload['configurations'] as Map;
          final normalized = _normalizedPayload(payload);
          final golden = File(
            'test/fixtures/macos/${scenario.name}-${mode.name}.json',
          );
          if (Platform.environment['UPDATE_MACOS_GOLDENS'] == '1') {
            await golden.parent.create(recursive: true);
            await golden.writeAsString(
              '${const JsonEncoder.withIndent('  ').convert(normalized)}\n',
            );
          }
          expect(
            normalized,
            jsonDecode(await golden.readAsString()),
            reason: 'macOS ${scenario.name}/${mode.name} configuration changed',
          );
          expect(configs.length, 1);
          expect(configs.values.join(), contains('node.example.com'));
          expect(
            payload['core'],
            core == VpnBackend.xray ? 'keqrnel' : 'mihomo',
          );
          expect(configs.containsKey('wireproxy'), isFalse);
          expect(payload.containsKey('wireproxyInfoPort'), isFalse);
          expect(payload['apiSecret'], 'test-secret-12345678');
          if (mode == ConnectionMode.tun) {
            expect(payload['contextId'], 'test-network');
            expect(configs.values.join(), contains('en0'));
            expect(
              configs.values.join(),
              contains(
                '/Library/Application Support/io.github.caocaocc.keqdroid/bin/keqrnel',
              ),
            );
          }
          // Optional cross-language fixture export for NetworkServiceChecks.
          // No network service is contacted and all values are synthetic.
          final export = Platform.environment['KEQDIS_MACOS_FIXTURE_DIR'];
          if (export != null) {
            await Directory(export).create(recursive: true);
            await File(
              '$export/${scenario.name}-${mode.name}.json',
            ).writeAsString(jsonEncode(payload));
          }
        },
      );
    }
  }

  // Upstream's DNS preferences must survive the final, privileged request,
  // alongside the existing CN split and physical bootstrap context.
  for (final backend in [VpnBackend.xray, VpnBackend.mihomo]) {
    for (final mode in ConnectionMode.values) {
      test('${backend.name} ${mode.name} DNS preferences contract', () async {
        const preferences = AppSettings(
          xrayCore: XrayCoreSettings(
            dnsHosts: 'www.example.cn 192.0.2.42\nerror 192.0.2.43',
            dnsPolicy:
                '*.example.cn https://192.0.2.55/custom-dns-query\nhome.local tcp+local://192.0.2.56\ncommand https://192.0.2.57/dns-query',
            concurrentDial: true,
          ),
        );
        Socks5Credentials().init('test-user', 'test-password');
        final name = '${backend.name}-${mode.name}-dns-preferences';
        final payload = MacOSSessionConfig.build(
          request: TunnelSessionRequest(
            mode: mode,
            vpnBackend: backend,
            socksPort: preferences.localPort,
            httpPort: preferences.httpPort,
            xrayConfig: backend == VpnBackend.xray
                ? ConfigGeneratorV2.generateConfig(
                    link,
                    preferences,
                    localInboundsNoAuth: mode == ConnectionMode.proxy,
                    physicalBootstrapDns: mode == ConnectionMode.tun,
                  )
                : '',
            mihomoConfig: backend == VpnBackend.mihomo
                ? MihomoConfigGen.generate(
                    link,
                    preferences,
                    socksPort: preferences.localPort,
                    httpPort: preferences.httpPort,
                    windows: false,
                    localInboundsNoAuth: mode == ConnectionMode.proxy,
                    tun: mode == ConnectionMode.tun
                        ? const MihomoTunOptions(stack: 'gvisor')
                        : null,
                  )
                : null,
            singboxConfig:
                backend == VpnBackend.xray && mode == ConnectionMode.tun
                ? SingBoxTunConfigGen.generate(
                    localSocksPort: preferences.localPort,
                    socksUsername: 'test-user',
                    socksPassword: 'test-password',
                    serverIpToExclude: 'node.example.com',
                    settings: preferences,
                    chinaDnsDomains: const [
                      GeoDomain(
                        type: GeoDomainType.domain,
                        value: 'example.cn',
                      ),
                    ],
                    windows: false,
                    macos: true,
                  )
                : null,
          ),
          sessionId: name,
          apiPort: 23000,
          apiSecret: 'test-secret-12345678',
          context: mode == ConnectionMode.tun ? context : null,
        );
        final configurations = payload['configurations'] as Map;
        final config =
            jsonDecode(configurations.values.single as String) as Map;
        if (backend == VpnBackend.mihomo) {
          expect(config['tcp-concurrent'], isTrue);
          expect((config['hosts'] as Map)['www.example.cn'], '192.0.2.42');
          expect((config['hosts'] as Map)['error'], '192.0.2.43');
          final dns = config['dns'] as Map;
          expect((dns['nameserver-policy'] as Map).keys.take(2), [
            '+.example.cn',
            'home.local',
          ]);
          expect(dns['default-nameserver'], ['tcp://223.5.5.5:53#DIRECT']);
        } else {
          final xray =
              (config['outbounds'] as List).cast<Map>().singleWhere(
                    (outbound) => outbound['type'] == 'xray',
                  )['xray']
                  as Map;
          expect((xray['dns'] as Map)['hosts'], {
            'www.example.cn': '192.0.2.42',
            'error': '192.0.2.43',
          });
          final proxy = (xray['outbounds'] as List).cast<Map>().singleWhere(
            (outbound) => outbound['tag'] == 'proxy',
          );
          final happy =
              ((proxy['streamSettings'] as Map)['sockopt']
                      as Map)['happyEyeballs']
                  as Map;
          expect(happy['tryDelayMs'], greaterThan(0));
          expect(happy['maxConcurrentTry'], greaterThan(0));
          if (mode == ConnectionMode.tun) {
            final rules = ((config['dns'] as Map)['rules'] as List).cast<Map>();
            expect(rules.take(3).map((rule) => rule['server']), [
              'keq-hosts',
              'keq-policy-0',
              'keq-policy-1',
            ]);
            expect(rules.last['server'], 'direct-dns');
          }
        }
        final export = Platform.environment['KEQDIS_MACOS_FIXTURE_DIR'];
        if (export != null) {
          await Directory(export).create(recursive: true);
          await File('$export/$name.json').writeAsString(jsonEncode(payload));
        }
      });
    }
  }
}

Object? _normalizedPayload(Map<String, dynamic> payload) {
  // Only the app/test-runtime location is machine dependent. Credentials,
  // ports, interfaces and endpoints above are fixed synthetic fixtures.
  const fixtureApp = '/Applications/KEQDIS.app/Contents';
  final canonicalPaths = [
    '$fixtureApp/MacOS/KEQDIS',
    for (final name in ['keqrnel', 'mihomo']) ...[
      '${MacOSCorePaths.installedRuntime}/bin/$name',
      '$fixtureApp/Resources/cores/$name',
    ],
  ];
  final replacements = [
    for (var i = 0; i < canonicalPaths.length; i++)
      MapEntry(MacOSCorePaths.bypassExecutablePaths[i], canonicalPaths[i]),
  ]..sort((a, b) => b.key.length.compareTo(a.key.length));
  Object? normalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: normalize(value[key])};
    }
    if (value is List) return value.map(normalize).toList();
    if (value is String) {
      for (final entry in replacements) {
        value = (value as String).replaceAll(entry.key, entry.value);
      }
    }
    return value;
  }

  return normalize({
    ...payload,
    'configurations': {
      for (final entry in (payload['configurations'] as Map).entries)
        entry.key: jsonDecode(entry.value as String),
    },
  });
}
