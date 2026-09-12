import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/xray_core_settings.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';

const _link =
    'vless://00000000-0000-4000-8000-000000000001@node.example:443?type=tcp&security=none';

void main() {
  Map<String, dynamic> xray(
    AppSettings settings, {
    bool desktop = true,
    bool physical = false,
  }) =>
      jsonDecode(
            ConfigGeneratorV2.generatePingConfig(
              _link,
              settings,
              socksPort: 28150,
              desktopDns: desktop,
              physicalBootstrapDns: physical,
            ),
          )
          as Map<String, dynamic>;
  Map<String, dynamic> mihomo(
    AppSettings settings, {
    bool desktop = true,
    bool physical = false,
  }) =>
      jsonDecode(
            MihomoConfigGen.generatePingConfig(
              _link,
              settings,
              socksPort: 28150,
              desktopDns: desktop,
              physicalBootstrapDns: physical,
            ),
          )
          as Map<String, dynamic>;

  test(
    'desktop China bootstrap uses the first direct resolver, no Geo rules',
    () {
      const settings = AppSettings();
      final a = xray(settings);
      final aDns = a['dns'] as Map;
      final addresses = [
        for (final server in aDns['servers'] as List)
          (server as Map)['address'],
      ];
      expect(addresses, ['tcp+local://223.5.5.5:53', 'localhost']);
      for (final server in aDns['servers'] as List) {
        expect((server as Map).containsKey('domains'), isFalse);
        expect(server['timeoutMs'], 2500);
      }
      final b = mihomo(settings);
      expect((b['dns'] as Map)['proxy-server-nameserver'], [
        'tcp://223.5.5.5:53#DIRECT',
        'system',
      ]);
      expect((b['dns'] as Map)['default-nameserver'], ['tcp://223.5.5.5:53']);
      expect(jsonEncode(a), isNot(contains('geosite:')));
      expect(jsonEncode(b), isNot(contains('GEOSITE')));
      expect(b['rules'], ['MATCH,${MihomoConfigGen.proxyName}']);
    },
  );

  test(
    'Android/default parameter preserves legacy fixed DNS and silent logs',
    () {
      final a = xray(const AppSettings(), desktop: false);
      expect(a['dns'], {
        'servers': [
          'https+local://1.1.1.1/dns-query',
          'https+local://8.8.8.8/dns-query',
          'localhost',
        ],
        'queryStrategy': 'UseIPv4',
      });
      final b = mihomo(const AppSettings(), desktop: false);
      expect((b['dns'] as Map)['nameserver'], [
        'https://1.1.1.1/dns-query#DIRECT',
        'https://8.8.8.8/dns-query#DIRECT',
        'system',
      ]);
      expect(b['log-level'], 'silent');
    },
  );

  test(
    'physical snapshot replaces automatic bootstrap only, never custom DNS',
    () {
      final saved = AppSettings.fromJson({});
      expect((xray(saved, physical: true)['dns'] as Map)['servers'], [
        {'address': 'localhost', 'timeoutMs': 2500, 'serveStale': true},
      ]);
      expect((mihomo(saved, physical: true)['dns'] as Map)['nameserver'], [
        'system',
      ]);
      expect(
        (mihomo(const AppSettings(), physical: true)['dns']
            as Map)['nameserver'],
        ['tcp://223.5.5.5:53#DIRECT', 'system'],
      );
    },
  );

  test(
    'custom resolver ports and direct transport survive desktop conversion',
    () {
      const settings = AppSettings(
        directRules: '',
        xrayCore: XrayCoreSettings(
          dnsUseCustom: true,
          dnsServers: '[2001:db8::53]:1053\ntcp://192.0.2.53:1054',
        ),
      );
      final a =
          ((xray(settings)['dns'] as Map)['servers'] as List).first as Map;
      expect(a['address'], '2001:db8::53');
      expect(a['port'], 1053);
      final b = (mihomo(settings)['dns'] as Map)['nameserver'];
      expect(b, [
        '[2001:db8::53]:1053#DIRECT',
        'tcp://192.0.2.53:1054#DIRECT',
        'system',
      ]);
    },
  );

  test('Mihomo keeps a supported DoT resolver that Xray cannot execute', () {
    const settings = AppSettings(
      directRules: '',
      xrayCore: XrayCoreSettings(
        dnsUseCustom: true,
        dnsServers: 'tls://9.9.9.9:853',
      ),
    );
    expect((mihomo(settings)['dns'] as Map)['nameserver'], [
      'tls://9.9.9.9:853#DIRECT',
      'system',
    ]);
  });

  test('complete authored Xray config retains its original DNS', () {
    final input = jsonEncode({
      'dns': {
        'servers': ['tcp+local://192.0.2.53:1053'],
      },
      'outbounds': [
        {'tag': 'proxy', 'protocol': 'freedom', 'settings': {}},
      ],
    });
    final config =
        jsonDecode(
              ConfigGeneratorV2.generatePingConfig(
                input,
                const AppSettings(),
                socksPort: 28150,
                desktopDns: true,
              ),
            )
            as Map;
    expect(config['dns'], {
      'servers': ['tcp+local://192.0.2.53:1053'],
    });
  });
}
