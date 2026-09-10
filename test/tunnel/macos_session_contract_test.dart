import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/macos_core_paths.dart';
import 'package:keqdroid/tunnel/macos_network_context.dart';
import 'package:keqdroid/tunnel/macos_session_config.dart';
import 'package:keqdroid/tunnel/tunnel_session_request.dart';
import 'package:keqdroid/tunnel/vpn_backend.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

void main() {
  const link =
      'trojan://test-password@node.example.com:443?sni=node.example.com';
  const awg =
      '[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nAllowedIPs = 0.0.0.0/0\nEndpoint = node.example.com:51820';
  const settings = AppSettings();
  const context = MacOSNetworkContext(
    contextId: 'test-network',
    interfaceName: 'en0',
    dnsServers: ['192.168.1.1'],
  );
  for (final core in VpnBackend.values) {
    for (final mode in ConnectionMode.values) {
      test(
        '${core.name} ${mode.name} uses the real generator contract',
        () async {
          Socks5Credentials().init('test-user', 'test-password');
          final request = TunnelSessionRequest(
            mode: mode,
            vpnBackend: core,
            socksPort: settings.localPort,
            httpPort: settings.httpPort,
            xrayConfig: core == VpnBackend.xray
                ? ConfigGeneratorV2.generateConfig(
                    link,
                    settings,
                    localInboundsNoAuth: mode == ConnectionMode.proxy,
                  )
                : '',
            awgConfig: core == VpnBackend.awg ? awg : null,
            mihomoConfig: core == VpnBackend.mihomo
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
                : null,
            singboxConfig: mode == ConnectionMode.tun
                ? SingBoxTunConfigGen.generate(
                    localSocksPort: settings.localPort,
                    socksUsername: 'test-user',
                    socksPassword: 'test-password',
                    serverIpToExclude: 'node.example.com',
                    settings: settings,
                    windows: false,
                    macos: true,
                    localSocksNoAuth: core == VpnBackend.awg,
                  )
                : null,
          );
          final payload = MacOSSessionConfig.build(
            request: request,
            sessionId: '${core.name}-${mode.name}',
            apiPort: 23000,
            apiSecret: 'test-secret-12345678',
            wireproxyInfoPort: 23001,
            context: mode == ConnectionMode.tun ? context : null,
          );
          final configs = payload['configurations'] as Map;
          final normalized = _normalizedPayload(payload);
          final golden = File(
            'test/fixtures/macos/${core.name}-${mode.name}.json',
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
            reason: 'macOS ${core.name}/${mode.name} configuration changed',
          );
          expect(
            configs.length,
            core == VpnBackend.awg && mode == ConnectionMode.tun ? 2 : 1,
          );
          expect(configs.values.join(), contains('node.example.com'));
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
              '$export/${core.name}-${mode.name}.json',
            ).writeAsString(jsonEncode(payload));
          }
        },
      );
    }
  }
}

Object? _normalizedPayload(Map<String, dynamic> payload) {
  // Only the app/test-runtime location is machine dependent. Credentials,
  // ports, interfaces and endpoints above are fixed synthetic fixtures.
  const fixtureApp = '/Applications/KEQDIS.app/Contents';
  final canonicalPaths = [
    '$fixtureApp/MacOS/KEQDIS',
    for (final name in ['keqrnel', 'mihomo', 'wireproxy']) ...[
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
        entry.key: entry.key == 'wireproxy'
            ? entry.value
            : jsonDecode(entry.value as String),
    },
  });
}
