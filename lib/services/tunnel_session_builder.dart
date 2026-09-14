import 'dart:io';

import '../models/app_settings.dart';
import '../tunnel/app_routing_mode.dart';
import '../tunnel/connection_mode.dart';
import '../tunnel/tunnel_session_request.dart';
import '../tunnel/vpn_backend.dart';
import '../utils/geo_dat_reader.dart';
import '../utils/singbox_tun_config.dart';

/// собирает TunnelSessionRequest под платформу и режим proxy/tun
class TunnelSessionBuilder {
  /// Only macOS TUN receives the helper's protected physical DNS snapshot.
  static bool usePhysicalBootstrapDns(ConnectionMode mode, {bool? isMacOS}) =>
      (isMacOS ?? Platform.isMacOS) && mode == ConnectionMode.tun;

  static ConnectionMode resolveMode(
    AppSettings settings, {
    bool? isAndroid,
  }) {
    final android = isAndroid ?? Platform.isAndroid;
    // на Android сохранённый режим только если выбран руками, до 0.13.0 у всех лежит proxy
    if (android && !settings.connectionModeChosen) return ConnectionMode.tun;
    return ConnectionMode.fromStorage(settings.connectionMode);
  }

  static TunnelSessionRequest build({
    required AppSettings settings,
    required String xrayConfig,
    VpnBackend vpnBackend = VpnBackend.xray,
    String? mihomoConfig,
    String resolvedServerIp = '',
    String socksUsername = '',
    String socksPassword = '',
    List<String> excludePackages = const [],
    List<String> includePackages = const [],
    List<String> excludeProcesses = const [],
    List<String> includeProcesses = const [],
    List<String> managedProcessPaths = const [],
    List<GeoDomain> chinaDnsDomains = const [],
    bool delegateRoutingToXray = false,
    String? serverName,
    AppRoutingMode routingMode = AppRoutingMode.allProxy,
    ConnectionMode? modeOverride,

    /// Есть ли у машины глобальный IPv6 — решает, забирать ли IPv6 в туннель
    /// (см. [TunSettings.blockIpv6Leak]). Считает вызывающий: здесь нельзя,
    /// метод синхронный, а перечисление интерфейсов — нет.
    bool hostHasIpv6 = false,
  }) {
    final mode = modeOverride ?? resolveMode(settings);

    // На macOS TUN остаётся в sing-box внутри keqrnel; Windows/Linux используют native Xray.
    // В proxy-режиме sing-box не нужен (системный прокси).
    String? singboxConfig;
    if (Platform.isMacOS &&
        mode == ConnectionMode.tun &&
        vpnBackend == VpnBackend.xray) {
      if (settings.xrayCore.udpPerAddress) {
        throw UnsupportedError('UDP per-exit routing requires mihomo on macOS. Disable this option to use Xray TUN.');
      }
      final managed = switch (routingMode) {
        AppRoutingMode.onlySelected => includeProcesses,
        AppRoutingMode.allExceptSelected => excludeProcesses,
        AppRoutingMode.allProxy => const <String>[],
      };
      singboxConfig = SingBoxTunConfigGen.generate(
        localSocksPort: settings.localPort,
        socksUsername: socksUsername,
        socksPassword: socksPassword,
        serverIpToExclude: resolvedServerIp,
        settings: settings,
        chinaDnsDomains: chinaDnsDomains,
        delegateRoutingToXray: delegateRoutingToXray,
        managedProcessNames: managed,
        managedProcessPaths: managedProcessPaths,
        routingMode: routingMode,
        appProcessPath: Platform.resolvedExecutable,
        hostHasIpv6: hostHasIpv6,
      );
    }

    return TunnelSessionRequest(
      mode: mode,
      vpnBackend: vpnBackend,
      xrayConfig: xrayConfig,
      mihomoConfig: mihomoConfig,
      socksPort: settings.localPort,
      httpPort: settings.httpPort,
      lan: settings.lanSharing
          ? LanProxySettings(
              socksPort: settings.lanSocksPort,
              httpPort: settings.lanHttpPort,
              username: settings.lanUsername,
              password: settings.lanPassword,
            )
          : null,
      singboxConfig: singboxConfig,
      excludePackages: excludePackages,
      includePackages: includePackages,
      excludeProcesses: excludeProcesses,
      includeProcesses: includeProcesses,
      serverName: serverName,
      systemProxy: settings.systemProxyEnabled,
      blockIpv6Leak: settings.tun.blockIpv6Leak,
      coreEngine: settings.coreEngine,
      debugMode: settings.debugMode,
    );
  }
}
