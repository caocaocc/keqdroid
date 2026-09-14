import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/xray_core_settings.dart';
import 'package:keqdroid/services/geo_asset_service.dart';
import 'package:keqdroid/utils/geo_asset_index.dart';
import 'package:keqdroid/utils/geo_dat_reader.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/routing_presets.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';

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
    expect(servers.first['address'], 'localhost');
    expect(servers.first['domains'], contains('domain:home.arpa'));
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
