import 'dart:io';

import 'package:path/path.dart' as p;

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

  /// Режим сессии из настроек — теперь и на Android.
  ///
  /// Раньше здесь стояло жёсткое `tun`: другого пути на Android не было, весь
  /// трафик забирал VpnService. Режим «прокси» его не поднимает вовсе — ядро
  /// слушает 127.0.0.1, а кого через него пускать, решает пользовательница в
  /// настройках приложений или Wi-Fi.
  ///
  /// [isAndroid] параметром, а не только из [Platform]: тесты идут на хосте,
  /// где `Platform.isAndroid` всегда false, и ветку Android иначе не проверить.
  static ConnectionMode resolveMode(
    AppSettings settings, {
    bool? isAndroid,
  }) {
    final android = isAndroid ?? Platform.isAndroid;
    // Сохранённый режим на Android учитываем только если его выбирали руками.
    // До 0.13.0 поле там не читалось вовсе, и в настройках у всех лежит
    // десктопный дефолт `proxy`, которого никто не просил: уважить его молча —
    // значит выключить туннель всему, что обновилось.
    if (android && !settings.connectionModeChosen) return ConnectionMode.tun;
    return ConnectionMode.fromStorage(settings.connectionMode);
  }

  static TunnelSessionRequest build({
    required AppSettings settings,
    required String xrayConfig,
    VpnBackend vpnBackend = VpnBackend.xray,
    String? mihomoConfig,
    required String resolvedServerIp,
    required String socksUsername,
    required String socksPassword,
    List<String> excludePackages = const [],
    List<String> includePackages = const [],
    List<String> excludeProcesses = const [],
    List<String> includeProcesses = const [],
    List<String> managedProcessPaths = const [],
    List<GeoDomain> chinaDnsDomains = const [],
    String? serverName,
    AppRoutingMode routingMode = AppRoutingMode.allProxy,
    ConnectionMode? modeOverride,

    /// Есть ли у машины глобальный IPv6 — решает, забирать ли IPv6 в туннель
    /// (см. [TunSettings.blockIpv6Leak]). Считает вызывающий: здесь нельзя,
    /// метод синхронный, а перечисление интерфейсов — нет.
    bool hostHasIpv6 = false,
  }) {
    final mode = modeOverride ?? resolveMode(settings);

    // TUN на десктопе: sing-box оборачивает tun → локальный SOCKS xray с auth.
    // В proxy-режиме sing-box не нужен (системный прокси).
    String? singboxConfig;
    if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
        mode == ConnectionMode.tun &&
        vpnBackend == VpnBackend.xray) {
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
        managedProcessNames: managed,
        managedProcessPaths: managedProcessPaths,
        routingMode: routingMode,
        appProcessName: Platform.isMacOS
            ? ''
            : p.basename(Platform.resolvedExecutable),
        appProcessPath: Platform.isMacOS ? Platform.resolvedExecutable : '',
        macos: Platform.isMacOS,
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
      killSwitch: settings.killSwitch,
      blockIpv6Leak: settings.tun.blockIpv6Leak,
      coreEngine: settings.coreEngine,
      debugMode: settings.debugMode,
    );
  }
}
