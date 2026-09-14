import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/xray_core_settings.dart';
import 'package:keqdroid/services/geo_asset_service.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/geo_asset_index.dart';
import 'package:keqdroid/utils/geo_dat_reader.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/routing_presets.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

const _cn = [
  GeoDomain(type: GeoDomainType.domain, value: 'example.cn'),
  GeoDomain(type: GeoDomainType.full, value: 'www.china.example'),
  GeoDomain(type: GeoDomainType.regex, value: r'^cn[0-9]+\.example$'),
  GeoDomain(type: GeoDomainType.plain, value: 'cn.keyword'),
];

Map<String, dynamic> _tun(AppSettings settings, {List<GeoDomain> cn = _cn}) =>
    jsonDecode(
          SingBoxTunConfigGen.generate(
            localSocksPort: 10808,
            socksUsername: 'test',
            socksPassword: 'test',
            serverIpToExclude: '192.0.2.1',
            settings: settings,
            chinaDnsDomains: cn,
            windows: false,
            macos: false,
          ),
        )
        as Map<String, dynamic>;

void main() {
  test('fresh/reset defaults are Chinese, old JSON keeps legacy values', () {
    const fresh = AppSettings();
    expect(fresh.directRules, 'geosite:cn, geoip:cn');
    expect(fresh.finalOutbound, AppSettings.finalOutboundProxy);
    expect(fresh.xrayCore.dnsUseCustom, isTrue);
    expect(fresh.xrayCore.dnsSplitDirectDomains, isTrue);
    expect(fresh.xrayCore.dnsServers, XrayCoreSettings.defaultDnsServers);
    expect(RoutingPresets.all.singleWhere((p) => p.id == 'china').values, [
      'geosite:cn',
      'geoip:cn',
    ]);

    for (final json in <Map<String, dynamic>>[
      {},
      {'xrayCore': <String, dynamic>{}},
    ]) {
      final old = AppSettings.fromJson(json);
      expect(old.directRules, 'ru, yandex.ru, vk.com');
      expect(old.xrayCore.dnsUseCustom, isFalse);
      expect(old.xrayCore.dnsServers, XrayCoreSettings.legacyDnsServers);
    }
    final explicit = AppSettings.fromJson({
      'directRules': 'domain:corp.example',
      'finalOutbound': AppSettings.finalOutboundDirect,
      'xrayCore': {
        'dnsUseCustom': true,
        'dnsServers': '192.0.2.53',
        'dnsSplitDirectDomains': false,
      },
    });
    expect(explicit.directRules, 'domain:corp.example');
    expect(explicit.xrayCore.dnsServers, '192.0.2.53');
    expect(explicit.xrayCore.dnsSplitDirectDomains, isFalse);
    expect(AppSettings.fromJson(fresh.toJson()).toJson(), fresh.toJson());
  });

  test('Xray splits CN and bootstrap without direct foreign DoH fallback', () {
    final dns = const XrayCoreSettings().buildDnsBlock(
      directDomains: ['geosite:cn'],
      bootstrapDomains: ['full:node.example'],
    );
    final servers = (dns['servers'] as List).cast<Map<String, dynamic>>();
    final bootstrap = servers
        .where(
          (s) => (s['domains'] as List?)?.contains('full:node.example') == true,
        )
        .toList();
    expect(bootstrap.map((s) => s['address']), [
      'tcp+local://223.5.5.5:53',
      'localhost',
    ]);
    expect(
      servers.singleWhere(
        (s) => (s['domains'] as List?)?.contains('geosite:cn') == true,
      )['address'],
      'tcp+local://223.5.5.5:53',
    );
    expect(servers.last['address'], 'https://1.1.1.1/dns-query');
    final local = servers.singleWhere(
      (server) =>
          (server['domains'] as List?)?.contains('domain:home.arpa') == true,
    );
    expect(local['address'], 'localhost');
    expect(local['finalQuery'], isTrue);
  });

  test('TUN uses typed CN only in DNS, with local names before CN', () {
    final config = _tun(const AppSettings());
    final dns = config['dns'] as Map;
    final servers = (dns['servers'] as List).cast<Map>();
    final direct = servers.singleWhere((s) => s['tag'] == 'direct-dns');
    final proxy = servers.singleWhere((s) => s['tag'] == 'proxy-dns');
    expect(direct['type'], 'tcp');
    expect(direct['server'], '223.5.5.5');
    expect(direct.containsKey('detour'), isFalse);
    expect(proxy['type'], 'https');
    expect(proxy['server'], '1.1.1.1');
    expect(proxy['detour'], 'proxy');
    final rules = (dns['rules'] as List).cast<Map>();
    expect(rules.first['server'], 'local-dns');
    expect(rules.last['server'], 'direct-dns');
    expect(rules.last['domain'], ['www.china.example']);
    expect(rules.last['domain_suffix'], ['example.cn']);
    expect(rules.last['domain_regex'], [
      r'^cn[0-9]+\.example$',
      r'cn\.keyword',
    ]);
    final legacyDns = _tun(
      const AppSettings(xrayCore: XrayCoreSettings(dnsUseCustom: false)),
    );
    expect(config['route'], legacyDns['route']);
    expect(
      SingBoxTunConfigGen.ignoredCustomDnsServers(const AppSettings()),
      isEmpty,
    );
    expect(() => _tun(const AppSettings(), cn: []), throwsFormatException);
  });

  test(
    'single DNS and disabled splitting retain the first-server behavior',
    () {
      for (final core in [
        const XrayCoreSettings(dnsServers: 'tcp+local://223.5.5.5:53'),
        const XrayCoreSettings(dnsSplitDirectDomains: false),
      ]) {
        final dns = _tun(AppSettings(xrayCore: core), cn: [])['dns'] as Map;
        final servers = (dns['servers'] as List).cast<Map>();
        expect(servers.any((s) => s['tag'] == 'direct-dns'), isFalse);
        expect(
          servers.singleWhere((s) => s['tag'] == 'proxy-dns')['server'],
          '223.5.5.5',
        );
      }
    },
  );

  test(
    'mihomo keeps CN and node DNS direct, with native policy and local DNS',
    () {
      final dns = MihomoConfigGen.buildDns(const AppSettings());
      expect(dns['nameserver'], ['https://1.1.1.1/dns-query']);
      expect(dns['default-nameserver'], ['tcp://223.5.5.5:53#DIRECT']);
      expect(dns['proxy-server-nameserver'], ['tcp://223.5.5.5:53#DIRECT']);
      expect(dns['respect-rules'], isTrue);
      final policy = dns['nameserver-policy'] as Map;
      expect(policy['geosite:cn'], ['tcp://223.5.5.5:53#DIRECT']);
      expect(policy['+.local'], ['system']);
      expect(policy['+.home.arpa'], ['system']);
      expect(policy['*'], ['system']);
      final named = MihomoConfigGen.buildDns(
        const AppSettings(
          xrayCore: XrayCoreSettings(
            dnsServers:
                'https+local://dns.example/dns-query\nhttps://1.1.1.1/dns-query',
          ),
        ),
      );
      expect(named['default-nameserver'], ['system']);
    },
  );

  test('explicit DNS policy precedes CN and reserved local defaults', () {
    const core = XrayCoreSettings(
      dnsPolicy:
          'www.china.example 192.0.2.54\n*.example.cn https://192.0.2.55/dns-query\nhome.local 192.0.2.56',
    );
    const settings = AppSettings(
      xrayCore: core,
      directRules: 'geosite:cn, domain:example.cn, geoip:cn',
    );
    final xray = core.buildDnsBlock(directDomains: ['geosite:cn']);
    final xrayServers = (xray['servers'] as List).cast<Map>();
    final policyIndexes = [
      for (final address in [
        '192.0.2.54',
        'https://192.0.2.55/dns-query',
        '192.0.2.56',
      ])
        xrayServers.indexWhere((server) => server['address'] == address),
    ];
    final localIndex = xrayServers.indexWhere(
      (server) => server['address'] == 'localhost',
    );
    final chinaIndex = xrayServers.indexWhere(
      (server) => server['address'] == 'tcp+local://223.5.5.5:53',
    );
    for (final index in policyIndexes) {
      expect(index, isNonNegative);
      expect(index, lessThan(localIndex));
      expect(index, lessThan(chinaIndex));
      expect(xrayServers[index]['skipFallback'], isTrue);
    }
    final mihomo = MihomoConfigGen.buildDns(settings);
    final policy = mihomo['nameserver-policy'] as Map;
    // The core matches policy groups in insertion order, including geosite.
    expect(policy.keys.take(3), [
      'www.china.example',
      '+.example.cn',
      'home.local',
    ]);
    expect(policy['+.example.cn'], ['https://192.0.2.55/dns-query']);
    expect(policy['geosite:cn'], ['tcp://223.5.5.5:53#DIRECT']);
    final tun = _tun(settings)['dns'] as Map;
    final rules = (tun['rules'] as List).cast<Map>();
    expect(rules.take(3).map((rule) => rule['server']), [
      'keq-policy-0',
      'keq-policy-1',
      'keq-policy-2',
    ]);
    expect(rules[1]['domain_suffix'], ['.example.cn']);
    expect(rules[3]['server'], 'local-dns');
    expect(rules.last['server'], 'direct-dns');
  });

  test(
    'explicit DNS and hosts survive backups without changing old defaults',
    () {
      const settings = AppSettings(
        xrayCore: XrayCoreSettings(
          dnsHosts: 'www.china.example 192.0.2.42',
          dnsPolicy: '*.example.cn https://192.0.2.55/dns-query',
          concurrentDial: true,
        ),
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.xrayCore, settings.xrayCore);
      expect(restored.directRules, settings.directRules);
      final legacy = AppSettings.fromJson({});
      expect(legacy.xrayCore.dnsHosts, isEmpty);
      expect(legacy.xrayCore.dnsPolicy, isEmpty);
      expect(legacy.xrayCore.concurrentDial, isFalse);
      final dns = _tun(settings)['dns'] as Map;
      final rules = (dns['rules'] as List).cast<Map>();
      expect(rules.first['server'], SingBoxTunConfigGen.hostsServerTag);
      expect(rules.first['domain'], ['www.china.example']);
      expect(rules[1]['server'], 'keq-policy-0');
      final hosts = (dns['servers'] as List).cast<Map>().singleWhere(
        (server) => server['type'] == 'hosts',
      );
      expect(hosts['predefined'], {
        'www.china.example': ['192.0.2.42'],
      });
    },
  );

  test('author DNS and hosts retain precedence over generated defaults', () {
    Socks5Credentials().init('test-user', 'test-password');
    const settings = AppSettings(
      xrayCore: XrayCoreSettings(
        dnsHosts: 'www.example.cn 192.0.2.42',
        dnsPolicy: '*.example.cn https://192.0.2.55/dns-query',
        concurrentDial: true,
      ),
    );
    final authorXrayDns = {
      'hosts': {'www.example.cn': '192.0.2.43'},
      'servers': ['192.0.2.57'],
    };
    final xray =
        jsonDecode(
              ConfigGeneratorV2.generateConfig(
                jsonEncode({
                  'dns': authorXrayDns,
                  'outbounds': [
                    {
                      'protocol': 'socks',
                      'tag': 'proxy',
                      'settings': {
                        'servers': [
                          {'address': '192.0.2.1', 'port': 1080},
                        ],
                      },
                    },
                  ],
                }),
                settings,
              ),
            )
            as Map;
    final xrayDns = xray['dns'] as Map;
    expect(xrayDns['hosts'], authorXrayDns['hosts']);
    // Upstream appends its general fallback, but the author's resolver stays
    // first and the app's domain policies must not displace it.
    expect((xrayDns['servers'] as List).first, '192.0.2.57');
    expect(
      (xrayDns['servers'] as List).skip(1),
      everyElement(
        isA<Map>().having((server) => server['domains'], 'domains', isNull),
      ),
    );
    final authorMihomoDns = {
      'enable': true,
      'nameserver': ['192.0.2.57'],
      'nameserver-policy': {
        '+.example.cn': ['192.0.2.58'],
      },
    };
    final mihomo = MihomoConfigGen.build(
      jsonEncode({
        'dns': authorMihomoDns,
        'hosts': {'www.example.cn': '192.0.2.43'},
        'proxies': [
          {
            'name': 'proxy',
            'type': 'socks5',
            'server': '192.0.2.1',
            'port': 1080,
          },
        ],
        'rules': ['MATCH,proxy'],
      }),
      settings,
      socksPort: 2080,
    );
    expect(mihomo['dns'], authorMihomoDns);
    expect(mihomo['hosts'], {'www.example.cn': '192.0.2.43'});
  });

  test('required CN data fails before sanitizing for every core and mode', () {
    const complete = GeoAssetIndex(geoipCodes: {'cn'}, geositeCodes: {'cn'});
    for (final core in [AppSettings.vpnCoreAuto, AppSettings.vpnCoreMihomo]) {
      for (final mode in ['proxy', 'tun']) {
        final settings = AppSettings(vpnCore: core, connectionMode: mode);
        expect(
          () => GeoAssetService.requireChinaRules(settings, complete),
          returnsNormally,
        );
        for (final missing in [
          GeoAssetIndex.empty,
          const GeoAssetIndex(geoipCodes: {'ru'}, geositeCodes: {'cn'}),
          const GeoAssetIndex(geoipCodes: {'cn'}, geositeCodes: {'ru'}),
        ]) {
          expect(
            () => GeoAssetService.requireChinaRules(settings, missing),
            throwsFormatException,
          );
        }
      }
    }
    expect(
      () => GeoAssetService.requireChinaRules(
        AppSettings.fromJson({}),
        GeoAssetIndex.empty,
      ),
      returnsNormally,
    );
  });

  test(
    'bundled desktop geosite and Android lite geoip both contain CN',
    () async {
      final cn = await GeoDatReader.domains(
        File('assets/bin/windows/geosite.dat'),
        'cn',
      );
      expect(cn, isNotEmpty);
      expect(cn.any((d) => d.type == GeoDomainType.domain), isTrue);
      expect(
        await GeoDatReader.codes(File('assets/geo/geoip-lite.dat')),
        contains('cn'),
      );
    },
  );
}
