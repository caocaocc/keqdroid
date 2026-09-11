import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/services/tunnel_session_builder.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_network_context.dart';
import 'package:keqdroid/tunnel/macos_session_config.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

// Export the final production payload, not a second implementation of the
// helper policy. macOS CI feeds these requests to Swift's --validate-request.
// All node, account, DNS and network-context values are synthetic.
void main() {
  const link =
      'trojan://test-password@node.example.com:443?sni=node.example.com';
  const defaults = AppSettings();
  const context = MacOSNetworkContext(
    contextId: 'test-network',
    interfaceName: 'en0',
    dnsServers: ['192.0.2.53'],
  );
  final cases = [
    (name: 'default', dns: null, type: 'https', path: null, direct: false),
    (
      name: 'doh-direct',
      dns: 'https+local://192.0.2.54/dns-query',
      type: 'https',
      path: '/dns-query',
      direct: true,
    ),
    (
      name: 'doh-proxy',
      dns: 'https://192.0.2.54/custom-dns-query',
      type: 'https',
      path: '/custom-dns-query',
      direct: false,
    ),
    (
      name: 'bare-ip',
      dns: '192.0.2.54',
      type: 'tcp',
      path: null,
      direct: false,
    ),
  ];

  for (final scenario in cases) {
    test(
      '${scenario.name} DNS survives final macOS session generation',
      () async {
        Socks5Credentials().init('test-user', 'test-password');
        final settings = scenario.dns == null
            ? defaults
            : defaults.copyWith(
                xrayCore: defaults.xrayCore.copyWith(
                  dnsUseCustom: true,
                  dnsServers: scenario.dns,
                ),
              );
        final payload = MacOSSessionConfig.build(
          request: TunnelSessionRequest(
            mode: ConnectionMode.tun,
            vpnBackend: VpnBackend.xray,
            socksPort: settings.localPort,
            httpPort: settings.httpPort,
            xrayConfig: ConfigGeneratorV2.generateConfig(
              link,
              settings,
              physicalBootstrapDns:
                  TunnelSessionBuilder.usePhysicalBootstrapDns(
                    ConnectionMode.tun,
                    isMacOS: true,
                  ),
            ),
            singboxConfig: SingBoxTunConfigGen.generate(
              localSocksPort: settings.localPort,
              socksUsername: 'test-user',
              socksPassword: 'test-password',
              serverIpToExclude: 'node.example.com',
              settings: settings,
              windows: false,
              macos: true,
            ),
          ),
          sessionId: 'xray-tun-dns-${scenario.name}',
          apiPort: 23000,
          apiSecret: 'test-secret-12345678',
          wireproxyInfoPort: 23001,
          context: context,
        );
        final config =
            jsonDecode((payload['configurations'] as Map)['keqrnel'] as String)
                as Map;
        final dns = config['dns'] as Map;
        final upstream = (dns['servers'] as List).cast<Map>().singleWhere(
          (server) => server['tag'] == dns['final'],
        );
        expect(upstream['type'], scenario.type);
        expect(upstream['path'], scenario.path);
        expect(upstream['detour'], scenario.direct ? isNull : 'proxy');
        if (scenario.dns != null) {
          expect(upstream['server'], '192.0.2.54');
        }
        expect((config['route'] as Map)['default_interface'], 'en0');
        final export = Platform.environment['KEQDIS_MACOS_FIXTURE_DIR'];
        if (export != null) {
          await Directory(export).create(recursive: true);
          await File(
            '$export/xray-tun-dns-${scenario.name}.json',
          ).writeAsString(jsonEncode(payload));
        }
      },
    );
  }
}
