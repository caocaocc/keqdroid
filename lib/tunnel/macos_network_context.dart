import 'dart:convert';
import 'dart:io';

/// DNS физической сети сохраняется до включения виртуального resolver.
/// contextId относится к снимку в helper: Dart не может подменить откат.
class MacOSNetworkContext {
  /// Temporary measurement cores must use the same physical resolver while
  /// system DNS points at the active tunnel. Only confirmed sessions set this.
  static MacOSNetworkContext? active;

  Map<String, String> get bootstrapEnvironment => {
    'KEQDIS_BOOTSTRAP_DNS': jsonEncode(dnsServers),
    'KEQDIS_BOOTSTRAP_INTERFACE': interfaceName,
  };

  final String contextId;
  final String interfaceName;
  final List<String> dnsServers;
  final List<String> serviceIds;
  final bool hasIpv6;

  const MacOSNetworkContext({
    required this.contextId,
    required this.interfaceName,
    required this.dnsServers,
    this.serviceIds = const [],
    this.hasIpv6 = false,
  });

  factory MacOSNetworkContext.fromMap(Map<Object?, Object?> map) {
    final id = map['contextId'] as String? ?? '';
    final interface = map['interfaceName'] as String? ?? '';
    final servers = (map['dnsServers'] as List? ?? const [])
        .whereType<String>()
        .toList();
    if (id.isEmpty ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(interface) ||
        interface.startsWith('utun') ||
        interface == 'lo0' ||
        servers.isEmpty) {
      throw const FormatException(
        'No usable physical network or bootstrap DNS.',
      );
    }
    for (final server in servers) {
      final ip = InternetAddress.tryParse(server);
      if (ip == null ||
          ip.isLoopback ||
          ip.isMulticast ||
          ip.address == '0.0.0.0' ||
          ip.address == '::' ||
          server == '172.19.0.2' ||
          server == '198.18.0.2') {
        throw const FormatException(
          'The physical DNS server is invalid or belongs to this tunnel.',
        );
      }
    }
    return MacOSNetworkContext(
      contextId: id,
      interfaceName: interface,
      dnsServers: List.unmodifiable(servers),
      serviceIds: List.unmodifiable(
        (map['serviceIds'] as List? ?? const []).whereType<String>(),
      ),
      hasIpv6: map['hasIpv6'] == true,
    );
  }
}
