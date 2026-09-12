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
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

// Actual production generators, exported to Swift's strict request validator.
// All endpoints, credentials and network context values are synthetic.
void main() {
  const link =
      'trojan://test-password@node.example.com:443?sni=node.example.com';
  const context = MacOSNetworkContext(
    contextId: 'test-network',
    interfaceName: 'en0',
    dnsServers: ['192.0.2.53'],
  );
  for (final core in [VpnBackend.xray, VpnBackend.mihomo]) {
    for (final mode in ConnectionMode.values) {
      for (final authenticated in [false, true]) {
        final name =
            '${core.name}-${mode.name}-lan-${authenticated ? 'auth' : 'noauth'}';
        test(
          '$name preserves generated listeners and source restrictions',
          () async {
            Socks5Credentials().init('local-test-user', 'local-test-password');
            final settings = AppSettings.fromJson({}).copyWith(
              lanSharing: true,
              lanSocksPort: 11080,
              lanHttpPort: 18080,
              lanUsername: authenticated ? 'lan-test-user' : '',
              lanPassword: authenticated ? 'lan-test-password' : '',
            );
            final xray = core == VpnBackend.xray
                ? ConfigGeneratorV2.generateConfig(
                    link,
                    settings,
                    localInboundsNoAuth: mode == ConnectionMode.proxy,
                    physicalBootstrapDns: mode == ConnectionMode.tun,
                  )
                : '';
            final mihomo = core == VpnBackend.mihomo
                ? MihomoConfigGen.generate(
                    link,
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
                : null;
            final request = TunnelSessionRequest(
              mode: mode,
              vpnBackend: core,
              socksPort: settings.localPort,
              httpPort: settings.httpPort,
              lan: LanProxySettings(
                socksPort: settings.lanSocksPort,
                httpPort: settings.lanHttpPort,
                username: settings.lanUsername,
                password: settings.lanPassword,
              ),
              xrayConfig: xray,
              mihomoConfig: mihomo,
              singboxConfig:
                  core == VpnBackend.xray && mode == ConnectionMode.tun
                  ? SingBoxTunConfigGen.generate(
                      localSocksPort: settings.localPort,
                      socksUsername: 'local-test-user',
                      socksPassword: 'local-test-password',
                      serverIpToExclude: 'node.example.com',
                      settings: settings,
                      windows: false,
                      macos: true,
                    )
                  : null,
            );
            final payload = MacOSSessionConfig.build(
              request: request,
              sessionId: name,
              apiPort: 23000,
              apiSecret: 'test-secret-12345678',
              context: mode == ConnectionMode.tun ? context : null,
            );
            expect(payload['lan'], request.lan!.toMap());
            expect(request.xrayConfig, xray);
            expect(request.mihomoConfig, mihomo);
            final configs = payload['configurations'] as Map;
            final export = Platform.environment['KEQDIS_MACOS_FIXTURE_DIR'];
            if (export != null) {
              await Directory(export).create(recursive: true);
              await File(
                '$export/$name.json',
              ).writeAsString(jsonEncode(payload));
            }
            final config = jsonDecode(configs.values.single as String) as Map;
            if (core == VpnBackend.mihomo) {
              expect(config['allow-lan'], false);
              expect(config['bind-address'], '127.0.0.1');
              final listeners = (config['listeners'] as List).cast<Map>();
              expect(
                listeners.map((v) => v['listen']),
                everyElement('0.0.0.0'),
              );
              expect(listeners.map((v) => v['port']), ['11080', '18080']);
              expect(
                listeners.every(
                  (v) => (v['users'] as List).length == (authenticated ? 1 : 0),
                ),
                isTrue,
              );
              final rules = (config['sub-rules'] as Map)['keq-lan'] as List;
              expect(rules.last, 'MATCH,REJECT');
              expect(rules.length, 6);
            } else {
              final root = mode == ConnectionMode.tun
                  ? ((config['outbounds'] as List).cast<Map>().singleWhere(
                          (v) => v['type'] == 'xray',
                        )['xray']
                        as Map)
                  : config;
              final inbounds = (root['inbounds'] as List)
                  .cast<Map>()
                  .where((v) => ['socks-lan', 'http-lan'].contains(v['tag']))
                  .toList();
              expect(inbounds.length, 2);
              expect(inbounds.map((v) => v['listen']), everyElement('0.0.0.0'));
              expect(
                inbounds.map(
                  (v) => v[mode == ConnectionMode.tun ? 'port' : 'listen_port'],
                ),
                [11080, 18080],
              );
              final allRules =
                  (root[mode == ConnectionMode.tun ? 'routing' : 'route']
                          as Map)['rules']
                      as List;
              final rules = mode == ConnectionMode.tun
                  ? allRules
                        .cast<Map>()
                        .where(
                          (rule) => (rule['inboundTag'] as List? ?? [])
                              .contains('socks-lan'),
                        )
                        .toList()
                  : allRules;
              expect(
                (rules[0] as Map).values.any(
                  (v) => v is List && v.contains('192.168.0.0/16'),
                ),
                true,
              );
              expect(
                (rules[1] as Map)[mode == ConnectionMode.tun
                    ? 'outboundTag'
                    : 'outbound'],
                'block',
              );
            }
          },
        );
      }
    }
  }

  test('LAN request opt-in is absent for old callers', () {
    const request = TunnelSessionRequest(
      mode: ConnectionMode.proxy,
      xrayConfig: '{}',
    );
    expect(request.lan, isNull);
  });
  test('LAN authentication retains legacy all-or-nothing semantics', () {
    expect(
      const LanProxySettings(
        socksPort: 1080,
        httpPort: 8080,
        username: ' user ',
        password: '',
      ).toMap()['username'],
      '',
    );
    expect(
      const LanProxySettings(
        socksPort: 1080,
        httpPort: 8080,
        username: ' user ',
        password: 'pass',
      ).toMap()['username'],
      'user',
    );
  });
  test('LAN rejects ambiguous HTTP and oversized SOCKS credentials', () {
    for (final user in ['a:b', 'a\nb', 'a\u007fb', 'a' * 256]) {
      expect(
        () => LanProxySettings(
          socksPort: 1080,
          httpPort: 8080,
          username: user,
          password: 'pass',
        ).toMap(),
        throwsFormatException,
      );
    }
    expect(
      () => LanProxySettings(
        socksPort: 1080,
        httpPort: 8080,
        username: 'user',
        password: '中' * 86,
      ).toMap(),
      throwsFormatException,
    );
  });
  test('LAN ports cannot collide with local ports or the protected API', () {
    for (final ports in [
      (2080, 8080),
      (1080, 23000),
      (1080, 1080),
      (80, 8080),
      (1080, 65536),
    ]) {
      expect(
        () => MacOSSessionConfig.build(
          request: TunnelSessionRequest(
            mode: ConnectionMode.proxy,
            xrayConfig: '{}',
            lan: LanProxySettings(socksPort: ports.$1, httpPort: ports.$2),
          ),
          sessionId: 'lan-invalid',
          apiPort: 23000,
          apiSecret: 'test-secret-12345678',
        ),
        throwsFormatException,
      );
    }
  });
}
