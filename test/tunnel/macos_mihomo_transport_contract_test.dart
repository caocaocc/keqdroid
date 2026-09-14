import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_network_context.dart';
import 'package:keqdroid/tunnel/macos_session_config.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

// The installed helper used to reject Mihomo's legitimate transport `path`
// fields as filesystem options. Export actual generator output for Swift's
// --validate-request gate, without a parallel implementation of its policy.
// Every endpoint, UUID, account, path and network context here is synthetic.
void main() {
  final settings = AppSettings.fromJson({});
  const context = MacOSNetworkContext(
    contextId: 'test-network',
    interfaceName: 'en0',
    dnsServers: ['192.0.2.53'],
  );
  const scenarios = [
    (network: 'xhttp', query: 'type=xhttp', options: 'xhttp-opts'),
    (network: 'ws', query: 'type=ws', options: 'ws-opts'),
    // In VLESS links, type=http means H2. Mihomo network=http is the TCP
    // HTTP-header transport and therefore comes from headerType=http.
    (network: 'http', query: 'type=tcp&headerType=http', options: 'http-opts'),
    (network: 'h2', query: 'type=h2', options: 'h2-opts'),
  ];

  for (final scenario in scenarios) {
    for (final mode in ConnectionMode.values) {
      test(
        'mihomo ${scenario.network} ${mode.name} preserves its HTTP path',
        () async {
          Socks5Credentials().init('test-user', 'test-password');
          final path = '/keqdis-contract/${scenario.network}';
          final link =
              'vless://00000000-0000-4000-8000-000000000001@node.example.com:443'
              '?${scenario.query}&security=tls&sni=front.example.com'
              '&host=transport.example.com&path=${Uri.encodeComponent(path)}';
          final generated = MihomoConfigGen.generate(
            link,
            settings,
            socksPort: settings.localPort,
            httpPort: settings.httpPort,
            windows: false,
            tun: mode == ConnectionMode.tun
                ? const MihomoTunOptions(stack: 'gvisor')
                : null,
            appProcessPath: '/Applications/KEQDIS.app/Contents/MacOS/KEQDIS',
            localInboundsNoAuth: mode == ConnectionMode.proxy,
          );
          final name = 'mihomo-${mode.name}-transport-${scenario.network}';
          final payload = MacOSSessionConfig.build(
            request: TunnelSessionRequest(
              mode: mode,
              vpnBackend: VpnBackend.mihomo,
              socksPort: settings.localPort,
              httpPort: settings.httpPort,
              xrayConfig: '',
              mihomoConfig: generated,
            ),
            sessionId: name,
            apiPort: 23000,
            apiSecret: 'test-secret-12345678',
            context: mode == ConnectionMode.tun ? context : null,
          );
          final configurations = payload['configurations'] as Map;
          expect(configurations.keys, ['mihomo']);
          final config = jsonDecode(configurations['mihomo'] as String) as Map;
          final proxy = (config['proxies'] as List).cast<Map>().singleWhere(
            (proxy) => proxy['type'] == 'vless',
          );
          expect(proxy['network'], scenario.network);
          final options = proxy[scenario.options] as Map;
          expect(options['path'], scenario.network == 'http' ? [path] : path);
          expect(proxy, (jsonDecode(generated) as Map)['proxies'][0]);
          expect(config['socks-port'], settings.localPort);
          expect(config['port'], settings.httpPort);
          expect(config['external-controller'], '127.0.0.1:23000');
          expect(config['secret'], 'test-secret-12345678');
          if (mode == ConnectionMode.tun) {
            expect((config['tun'] as Map)['enable'], isTrue);
            expect(config['interface-name'], 'en0');
            expect(payload['contextId'], 'test-network');
            expect(config['authentication'], ['test-user:test-password']);
          } else {
            expect(config.containsKey('tun'), isFalse);
            expect(payload.containsKey('contextId'), isFalse);
            expect(config.containsKey('authentication'), isFalse);
          }

          final export = Platform.environment['KEQDIS_MACOS_FIXTURE_DIR'];
          if (export != null) {
            await Directory(export).create(recursive: true);
            await File('$export/$name.json').writeAsString(jsonEncode(payload));
          }
        },
      );
    }
  }
}
