import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/traffic_route.dart';
import 'package:keqdroid/models/tun_settings.dart';
import 'package:keqdroid/utils/app_routes.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';

void main() {
  const link = 'vless://test@203.0.113.8:443?security=none&type=tcp';
  const path = '/Applications/Chat.app/Contents/MacOS/Chat';
  final settings = AppSettings.fromJson({});
  const routes = [RouteAppRules(tag: 'keq-app-0', apps: [path], target: RouteTarget.block, allTraffic: true)];

  test('Mac process rules reuse Xray routing without a native TUN inbound', () {
    final config = jsonDecode(ConfigGeneratorV2.generateConfig(link, settings,
      macosTunRouting: true, appRoutes: routes)) as Map;
    final rule = (config['routing']['rules'] as List).cast<Map>()
        .singleWhere((rule) => rule['process'] != null);
    expect(rule['process'], [path]);
    expect(rule['inboundTag'], ['tun-in']);
    expect(rule['outboundTag'], 'block');
    expect((config['inbounds'] as List).cast<Map>().any((i) => i['protocol'] == 'tun'), isFalse);
    final ordinary = jsonDecode(ConfigGeneratorV2.generateConfig(link, settings, appRoutes: routes)) as Map;
    expect((ordinary['routing']['rules'] as List).cast<Map>().any((r) => r['process'] != null), isFalse);
  });

  test('delegated routing keeps DNS, loop protection and IPv6 protection', () {
    final config = jsonDecode(SingBoxTunConfigGen.generate(
      localSocksPort: 2080, socksUsername: 'test', socksPassword: 'test',
      serverIpToExclude: '203.0.113.8',
      settings: settings.copyWith(directRules: 'corp.example', blockedRules: 'ads.example',
        finalOutbound: AppSettings.finalOutboundDirect, tun: const TunSettings(blockIpv6Leak: true)),
      hostHasIpv6: true, delegateRoutingToXray: true)) as Map;
    final rules = (config['route']['rules'] as List).cast<Map>();
    expect(config['route']['final'], 'proxy');
    expect(rules.any((r) => r['port'] == 53 && r['action'] == 'hijack-dns'), isTrue);
    expect(rules.any((r) => (r['ip_cidr'] as List?)?.contains('203.0.113.8/32') == true), isTrue);
    expect(rules.any((r) => (r['ip_cidr'] as List?)?.contains('::/0') == true && r['action'] == 'reject'), isTrue);
    expect(rules.any((r) => (r['domain_suffix'] as List?)?.contains('corp.example') == true), isFalse);
    expect(rules.any((r) => (r['domain_suffix'] as List?)?.contains('ads.example') == true), isFalse);
  });
}
