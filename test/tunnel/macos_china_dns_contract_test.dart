import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_network_context.dart';
import 'package:keqdroid/tunnel/macos_session_config.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/geo_dat_reader.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

// Export final production requests for Swift's --validate-request, including
// the real bundled CN data. No network operations or user profiles are used.
void main() {
  const link =
      'trojan://test-password@node.example.com:443?sni=node.example.com';
  const settings = AppSettings();
  const context = MacOSNetworkContext(
    contextId: 'test-network',
    interfaceName: 'en0',
    dnsServers: ['192.0.2.53'],
  );

  for (final core in [VpnBackend.xray, VpnBackend.mihomo]) {
    test(
      '${core.name} China defaults fit the final macOS helper contract',
      () async {
        Socks5Credentials().init('test-user', 'test-password');
        final cn = await GeoDatReader.domains(
          File('assets/bin/linux/geosite.dat'),
          'cn',
        );
        expect(cn, isNotEmpty);
        final request = TunnelSessionRequest(
          mode: ConnectionMode.tun,
          vpnBackend: core,
          socksPort: settings.localPort,
          httpPort: settings.httpPort,
          xrayConfig: core == VpnBackend.xray
              ? ConfigGeneratorV2.generateConfig(
                  link,
                  settings,
                  physicalBootstrapDns: true,
                )
              : '',
          singboxConfig: core == VpnBackend.xray
              ? SingBoxTunConfigGen.generate(
                  localSocksPort: settings.localPort,
                  socksUsername: 'test-user',
                  socksPassword: 'test-password',
                  serverIpToExclude: 'node.example.com',
                  settings: settings,
                  chinaDnsDomains: cn,
                  windows: false,
                  macos: true,
                )
              : null,
          mihomoConfig: core == VpnBackend.mihomo
              ? MihomoConfigGen.generate(
                  link,
                  settings,
                  socksPort: settings.localPort,
                  httpPort: settings.httpPort,
                  windows: false,
                  tun: const MihomoTunOptions(stack: 'gvisor'),
                  appProcessPath:
                      '/Applications/KEQDIS.app/Contents/MacOS/KEQDIS',
                )
              : null,
        );
        final name = '${core.name}-tun-china-default';
        final payload = MacOSSessionConfig.build(
          request: request,
          sessionId: name,
          apiPort: 23000,
          apiSecret: 'test-secret-12345678',
          context: context,
        );
        final configs = payload['configurations'] as Map;
        expect(configs.length, 1);
        final text = configs.values.single as String;
        final config = jsonDecode(text) as Map;
        // SessionRequest.swift bounds the serialized configuration and visited
        // JSON values. Actual authorization/policy validation stays in Swift.
        final bytes = utf8.encode(text).length;
        final nodes = _jsonNodes(config);
        expect(bytes, lessThanOrEqualTo(2 * 1024 * 1024));
        expect(nodes, lessThan(100000));
        expect(_jsonDepth(config), lessThan(48));
        final dns = config['dns'] as Map;
        if (core == VpnBackend.xray) {
          final servers = (dns['servers'] as List).cast<Map>();
          final direct = servers.singleWhere((s) => s['tag'] == 'direct-dns');
          final proxy = servers.singleWhere((s) => s['tag'] == 'proxy-dns');
          expect(direct['server'], '223.5.5.5');
          expect(direct.containsKey('detour'), isFalse);
          expect(proxy['server'], '1.1.1.1');
          expect(proxy['detour'], 'proxy');
          final rules = (dns['rules'] as List).cast<Map>();
          expect(rules.first['server'], 'local-dns');
          final china = rules.singleWhere((r) => r['server'] == 'direct-dns');
          final domainCount = [
            'domain',
            'domain_suffix',
            'domain_regex',
          ].fold<int>(0, (n, key) => n + ((china[key] as List?)?.length ?? 0));
          expect(domainCount, greaterThan(1000));
          final embedded =
              (config['outbounds'] as List).cast<Map>().singleWhere(
                    (o) => o['type'] == 'xray',
                  )['xray']
                  as Map;
          final xrayDns = ((embedded['dns'] as Map)['servers'] as List)
              .cast<Map>();
          expect(
            xrayDns.any(
              (s) => s['address'] == 'https+local://1.1.1.1/dns-query',
            ),
            isFalse,
          );
          expect(jsonEncode(embedded['routing']), contains('geosite:cn'));
          expect((config['route'] as Map)['default_interface'], 'en0');
        } else {
          expect(dns['nameserver'], ['https://1.1.1.1/dns-query']);
          expect(dns['proxy-server-nameserver'], ['tcp://223.5.5.5:53#DIRECT']);
          expect((dns['nameserver-policy'] as Map)['geosite:cn'], [
            'tcp://223.5.5.5:53#DIRECT',
          ]);
          expect((dns['nameserver-policy'] as Map)['+.local'], ['system']);
          expect(config['rules'], contains('GEOSITE,cn,DIRECT'));
          expect(config['rules'], contains('GEOIP,cn,DIRECT'));
        }
        // Report size headroom without persisting a duplicate of the geo data.
        // ignore: avoid_print
        print(
          '$name: $bytes configuration bytes, $nodes JSON nodes, ${cn.length} bundled CN domains',
        );
        final export = Platform.environment['KEQDIS_MACOS_FIXTURE_DIR'];
        if (export != null) {
          await Directory(export).create(recursive: true);
          await File('$export/$name.json').writeAsString(jsonEncode(payload));
        }
      },
    );
  }
}

int _jsonNodes(Object? value) =>
    1 +
    switch (value) {
      Map map => map.values.fold<int>(0, (n, item) => n + _jsonNodes(item)),
      List list => list.fold<int>(0, (n, item) => n + _jsonNodes(item)),
      _ => 0,
    };

int _jsonDepth(Object? value) {
  final values = switch (value) {
    Map map => map.values,
    List list => list,
    _ => const <Object?>[],
  };
  return values.fold<int>(0, (depth, item) {
    final child = 1 + _jsonDepth(item);
    return child > depth ? child : depth;
  });
}
