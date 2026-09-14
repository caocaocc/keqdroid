import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/utils/fake_ip.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';

// Keep this upstream suite independent of regional installation defaults.
final _legacySettings = AppSettings.fromJson({});

/// Fake-ip в TUN на десктопе: подменный адрес отдаёт DNS sing-box, а обратно в
/// домен его превращает роутер sing-box (sing-box 1.14, route/route.go), и во
/// встроенный xray уходит уже имя.
Map<String, dynamic> _config(AppSettings settings) =>
    jsonDecode(SingBoxTunConfigGen.generate(
      localSocksPort: 10808,
      socksUsername: 'u',
      socksPassword: 'p',
      serverIpToExclude: '1.2.3.4',
      settings: settings,
    )) as Map<String, dynamic>;

List<Map<String, dynamic>> _dnsRules(Map<String, dynamic> c) =>
    (((c['dns'] as Map)['rules'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _routeRules(Map<String, dynamic> c) =>
    ((c['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

void main() {
  test('по умолчанию выключен', () {
    final c = _config(_legacySettings);
    final servers = (c['dns'] as Map)['servers'] as List;
    expect(servers.any((s) => (s as Map)['type'] == 'fakeip'), isFalse);
    expect(jsonEncode(c), isNot(contains(SingBoxTunConfigGen.fakeIpServerTag)));
  });

  test('подмена — последним правилом DNS, с TTL в секунду', () {
    final c = _config(_legacySettings.copyWith(fakeIp: true));
    final servers = ((c['dns'] as Map)['servers'] as List).cast<Map>();
    final fake = servers.firstWhere((s) => s['type'] == 'fakeip');
    expect(fake['tag'], SingBoxTunConfigGen.fakeIpServerTag);
    expect(fake['inet4_range'], kFakeIpRange);

    // TTL по умолчанию у sing-box — 600: после отключения система десять
    // минут ходила бы по подменным адресам в никуда.
    expect(_dnsRules(c).last, {
      'query_type': ['A'],
      'server': SingBoxTunConfigGen.fakeIpServerTag,
      'rewrite_ttl': 1,
    });
  });

  test('проверки связности и локальные зоны получают настоящий адрес', () {
    final rules = _dnsRules(_config(_legacySettings.copyWith(fakeIp: true)));
    final exclusions = rules[rules.length - 2];
    expect(exclusions['server'], 'proxy-dns');
    expect(exclusions['domain'], contains('connectivitycheck.gstatic.com'));
    expect(exclusions['domain_suffix'], containsAll(['msftconnecttest.com', 'lan']));
    expect(exclusions['domain_regex'], contains(r'^time\.[^.]+\.com$'));
  });

  test('свои hosts и direct-домены по-прежнему раньше подмены', () {
    final rules = _dnsRules(_config(_legacySettings.copyWith(
      fakeIp: true,
      directRules: 'corp.example',
    ).copyWith(
      xrayCore: _legacySettings.xrayCore.copyWith(
            dnsHosts: 'nas.example 10.0.0.5',
          ),
    )));
    final fakeAt = rules.indexWhere(
      (r) => r['server'] == SingBoxTunConfigGen.fakeIpServerTag,
    );
    final hostsAt = rules.indexWhere(
      (r) => r['server'] == SingBoxTunConfigGen.hostsServerTag,
    );
    final directAt = rules.indexWhere((r) => r['server'] == 'local-dns');
    expect(hostsAt, isNot(-1));
    expect(directAt, isNot(-1));
    expect(hostsAt, lessThan(fakeAt));
    expect(directAt, lessThan(fakeAt));
  });

  // Без IP-правил доразрешать нечего, и лишний DNS на каждом соединении
  // отменил бы весь выигрыш.
  test('resolve — только при правилах по IP и до первого из них', () {
    bool hasResolve(Map<String, dynamic> c) =>
        _routeRules(c).any((r) => r['action'] == 'resolve');

    expect(hasResolve(_config(_legacySettings.copyWith(fakeIp: true))), isFalse);
    expect(
      hasResolve(_config(_legacySettings.copyWith(directRules: '10.10.0.0/16'))),
      isFalse,
      reason: 'без fake-ip назначение и так адрес',
    );

    final rules = _routeRules(_config(_legacySettings.copyWith(
      fakeIp: true,
      directRules: '10.10.0.0/16',
      blockedRules: '203.0.113.0/24',
    )));
    final resolveAt = rules.indexWhere((r) => r['action'] == 'resolve');
    final firstUserIpAt = rules.indexWhere((r) {
      final cidrs = r['ip_cidr'];
      return cidrs is List &&
          (cidrs.contains('10.10.0.0/16') || cidrs.contains('203.0.113.0/24'));
    });
    expect(rules[resolveAt], {'action': 'resolve', 'server': 'proxy-dns'});
    expect(resolveAt, lessThan(firstUserIpAt));
  });
}
