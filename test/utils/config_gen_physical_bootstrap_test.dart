import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/xray_core_settings.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/proxy_chain.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

const _node =
    'vless://test-id@node.example.com:443?security=tls&sni=decoy.example.com';
const _settings = AppSettings(
  xrayCore: XrayCoreSettings(dnsUseCustom: false),
  directRules: 'corp.example',
  proxyRules: 'proxied.example',
  blockedRules: 'blocked.example',
);

Map<String, dynamic> _generate(
  String input, {
  AppSettings settings = _settings,
  bool physical = false,
}) =>
    jsonDecode(
          ConfigGeneratorV2.generateConfig(
            input,
            settings,
            physicalBootstrapDns: physical,
          ),
        )
        as Map<String, dynamic>;

List<Map<String, dynamic>> _bootstrap(
  Map<String, dynamic> config,
  List<String> domains,
) => ((config['dns'] as Map)['servers'] as List)
    .cast<Map<String, dynamic>>()
    .where(
      (server) => (server['domains'] as List?)?.any(domains.contains) ?? false,
    )
    .toList();

Map<String, dynamic> _withoutBootstrap(
  Map<String, dynamic> config,
  List<String> domains,
) {
  final copy = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
  ((copy['dns'] as Map)['servers'] as List).removeWhere(
    (server) => (server['domains'] as List?)?.any(domains.contains) ?? false,
  );
  return copy;
}

void main() {
  setUp(() => Socks5Credentials().init('test-user', 'test-password'));

  test('macOS physical bootstrap changes only the automatic node resolver', () {
    const domains = ['full:node.example.com'];
    final original = _generate(_node);
    final physical = _generate(_node, physical: true);
    final bootstrap = _bootstrap(physical, domains);
    expect(bootstrap.map((server) => server['address']), ['localhost']);
    expect(bootstrap.single['domains'], domains);
    expect(bootstrap.single['skipFallback'], isTrue);
    expect(bootstrap.single['finalQuery'], isTrue);
    expect(
      _withoutBootstrap(physical, domains),
      _withoutBootstrap(original, domains),
      reason: 'business DNS, routing, credentials and TLS must stay unchanged',
    );
    expect(
      _bootstrap(original, domains).map((server) => server['address']),
      ['https+local://1.1.1.1/dns-query', 'localhost'],
      reason: 'omitted/false policy preserves other platform and Proxy output',
    );
  });

  test('IP node keeps its configuration and never bootstraps its SNI', () {
    final ipNode = _node.replaceFirst('node.example.com', '198.51.100.10');
    expect(_generate(ipNode, physical: true), _generate(ipNode));
  });

  test('chain bootstrap includes each node domain and excludes IP and SNI', () {
    final chain = ProxyChainConfig(
      name: 'synthetic',
      hops: const [
        ProxyChainHop(config: _node),
        ProxyChainHop(
          config:
              'trojan://test-password@exit.example.com:443?sni=cover.example.com',
        ),
        ProxyChainHop(config: 'ss://YWVzLTI1Ni1nY206cGFzcw@198.51.100.11:8388'),
      ],
    ).encode();
    const domains = ['full:node.example.com', 'full:exit.example.com'];
    final physical = _generate(chain, physical: true);
    final bootstrap = _bootstrap(physical, domains);
    expect(bootstrap.map((server) => server['address']), ['localhost']);
    expect(bootstrap.single['domains'], domains);
    expect(
      _withoutBootstrap(physical, domains),
      _withoutBootstrap(_generate(chain), domains),
      reason: 'chain transport and each dialerProxy must stay unchanged',
    );
  });

  for (final servers in [
    'https+local://1.1.1.1/dns-query',
    'https://resolver.example/dns-query\ntls://resolver.example',
    '',
  ]) {
    test(
      'explicit custom DNS keeps its whole policy (${servers.isEmpty ? 'empty' : servers})',
      () {
        final settings = _settings.copyWith(
          xrayCore: XrayCoreSettings(dnsUseCustom: true, dnsServers: servers),
        );
        final chain = ProxyChainConfig(
          name: 'explicit-dns-chain',
          hops: const [
            ProxyChainHop(config: _node),
            ProxyChainHop(
              config: 'trojan://test-password@exit.example.com:443',
            ),
          ],
        ).encode();
        for (final input in [_node, chain]) {
          expect(
            _generate(input, settings: settings, physical: true),
            _generate(input, settings: settings),
          );
        }
      },
    );
  }

  for (final authorDns in [false, true]) {
    test(
      'complete author JSON retains its policy (DNS present: $authorDns)',
      () {
        final author = jsonEncode({
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'node.example.com',
                    'port': 443,
                    'users': [
                      {'id': 'test-id', 'encryption': 'none'},
                    ],
                  },
                ],
              },
            },
          ],
          if (authorDns)
            'dns': {
              'servers': [
                {
                  'address': 'https+local://1.1.1.1/dns-query',
                  'domains': ['full:node.example.com'],
                },
                'localhost',
              ],
            },
        });
        expect(_generate(author, physical: true), _generate(author));
      },
    );
  }

  test('physical bootstrap keeps DNS query and cache options', () {
    const core = XrayCoreSettings(
        dnsUseCustom: false,
        dnsServers: XrayCoreSettings.legacyDnsServers,
      dnsQueryStrategy: 'UseIP',
      dnsDisableCache: true,
    );
    final dns = core.buildDnsBlock(
      directDomains: ['domain:corp.example'],
      bootstrapDomains: ['full:node.example.com'],
      proxiedDoh: true,
      physicalBootstrapDns: true,
    );
    expect(dns['queryStrategy'], 'UseIP');
    expect(dns['disableCache'], isTrue);
    expect((dns['servers'] as List).first['address'], 'localhost');
  });
}
