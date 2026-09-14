import 'dart:convert';

import 'connection_mode.dart';
import 'vpn_backend.dart';

/// Optional LAN listeners for one session. The core keeps its local API private.
class LanProxySettings {
  final int socksPort;
  final int httpPort;
  final String username;
  final String password;

  const LanProxySettings({
    required this.socksPort,
    required this.httpPort,
    this.username = '',
    this.password = '',
  });

  Map<String, dynamic> toMap() {
    final user = username.trim();
    final authenticated = user.isNotEmpty && password.isNotEmpty;
    final normalizedUser = authenticated ? user : '';
    final normalizedPassword = authenticated ? password : '';
    for (final value in [normalizedUser, normalizedPassword]) {
      if (utf8.encode(value).length > 255 ||
          value.runes.any((c) => c < 32 || c >= 127 && c <= 159)) {
        throw const FormatException(
          'LAN credentials must be at most 255 UTF-8 bytes without control characters.',
        );
      }
    }
    if (normalizedUser.contains(':')) {
      throw const FormatException('LAN usernames cannot contain a colon.');
    }
    return {
      'socksPort': socksPort,
      'httpPort': httpPort,
      'username': normalizedUser,
      'password': normalizedPassword,
    };
  }
}

/// параметры запуска туннеля (android tun и desktop proxy/tun)
class TunnelSessionRequest {
  final ConnectionMode mode;
  final VpnBackend vpnBackend;
  final String xrayConfig;

  /// Конфиг mihomo (когда [vpnBackend] == mihomo). JSON — ядро читает его как
  /// YAML, тот надмножество; см. MihomoConfigGen.
  final String? mihomoConfig;
  final int socksPort;
  final int httpPort;
  final LanProxySettings? lan;
  final String? singboxConfig;
  final List<String> excludePackages;
  final List<String> includePackages;
  final List<String> excludeProcesses;
  final List<String> includeProcesses;
  final String? serverName;
  final bool systemProxy;
  final bool killSwitch;
  final bool blockIpv6Leak;

  /// Ядро: `chain` (xray → sing-box) или `keqrnel` (единое ядро). Дефолт `chain`.
  final String coreEngine;

  /// Дебаг-режим приложения. Включает то, что стоит денег в рантайме и нужно
  /// только для диагностики: поиск процесса-владельца соединения в sing-box
  /// (`find_process`) для дебаг-экрана «Соединения».
  final bool debugMode;

  const TunnelSessionRequest({
    required this.mode,
    this.vpnBackend = VpnBackend.xray,
    required this.xrayConfig,
    this.mihomoConfig,
    this.socksPort = 2080,
    this.httpPort = 2081,
    this.lan,
    this.singboxConfig,
    this.excludePackages = const [],
    this.includePackages = const [],
    this.excludeProcesses = const [],
    this.includeProcesses = const [],
    this.serverName,
    this.systemProxy = true,
    this.killSwitch = false,
    this.blockIpv6Leak = false,
    this.coreEngine = 'chain',
    this.debugMode = false,
  });

  Map<String, dynamic> toMethodChannelArgs({
    required String socksUsername,
    required String socksPassword,
  }) =>
      {
        'connectionMode': mode.storageValue,
        'vpnBackend': vpnBackend.wireValue,
        'xrayConfig': xrayConfig,
        if (mihomoConfig != null && mihomoConfig!.isNotEmpty)
          'mihomoConfig': mihomoConfig,
        'socksPort': socksPort,
        if (singboxConfig != null && singboxConfig!.isNotEmpty)
          'singboxConfig': singboxConfig,
        'socksUsername': socksUsername,
        'socksPassword': socksPassword,
        'excludePackages': excludePackages,
        'includePackages': includePackages,
        'excludeProcesses': excludeProcesses,
        'includeProcesses': includeProcesses,
        'systemProxy': systemProxy,
        'killSwitch': killSwitch,
        'coreEngine': coreEngine,
        if (serverName != null && serverName!.isNotEmpty) 'serverName': serverName,
      };
}
