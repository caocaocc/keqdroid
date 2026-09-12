import 'dart:convert';
import 'dart:io';

import '../utils/keqrnel_config.dart';
import 'connection_mode.dart';
import 'macos_core_paths.dart';
import 'macos_network_context.dart';
import 'tunnel_session_request.dart';
import 'vpn_backend.dart';

/// Конфиги передаются helper как данные. Пути, argv и environment выбирает
/// только установленный сервис; исходная подписка при адаптации не меняется.
class MacOSSessionConfig {
  MacOSSessionConfig._();

  static Map<String, dynamic> build({
    required TunnelSessionRequest request,
    required String sessionId,
    required int apiPort,
    required String apiSecret,
    MacOSNetworkContext? context,
  }) {
    final tun = request.mode == ConnectionMode.tun;
    if (tun && context == null) {
      throw const FormatException(
        'TUN requires a physical network DNS context.',
      );
    }
    if (tun && context!.hasIpv6 && request.blockIpv6Leak) {
      if (request.vpnBackend == VpnBackend.mihomo) {
        throw const FormatException(
          'Mihomo on macOS cannot guarantee IPv6 leak protection. Select the keqrnel core before connecting.',
        );
      }
      final config = _object(request.singboxConfig, 'TUN');
      final inbounds = (config['inbounds'] as List? ?? const [])
          .whereType<Map>();
      final capturesIpv6 = inbounds.any(
        (inbound) =>
            inbound['type'] == 'tun' &&
            (inbound['address'] as List? ?? const []).contains(
              'fdfe:dcba:9876::1/126',
            ),
      );
      final rules = (config['route'] as Map?)?['rules'] as List? ?? const [];
      final blocksIpv6 = rules.whereType<Map>().any(
        (rule) =>
            rule['outbound'] == 'block' &&
            (rule['ip_cidr'] as List? ?? const []).contains('::/0'),
      );
      if (!capturesIpv6 || !blocksIpv6) {
        throw const FormatException(
          'The physical network has IPv6 but its protection could not be prepared. Reconnect after verifying IPv6 settings; the tunnel was not started.',
        );
      }
    }
    final ports = [
      request.socksPort,
      request.httpPort,
      apiPort,
      if (request.lan case final lan?) ...[lan.socksPort, lan.httpPort],
    ];
    for (final port in ports) {
      if (port < 1024 || port > 65535) {
        throw const FormatException(
          'Local core ports must be between 1024 and 65535.',
        );
      }
    }
    if (ports.toSet().length != ports.length) {
      throw const FormatException('Local core ports must be distinct.');
    }
    if (!RegExp(r'^[A-Za-z0-9-]{1,128}$').hasMatch(sessionId) ||
        apiSecret.length < 16 ||
        apiSecret.length > 256) {
      throw const FormatException(
        'A session identifier and API secret are required.',
      );
    }
    final configs = <String, String>{};
    String? dnsAddress;
    switch (request.vpnBackend) {
      case VpnBackend.mihomo:
        final config = _object(request.mihomoConfig, 'Mihomo');
        _validateMihomoResources(config);
        if (tun &&
            config['proxy-providers'] is Map &&
            (config['proxy-providers'] as Map).isNotEmpty) {
          throw const FormatException(
            'unsafeConfiguration: macOS TUN cannot load remote proxy providers after privileged configuration validation. Import the provider as inline proxies before connecting.',
          );
        }
        config['external-controller'] = '127.0.0.1:$apiPort';
        config['secret'] = apiSecret;
        for (final key in [
          'external-controller-unix',
          'external-controller-pipe',
          'external-ui',
          'external-ui-url',
          'external-ui-name',
        ]) {
          config.remove(key);
        }
        if (tun) {
          final inbound = Map<String, dynamic>.from(
            config['tun'] as Map? ?? const {},
          );
          inbound.remove('device');
          inbound.remove('strict-route');
          inbound.remove('file-descriptor');
          inbound['enable'] = true;
          inbound['auto-route'] = true;
          inbound['auto-detect-interface'] = true;
          inbound['dns-hijack'] = ['any:53'];
          config['tun'] = inbound;
          final dns = Map<String, dynamic>.from(
            config['dns'] as Map? ?? const {},
          );
          dns['enable'] = true;
          dns.remove('listen');
          dnsAddress = mihomoDnsAddress(dns);
          if (context!.dnsServers.contains(dnsAddress)) {
            throw const FormatException(
              'The tunnel DNS address overlaps the physical DNS.',
            );
          }
          config['dns'] = dns;
          config['interface-name'] = context.interfaceName;
          config['rules'] = [
            for (final path in MacOSCorePaths.bypassExecutablePaths)
              'PROCESS-PATH,$path,DIRECT',
            ...config['rules'] as List? ?? const [],
          ];
        } else {
          config.remove('tun');
        }
        configs['mihomo'] = jsonEncode(config);
      case VpnBackend.xray:
        final config = _object(
          tun
              ? KeqrnelConfig.fromChain(
                  singboxConfig: _required(request.singboxConfig, 'TUN'),
                  xrayConfig: request.xrayConfig,
                  windows: false,
                  clashApiPort: apiPort,
                )
              : KeqrnelConfig.proxyWithStats(
                  xrayConfig: request.xrayConfig,
                  socksPort: request.socksPort,
                  httpPort: request.httpPort,
                  clashPort: apiPort,
                  findProcess: request.debugMode,
                ),
          'keqrnel',
        );
        _configureKeqrnel(
          config,
          apiPort,
          apiSecret,
          context: tun ? context : null,
        );
        configs['keqrnel'] = jsonEncode(config);
        if (tun) dnsAddress = '172.19.0.2';
    }
    return {
      'protocolVersion': 1,
      'sessionId': sessionId,
      'connectionMode': request.mode.storageValue,
      'core': switch (request.vpnBackend) {
        VpnBackend.xray => 'keqrnel',
        VpnBackend.mihomo => 'mihomo',
      },
      'configurations': configs,
      'socksPort': request.socksPort,
      'httpPort': request.httpPort,
      'apiPort': apiPort,
      'apiSecret': apiSecret,
      if (request.lan case final lan?) 'lan': lan.toMap(),
      'systemProxy':
          request.mode == ConnectionMode.proxy && request.systemProxy,
      'blockIpv6Leak': request.blockIpv6Leak,
      if (tun) 'contextId': context!.contextId,
      'dnsAddress': ?dnsAddress,
    };
  }

  static Map<String, dynamic> _object(String? raw, String label) =>
      Map<String, dynamic>.from(jsonDecode(_required(raw, label)) as Map);

  static String _required(String? value, String label) {
    if (value == null || value.trim().isEmpty) {
      throw FormatException('$label configuration is required.');
    }
    return value;
  }

  static void _configureKeqrnel(
    Map<String, dynamic> config,
    int apiPort,
    String apiSecret, {
    MacOSNetworkContext? context,
  }) {
    final experimental = Map<String, dynamic>.from(
      config['experimental'] as Map? ?? const {},
    );
    experimental['clash_api'] = {
      'external_controller': '127.0.0.1:$apiPort',
      'secret': apiSecret,
    };
    config['experimental'] = experimental;
    if (context == null) return;
    var foundTun = false;
    for (final inbound
        in (config['inbounds'] as List? ?? const []).whereType<Map>()) {
      if (inbound['type'] != 'tun') continue;
      foundTun = true;
      inbound.remove('interface_name');
      inbound.remove('strict_route');
      inbound.remove('auto_redirect');
      inbound['auto_route'] = true;
    }
    if (!foundTun) {
      throw const FormatException('The session has no TUN inbound.');
    }
    final route = Map<String, dynamic>.from(
      config['route'] as Map? ?? const {},
    );
    route.remove('auto_detect_interface');
    route['default_interface'] = context.interfaceName;
    route['rules'] = [
      {
        'process_path': MacOSCorePaths.bypassExecutablePaths,
        'outbound': 'direct',
      },
      ...route['rules'] as List? ?? const [],
    ];
    config['route'] = route;
  }

  static String mihomoDnsAddress(Map<String, dynamic> dns) {
    final range = dns['fake-ip-range']?.toString() ?? '198.18.0.1/16';
    final parts = range.split('/');
    final ip = InternetAddress.tryParse(parts.first);
    final prefix = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        prefix == null ||
        prefix < 1 ||
        prefix > 30 ||
        ip.isLoopback ||
        ip.isMulticast) {
      throw const FormatException(
        'Mihomo TUN needs a usable IPv4 fake-ip-range.',
      );
    }
    final bytes = ip.rawAddress.toList();
    final privateRange =
        bytes[0] == 10 && prefix >= 8 ||
        bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 && prefix >= 12 ||
        bytes[0] == 192 && bytes[1] == 168 && prefix >= 16 ||
        bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19) && prefix >= 15;
    if (!privateRange) {
      throw const FormatException(
        'Mihomo TUN DNS requires a private or benchmarking subnet.',
      );
    }
    if (bytes.last >= 254) {
      throw const FormatException(
        'Mihomo DNS address is outside its TUN subnet.',
      );
    }
    bytes[3]++;
    return bytes.join('.');
  }

  static void _validateMihomoResources(Map<String, dynamic> config) {
    bool usesAsnRule(Object? value) {
      if (value is String) return value.toUpperCase().contains('IP-ASN,');
      if (value is List) return value.any(usesAsnRule);
      if (value is Map) return value.values.any(usesAsnRule);
      return false;
    }

    if (config['geodata-mode'] == false ||
        usesAsnRule(config['rules']) ||
        usesAsnRule(config['sub-rules'])) {
      throw const FormatException(
        'unsupportedGeoData: macOS packages contain GeoIP and GeoSite DAT databases. MMDB and IP-ASN rules require a database that is not included.',
      );
    }
    config['geodata-mode'] = true;
    config['geo-auto-update'] = false;
    config.remove('geo-update-interval');
    config.remove('geox-url');
    for (final key in ['proxy-providers', 'rule-providers']) {
      final providers = config[key];
      if (providers is! Map) continue;
      for (final provider in providers.values.whereType<Map>()) {
        final path = provider['path']?.toString();
        if (path != null &&
            (path.startsWith('/') ||
                path.contains('\\') ||
                path.split('/').contains('..'))) {
          throw const FormatException(
            'macOS sessions cannot read provider files outside their session directory.',
          );
        }
        if (provider['type'] == 'file') {
          throw const FormatException(
            'A file provider must be embedded or changed to HTTP before using it on macOS.',
          );
        }
      }
    }
  }
}
