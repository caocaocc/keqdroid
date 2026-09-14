import 'dart:io';

import 'package:flutter/foundation.dart';

/// Confirmed listeners only. This public runtime state never contains passwords.
final desktopLanState = ValueNotifier<DesktopLanState?>(null);

class DesktopLanState {
  final int socksPort;
  final int httpPort;
  final List<String> addresses;

  const DesktopLanState({
    required this.socksPort,
    required this.httpPort,
    required this.addresses,
  });

  static DesktopLanState? fromSnapshot(Object? value) {
    if (value is! Map) return null;
    final socks = value['socksPort'];
    final http = value['httpPort'];
    if (socks is! int ||
        http is! int ||
        socks < 1024 ||
        http < 1024 ||
        socks > 65535 ||
        http > 65535 ||
        socks == http) {
      return null;
    }
    return DesktopLanState(
      socksPort: socks,
      httpPort: http,
      addresses: List.unmodifiable(
        (value['addresses'] is List ? value['addresses'] as List : const [])
            .whereType<String>()
            .where(isDisplayAddress)
            .toSet(),
      ),
    );
  }

  static bool isDisplayAddress(String value) {
    final address = InternetAddress.tryParse(value);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        address.isLoopback) {
      return false;
    }
    final bytes = address.rawAddress;
    return bytes[0] != 0 &&
        bytes[0] < 224 &&
        !(bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)) &&
        !(bytes[0] == 172 && bytes[1] == 19 && bytes[2] == 0 && bytes[3] < 4);
  }

  static List<String> physicalAddresses(
    Iterable<({String name, List<String> addresses})> interfaces, {
    required bool macos,
  }) {
    final result = <String>{};
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      if (macos && !['en', 'bridge', 'bond', 'vlan'].any(name.startsWith)) {
        continue;
      }
      if (['utun', 'tun', 'tap', 'ppp', 'ipsec', 'lo'].any(name.startsWith)) {
        continue;
      }
      result.addAll(interface.addresses.where(isDisplayAddress));
    }
    return result.toList();
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopLanState &&
      socksPort == other.socksPort &&
      httpPort == other.httpPort &&
      listEquals(addresses, other.addresses);

  @override
  int get hashCode =>
      Object.hash(socksPort, httpPort, Object.hashAll(addresses));
}
