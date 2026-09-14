import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/traffic_route.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_network_context.dart';
import 'package:keqdroid/tunnel/macos_session_config.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';
import 'package:keqdroid/utils/app_routes.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

// Real import/generator/session adapters, with synthetic credentials and no
// running core. CI passes these exact payloads to the native request validator.
void main() {
  final settings = AppSettings.fromJson({});
  const context = MacOSNetworkContext(
    contextId: 'upstream-template-context',
    interfaceName: 'en0',
    dnsServers: ['192.168.1.1'],
  );
  const routes = [
    RouteAppRules(
      tag: 'keq-route-placed',
      apps: [],
      target: RouteTarget.direct,
      entries: 'placed.example',
      network: RouteNetwork.tcp,
      ports: [(443, 443)],
      ownOrder: true,
    ),
    RouteAppRules(
      tag: 'keq-app-filtered',
      apps: ['/Applications/Example.app/Contents/MacOS/Example'],
      target: RouteTarget.direct,
      allTraffic: true,
      network: RouteNetwork.udp,
      ports: [(5353, 5353)],
    ),
  ];
  for (final core in [VpnBackend.xray, VpnBackend.mihomo]) {
    for (final mode in ConnectionMode.values) {
      test(
        '${core.name} ${mode.name} upstream template native contract',
        () async {
          Socks5Credentials().init('fixture-user', 'fixture-password');
          final tun = mode == ConnectionMode.tun;
          final input = jsonEncode(core == VpnBackend.xray ? _xray : _mihomo);
          final payload = MacOSSessionConfig.build(
            request: TunnelSessionRequest(
              mode: mode,
              vpnBackend: core,
              socksPort: settings.localPort,
              httpPort: settings.httpPort,
              xrayConfig: core == VpnBackend.xray
                  ? ConfigGeneratorV2.generateConfig(
                      input,
                      settings,
                      localInboundsNoAuth: !tun,
                      macosTunRouting: tun,
                      physicalBootstrapDns: tun,
                      appRoutes: routes,
                    )
                  : '',
              mihomoConfig: core == VpnBackend.mihomo
                  ? MihomoConfigGen.generate(
                      input,
                      settings,
                      socksPort: settings.localPort,
                      httpPort: settings.httpPort,
                      windows: false,
                      localInboundsNoAuth: !tun,
                      tun: tun ? const MihomoTunOptions(stack: 'gvisor') : null,
                      appRoutes: routes,
                    )
                  : null,
              singboxConfig: core == VpnBackend.xray && tun
                  ? SingBoxTunConfigGen.generate(
                      localSocksPort: settings.localPort,
                      socksUsername: 'fixture-user',
                      socksPassword: 'fixture-password',
                      serverIpToExclude: 'node.example.com',
                      settings: settings,
                    )
                  : null,
            ),
            sessionId: '${core.name}-${mode.name}-upstream-template',
            apiPort: 23000,
            apiSecret: 'fixture-api-secret-12345678',
            context: tun ? context : null,
          );
          final configs = payload['configurations'] as Map;
          final config = jsonDecode(configs.values.single as String) as Map;
          if (core == VpnBackend.xray) {
            final xray =
                (config['outbounds'] as List).cast<Map>().singleWhere(
                      (entry) => entry['type'] == 'xray',
                    )['xray']
                    as Map;
            expect(xray.keys, isNot(contains('api')));
            expect((xray['log'] as Map).keys, isNot(contains('access')));
            final outbounds = (xray['outbounds'] as List).cast<Map>();
            final node = outbounds.singleWhere(
              (entry) => entry['tag'] == 'author',
            );
            expect((node['settings'] as Map).containsKey('reverse'), isFalse);
            final rules = ((xray['routing'] as Map)['rules'] as List)
                .cast<Map>();
            expect(rules.any((rule) => rule.containsKey('webhook')), isFalse);
            expect(
              rules.any(
                (rule) => rule['network'] == 'tcp' && rule['port'] == '443',
              ),
              isTrue,
            );
            expect(
              rules.any(
                (rule) =>
                    rule['network'] == 'udp' &&
                    rule['port'] == '5353' &&
                    rule['process'] is List,
              ),
              tun,
            );
            expect(
              (xray['dns'] as Map)['hosts'],
              containsPair('webhook', '192.0.2.10'),
            );
          } else {
            expect(config['mode'], 'rule');
            for (final key in [
              'ss-config',
              'vmess-config',
              'tuic-server',
              'iptables',
              'listeners',
            ]) {
              expect(config.containsKey(key), isFalse, reason: key);
            }
            expect(
              (config['ntp'] as Map).containsKey('write-to-system'),
              isFalse,
            );
            expect((config['dns'] as Map).containsKey('listen'), isFalse);
            final groups = (config['proxy-groups'] as List).cast<Map>();
            expect(
              groups.any(
                (group) =>
                    group['name'] == 'Auto / group' &&
                    group['type'] == 'url-test',
              ),
              isTrue,
            );
            expect(configs.values.single, contains('NETWORK,TCP'));
            expect(configs.values.single, contains('DST-PORT,443'));
            expect((config['hosts'] as Map)['webhook'], '192.0.2.10');
          }
          // Import/generation must never mutate the saved provider configuration.
          expect(jsonEncode(core == VpnBackend.xray ? _xray : _mihomo), input);
          final export = Platform.environment['KEQDIS_MACOS_FIXTURE_DIR'];
          if (export != null) {
            await Directory(export).create(recursive: true);
            await File(
              '$export/${core.name}-${mode.name}-upstream-template.json',
            ).writeAsString(jsonEncode(payload));
          }
        },
      );
    }
  }
}

const _xray = {
  'api': {
    'listen': '0.0.0.0:10085',
    'services': ['HandlerService'],
  },
  'log': {'access': '/private/var/root/never-write'},
  'dns': {
    'servers': ['tcp+local://223.5.5.5:53'],
    'hosts': {'webhook': '192.0.2.10'},
  },
  'outbounds': [
    {
      'protocol': 'vless',
      'tag': 'author',
      'settings': {
        'address': 'node.example.com',
        'port': 443,
        'id': '00000000-0000-4000-8000-000000000001',
        'encryption': 'none',
        'reverse': {'tag': 'remote'},
      },
      'streamSettings': {
        'network': 'tcp',
        'security': 'tls',
        'tlsSettings': {'serverName': 'node.example.com'},
      },
    },
    {'protocol': 'freedom', 'tag': 'direct'},
  ],
  'routing': {
    'rules': [
      {
        'type': 'field',
        'domain': ['domain:author.example'],
        'outboundTag': 'direct',
        'webhook': {'url': 'https://example.invalid/never-call'},
      },
    ],
  },
};

const _mihomo = {
  'mode': 'global',
  'ss-config': 'ss://fixture@0.0.0.0:23456',
  'vmess-config': {'port': 23457},
  'tuic-server': {'enable': true, 'listen': '0.0.0.0:23458'},
  'iptables': {'enable': true},
  'listeners': [
    {'name': 'foreign', 'type': 'http', 'port': 23459},
  ],
  'ntp': {'enable': false, 'write-to-system': true},
  'hosts': {'webhook': '192.0.2.10'},
  'dns': {
    'enable': true,
    'listen': '0.0.0.0:53',
    'nameserver': ['tcp://223.5.5.5:53'],
  },
  'proxies': [
    {
      'name': 'node, one',
      'type': 'socks5',
      'server': 'node.example.com',
      'port': 443,
    },
  ],
  'proxy-groups': [
    {
      'name': 'Web, sites',
      'type': 'select',
      'proxies': ['Auto / group'],
    },
    {
      'name': 'Auto / group',
      'type': 'url-test',
      'proxies': ['node, one'],
      'url': 'https://example.invalid/generate_204',
      'interval': 300,
    },
  ],
  'rules': ['DOMAIN,author.example,DIRECT', 'MATCH,Web, sites'],
};
