part of 'providers.dart';

/// Tests can advance recovery time without sleeping or changing system clocks.
final macOSRecoveryClockProvider = Provider<DateTime Function()?>(
  (ref) => null,
);

/// Что делать с состоянием из натива, пока идёт наша попытка подключения.
enum ConnectInFlightAction {
  ignore,

  apply,

  applyAndFinish,
}

// до старта сессии сервис ещё не поднят и честно отвечает disconnected, это не исход попытки
ConnectInFlightAction connectInFlightAction(
  VpnStatus status, {
  required bool awaitingSessionStart,
}) {
  if (awaitingSessionStart && status == VpnStatus.disconnected) {
    return ConnectInFlightAction.ignore;
  }
  return switch (status) {
    VpnStatus.connected ||
    VpnStatus.disconnected => ConnectInFlightAction.applyAndFinish,
    VpnStatus.error => ConnectInFlightAction.apply,
    _ => ConnectInFlightAction.ignore,
  };
}

class VpnStateNotifier extends AsyncNotifier<VpnState> {
  StreamSubscription<VpnState>? _sub;
  StreamSubscription<MacOSServiceObservation>? _macObservations;
  MacOSRecoveryController? _recovery;
  int _connectGeneration = 0;
  Completer<void>? _connectFinished;
  bool _inputRestartPending = false;

  List<TrafficRoute> _macRuntimeRoutes({
    List<TrafficRoute>? routes,
    List<RoutingProfile>? profiles,
  }) {
    final profile = profileForSubscription(
      profiles ?? ref.read(routingProfilesProvider).value ?? const [],
      ref.read(serversProvider).activeServer?.subscriptionId,
    );
    final settings = ref.read(settingsNotifierProvider).value ??
        ref.read(storageProvider).cachedSettings ?? const AppSettings();
    final appsRun = appRoutesRun(TunnelSessionBuilder.resolveMode(settings));
    return orderedRoutes(profile?.routes ?? routes ??
            ref.read(routesProvider).value ?? const [])
        .where((route) => route.enabled && !routeIsEmpty(route) &&
            (route.allApps || appsRun))
        .toList();
  }

  String _macRoutingKey({
    List<TrafficRoute>? routes,
    List<RoutingProfile>? profiles,
  }) {
    final profile = profileForSubscription(
      profiles ?? ref.read(routingProfilesProvider).value ?? const [],
      ref.read(serversProvider).activeServer?.subscriptionId,
    );
    return jsonEncode([
      profile?.finalOutbound ??
          ref.read(settingsNotifierProvider).value?.finalOutbound,
      for (final route in _macRuntimeRoutes(routes: routes, profiles: profiles))
        route.toJson()..remove('id'),
    ]);
  }

  void _macRuleListUpdated(String url) {
    if (_recovery?.waiting == true &&
        routeListUrls(_macRuntimeRoutes()).contains(url)) {
      _macInputsChanged();
    }
  }

  void _macInputsChanged() {
    final recovery = _recovery;
    if (recovery?.waiting != true || _serverSwitchInProgress) return;
    ConnectionMode latestMode() =>
        (ref.read(settingsNotifierProvider).value ??
                ref.read(storageProvider).cachedSettings ??
                const AppSettings())
            .connectionModeEnum;
    if (_inputRestartPending) {
      // Coalesce changes while the same cleanup is still running. Readiness
      // must follow the latest mode, without issuing a second stop request.
      recovery!.mode = latestMode();
      _showRecovery();
      return;
    }
    _inputRestartPending = true;
    ++_connectGeneration;
    _cancelRequested = true;
    recovery!.begin(latestMode());
    final ticket = recovery.generation;
    unawaited(() async {
      try {
        await ref.read(vpnEngineProvider).stopVpn();
        await _connectFinished?.future;
        if (ref.mounted && recovery.wanted && ticket == recovery.generation) {
          recovery.mode = latestMode();
          recovery.failed('network_changed');
        }
      } catch (error) {
        if (ref.mounted && ticket == recovery.generation) {
          recovery.failed(macOSFailureCode(error), text: error.toString());
        }
      } finally {
        _inputRestartPending = false;
      }
    }());
  }

  void _showRecovery() {
    final recovery = _recovery;
    if (recovery == null || !ref.mounted) return;
    desktopRecoveryStatus.value = recovery.phase == MacOSRecoveryPhase.idle
        ? null
        : DesktopRecoveryStatus(
            recovery.phase,
            recovery.reason,
            recovery.message,
            recovery.retries,
          );
    if (recovery.waiting) {
      ActiveLocalPorts().clear();
      state = AsyncData(
        VpnState(status: VpnStatus.connecting, activeMode: recovery.mode),
      );
      _persistActiveLocalHttpPort(VpnStatus.connecting);
    } else if (recovery.phase == MacOSRecoveryPhase.paused) {
      state = AsyncData(
        VpnState(
          status: VpnStatus.error,
          errorMessage: recovery.message ?? recovery.reason,
          activeMode: recovery.mode,
        ),
      );
    }
  }

  void _observeMac(MacOSServiceObservation observation) {
    if (!ref.mounted) return;
    _recovery?.observe(
      service: observation.service,
      session: observation.session,
    );
    if (_recovery?.waiting == true) _showRecovery();
  }

  bool _connectInFlight = false;
  bool _awaitingSessionStart = false;
  bool _serverSwitchInProgress = false;
  Completer<void>? _serverSwitchFinished;
  // Selecting the current node can still supersede an earlier async choice.
  int? _pendingManualSelection;
  // Пользователь отменил попытку подключения (тап по кругу в connecting) —
  // connect-in-flight сворачивается в disconnected вместо error/connected.
  bool _cancelRequested = false;
  Completer<void>? _disconnectWaiter;
  Timer? _androidPollTimer;

  Timer? _autoSelectTimer;
  Timer? _autoSelectListenTimer;
  int _autoSelectSeenReceived = 0;
  int _autoSelectSeenSent = 0;
  int? _autoSelectSeenFailures;
  SilenceStreak _autoSelectSilence = const SilenceStreak();
  ({int down, int up})? _autoSelectCounters;
  final _autoSelectSwitches = <DateTime>[];
  DateTime? _autoSelectQuietUntil;
  bool _autoSelectBusy = false;

  bool _autoSelectListening = false;

  Timer? _autoSelectRecheckTimer;
  DateTime? _autoSelectRecheckAt;
  NeighbourHomePace _autoSelectHomePace = const NeighbourHomePace();
  int? _autoSelectRecheckSeenBytes;
  SubscriptionOutage _autoSelectOutage = const SubscriptionOutage();
  int _autoSelectDeadRounds = 0;
  int? _autoSelectNetworkMark;
  int _autoSelectRevision = 0;
  String? _autoSelectSampleSession;

  void _invalidateAutoSelect() {
    ++_autoSelectRevision;
    _autoSelectSeenFailures = null;
    _autoSelectSilence = const SilenceStreak();
    _autoSelectCounters = null;
    _autoSelectOutage = const SubscriptionOutage();
    _autoSelectDeadRounds = 0;
    _autoSelectNetworkMark = null;
    _autoSelectQuietUntil = null;
    _autoSelectRecheckSeenBytes = null;
    _autoSelectHomePace = const NeighbourHomePace();
  }

  /// A UI action carries this ticket across its asynchronous saves. A later
  /// disconnect, connect or selection invalidates it before it can start a core.
  int get connectionGeneration => _connectGeneration;

  bool get hasConnectionIntent =>
      _connectInFlight ||
      _serverSwitchInProgress ||
      state.value?.status == VpnStatus.connected ||
      state.value?.status == VpnStatus.connecting;

  int beginConnectionChange() {
    ++_connectGeneration;
    _cancelRequested = true;
    _recovery?.cancel();
    _invalidateAutoSelect();
    return _connectGeneration;
  }

  bool isConnectionChangeCurrent(int generation) =>
      ref.mounted && generation == _connectGeneration;

  /// A manual choice hands Auto back to the user. Selecting the current node
  /// does not tear down its session or cancel its recovery intent.
  Future<void> selectServerManually(
    ServerItem server, {
    bool reconnectIfActive = false,
  }) async {
    if (_pendingManualSelection == null &&
        ref.read(serversProvider).activeServerId == server.id) {
      _invalidateAutoSelect();
      await ref.read(subscriptionsProvider.notifier).handAutoSelectTo(null);
      return;
    }
    final status = state.value?.status;
    final reconnect =
        reconnectIfActive &&
        (status == VpnStatus.connected ||
            status == VpnStatus.connecting ||
            _connectInFlight ||
            _serverSwitchInProgress);
    final generation = beginConnectionChange();
    _pendingManualSelection = generation;
    try {
      await ref.read(subscriptionsProvider.notifier).handAutoSelectTo(null);
      if (!isConnectionChangeCurrent(generation)) return;
      await ref.read(serversProvider.notifier).setActive(server);
      if (!isConnectionChangeCurrent(generation)) return;
      if (reconnect) {
        await reconnectToActiveServer(expectedGeneration: generation);
      }
    } finally {
      if (_pendingManualSelection == generation) {
        _pendingManualSelection = null;
      }
    }
  }

  AppLifecycleListener? _androidLifecycle;

  void _applyNativeState(VpnState s) {
    if (state.value?.status != s.status) _invalidateAutoSelect();
    _restoreSocksCredentialsIfNeeded(s);
    _syncMihomoApiSession(s);
    _persistActiveLocalHttpPort(s.status);
    if (_serverSwitchInProgress && s.status == VpnStatus.error) return;
    final recovery = _recovery;
    if (!_connectInFlight && recovery?.wanted == true) {
      if (s.status == VpnStatus.connected) {
        recovery!.connected();
      } else if (s.status == VpnStatus.error) {
        final backend = ref.read(vpnEngineProvider).macOSBackend;
        final snapshot = backend?.lastSnapshot;
        if (snapshot?['errorCode'] is String) {
          recovery!.failed(
            snapshot!['errorCode'] as String,
            text: s.errorMessage,
            occurrence: backend!.failureOccurrence,
          );
        }
      }
      if (recovery!.waiting) {
        _showRecovery();
        return;
      }
    }
    if (_connectInFlight) {
      switch (connectInFlightAction(
        s.status,
        awaitingSessionStart: _awaitingSessionStart,
      )) {
        case ConnectInFlightAction.ignore:
          break;
        case ConnectInFlightAction.apply:
          state = AsyncData(s);
        case ConnectInFlightAction.applyAndFinish:
          state = AsyncData(s);
          _connectInFlight = false;
      }
      return;
    }
    final current = state.value;
    if (current != null &&
        current.status == s.status &&
        current.telemetryEquals(s)) {
      return;
    }
    state = AsyncData(s);
  }

  // для фоновых изолятов: мимо туннеля им нельзя, а пробовать порт мало, на нём может слушать чужой клиент
  void _persistActiveLocalHttpPort(VpnStatus status) {
    final storage = ref.read(storageProvider);
    if (status != VpnStatus.connected) {
      // сброс без await, иначе зависшая запись подключения воскресит порт после отключения
      if (storage.getActiveLocalHttpPort() != null) {
        unawaited(storage.setActiveLocalHttpPort(null));
      }
      return;
    }
    unawaited(_writeActiveLocalHttpPort(storage));
  }

  Future<void> _writeActiveLocalHttpPort(StorageService storage) async {
    // на Android через getSettings: кэш может быть холодным, и на диск уехал бы порт по умолчанию
    final port =
        ActiveLocalPorts().httpPort ?? (await storage.getSettings()).httpPort;
    if (!ref.mounted) return;
    if (state.value?.status != VpnStatus.connected) return;
    // пароль сверяем тоже: после реконнекта порт прежний, а пароль новый
    final creds = Socks5Credentials();
    final stored = storage.getActiveLocalHttpCredentials();
    if (storage.getActiveLocalHttpPort() == port &&
        stored.username == creds.username &&
        stored.password == creds.password) {
      return;
    }
    await storage.setActiveLocalHttpPort(
      port,
      username: creds.username,
      password: creds.password,
    );
  }

  bool _credsRestoreInFlight = false;

  // VpnService переживает пересоздание движка, и без кредов свежий изолят получает 407
  void _restoreSocksCredentialsIfNeeded(VpnState s) {
    if (!Platform.isAndroid) return;
    if (s.status != VpnStatus.connected) return;
    if (Socks5Credentials().isInitialized) return;
    if (_credsRestoreInFlight) return;
    _credsRestoreInFlight = true;
    unawaited(() async {
      try {
        final creds = await ref
            .read(vpnEngineProvider)
            .fetchActiveSocksCredentials();
        if (creds != null) {
          Socks5Credentials().init(creds.username, creds.password);
          AppLogger.instance.info(
            'SOCKS5 credentials restored from the running VPN service',
          );
        }
      } finally {
        _credsRestoreInFlight = false;
      }
    }());
  }

  bool _mihomoApiRestoreInFlight = false;

  void _syncMihomoApiSession(VpnState s) {
    final api = MihomoApiSession();
    if (s.status == VpnStatus.disconnected || s.status == VpnStatus.error) {
      api.clear();
      return;
    }
    if (!Platform.isAndroid) return;
    if (s.status != VpnStatus.connected) return;
    if (api.isActive || _mihomoApiRestoreInFlight) return;
    _mihomoApiRestoreInFlight = true;
    unawaited(() async {
      try {
        final restored = await VpnNativeBridge.getMihomoApi();
        if (restored != null) {
          api.restore(port: restored.port, secret: restored.secret);
          AppLogger.instance.info(
            'mihomo API restored from the running VPN service',
          );
        }
      } finally {
        _mihomoApiRestoreInFlight = false;
      }
    }());
  }

  void _startAndroidPolling() {
    if (!Platform.isAndroid) return;
    _androidPollTimer?.cancel();
    _androidPollTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => unawaited(syncFromNative()),
    );
  }

  void _stopAndroidPolling() {
    _androidPollTimer?.cancel();
    _androidPollTimer = null;
  }

  void _onAndroidResumed() {
    if (!Platform.isAndroid) return;
    ref.read(vpnEngineProvider).refreshStateStream();
    unawaited(syncFromNative());
    _startAndroidPolling();
  }

  @override
  Future<VpnState> build() async {
    final engine = ref.read(vpnEngineProvider);
    final macBackend = engine.macOSBackend;
    if (macBackend != null) {
      _recovery ??= MacOSRecoveryController(
        attempt: (generation) async {
          if (!ref.mounted ||
              generation != _recovery?.generation ||
              _connectInFlight) {
            return;
          }
          await _connectOnce(
            automaticRecovery: true,
            recoveryGeneration: generation,
          );
        },
        onChanged: _showRecovery,
        now: ref.read(macOSRecoveryClockProvider),
      );
      unawaited(_macObservations?.cancel());
      _macObservations = macBackend.observations.listen(_observeMac);
      ref.listen(settingsNotifierProvider, (previous, next) {
        if (previous?.value != null &&
            next.value != null &&
            previous!.value != next.value) {
          _macInputsChanged();
        }
      });
      ref.listen(serversProvider.select((value) => value.activeServer), (
        previous,
        next,
      ) {
        if (previous != null && next != null && previous != next) {
          _macInputsChanged();
        }
      });
      ref.listen(routesProvider, (previous, next) {
        if (previous?.value != null && next.value != null &&
            _macRoutingKey(routes: previous!.value) !=
                _macRoutingKey(routes: next.value)) {
          _macInputsChanged();
        }
      });
      ref.listen(routingProfilesProvider, (previous, next) {
        if (previous?.value != null && next.value != null &&
            _macRoutingKey(profiles: previous!.value) !=
                _macRoutingKey(profiles: next.value)) {
          _macInputsChanged();
        }
      });
    }
    unawaited(_sub?.cancel());
    _sub = engine.stateStream.listen((s) {
      if (s.status == VpnStatus.disconnected) {
        final waiter = _disconnectWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      }
      _applyNativeState(s);
    });
    ref.listen(subscriptionsProvider, (previous, next) {
      String owners(AsyncValue<List<Subscription>>? value) =>
          (value?.value ?? const <Subscription>[])
              .where((subscription) => subscription.autoSelect)
              .map((subscription) => subscription.id)
              .join(',');
      if (owners(previous) != owners(next)) _invalidateAutoSelect();
    });
    ref.listen(settingsNotifierProvider, (previous, next) {
      if (previous?.value != next.value) _invalidateAutoSelect();
    });
    _autoSelectTimer?.cancel();
    _autoSelectTimer = Timer.periodic(
      AutoSelectWatchdog.probeEvery,
      (_) => unawaited(_autoSelectTick()),
    );
    _autoSelectListenTimer?.cancel();
    _autoSelectListenTimer = Timer.periodic(
      AutoSelectWatchdog.listenEvery,
      (_) => unawaited(_autoSelectListenOnce()),
    );
    _autoSelectRecheckTimer?.cancel();
    _autoSelectRecheckTimer = Timer.periodic(
      NeighbourHomePace.every,
      (_) => unawaited(_autoSelectRecheckTick()),
    );
    ref.onDispose(() {
      _autoSelectTimer?.cancel();
      _autoSelectListenTimer?.cancel();
      _autoSelectRecheckTimer?.cancel();
      ++_connectGeneration;
      _recovery?.dispose();
      desktopRecoveryStatus.value = null;
      _macObservations?.cancel();
      _sub?.cancel();
      _stopAndroidPolling();
      _androidLifecycle?.dispose();
      _androidLifecycle = null;
    });

    if (Platform.isAndroid) {
      _androidLifecycle?.dispose();
      _androidLifecycle = AppLifecycleListener(
        onResume: _onAndroidResumed,
        onPause: _stopAndroidPolling,
        onHide: _stopAndroidPolling,
      );
      _onAndroidResumed();
    }

    try {
      return await engine.getCurrentState();
    } catch (_) {
      return VpnState.disconnected;
    }
  }

  Future<void> syncFromNative() async {
    try {
      final s = await ref.read(vpnEngineProvider).getCurrentState();
      _applyNativeState(s);
    } catch (e, st) {
      AppLogger.instance.debug(
        'syncFromNative failed',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<VpnState> _awaitNativeConnectOutcome(VpnEngine engine) async {
    for (var i = 0; i < 150; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (_cancelRequested) {
        return const VpnState(status: VpnStatus.disconnected);
      }
      final s = await engine.getCurrentState();
      if (s.status == VpnStatus.connected ||
          s.status == VpnStatus.error ||
          s.status == VpnStatus.disconnected) {
        return s;
      }
    }
    return engine.getCurrentState();
  }

  Future<RuleListDomains> _cachedRuleLists(AppSettings settings) async {
    try {
      final lists = await ref.read(ruleListServiceProvider).domainsFor(settings);
      if (!lists.isEmpty) {
        AppLogger.instance.info(
          'Rule lists: block ${lists.blocked.length}, '
          'direct ${lists.direct.length}, proxy ${lists.proxy.length} domains',
        );
      }
      return lists;
    } catch (e, st) {
      AppLogger.instance.warn(
        'Rule lists unreadable, connecting without them',
        error: e,
        stackTrace: st,
      );
      return RuleListDomains.none;
    }
  }

  // на диск только правка поверх сохранённых настроек: в settings из connect() правила уже
  // сложены в списки, и так они приклеились бы к полям навсегда
  Future<void> _saveDuringConnect(
    AppSettings Function(AppSettings saved) change,
  ) async {
    final saved = await ref.read(settingsNotifierProvider.future);
    await ref.read(settingsNotifierProvider.notifier).save(change(saved));
  }

  // неизвестные geo-коды выбрасываем: xray на таком коде роняет весь конфиг. нечитаемый кэш списков подключению не мешает
  Future<({String entries, List<String> listDomains})> _prepareRouteEntries(
    String entries,
    GeoAssetIndex index,
  ) async {
    final clean = stripUnknownGeoTokensText(entries, index);
    if (clean.dropped.isNotEmpty) {
      AppLogger.instance.warn(
        'Route: geo code(s) not in the bundled bases dropped: '
        '${clean.dropped.join(', ')}',
      );
    }
    var listed = const <String>[];
    try {
      listed =
          await ref.read(ruleListServiceProvider).domainsForEntries(entries);
    } catch (e) {
      AppLogger.instance.warn('Rule lists for a route unreadable: $e');
    }
    return (entries: clean.text, listDomains: listed);
  }

  Future<List<RouteServerOutbound>> _prepareRouteServers(
    List<RouteServerOutbound> servers,
  ) async {
    if (servers.isEmpty) return servers;
    final index = await GeoAssetService.index();
    final out = <RouteServerOutbound>[];
    for (final server in servers) {
      final p = await _prepareRouteEntries(server.entries, index);
      out.add(server.copyWith(entries: p.entries, listDomains: p.listDomains));
    }
    return out;
  }

  Future<List<RouteAppRules>> _prepareAppRoutes(
    List<RouteAppRules> routes,
  ) async {
    if (routes.isEmpty) return routes;
    final index = await GeoAssetService.index();
    final installed = Platform.isMacOS
        ? await ref.read(vpnEngineProvider).getInstalledApps(includeSystem: true)
        : const <Map<String, dynamic>>[];
    final out = <RouteAppRules>[];
    for (final route in routes) {
      final p = await _prepareRouteEntries(route.entries, index);
      out.add(RouteAppRules(
        tag: route.tag,
        apps: Platform.isMacOS ? expandMacOSRouteApps(route.apps, installed) : route.apps,
        target: route.target,
        serverTag: route.serverTag,
        allTraffic: route.allTraffic,
        entries: p.entries,
        listDomains: p.listDomains,
      ));
    }
    return out;
  }

  Future<void> connect({bool autostartTunFallback = false}) async {
    if (_connectInFlight) return;
    final settings =
        ref.read(settingsNotifierProvider).value ??
        ref.read(storageProvider).cachedSettings ??
        const AppSettings();
    final generation = _recovery?.begin(settings.connectionModeEnum);
    await _connectOnce(
      autostartTunFallback: autostartTunFallback,
      recoveryGeneration: generation,
    );
  }

  Future<void> _connectOnce({
    bool autostartTunFallback = false,
    bool automaticRecovery = false,
    int? recoveryGeneration,
  }) async {
    if (_connectInFlight) {
      AppLogger.instance.debug(
        'VPN connect() ignored: connect already in progress',
      );
      return;
    }

    final server = ref.read(serversProvider).activeServer;
    if (server == null) {
      _recovery?.failed('noActiveServer', text: 'No active server selected');
      state = AsyncData(
        VpnState(
          status: VpnStatus.error,
          errorMessage: 'No active server selected',
        ),
      );
      return;
    }

    _connectInFlight = true;
    final finished = _connectFinished = Completer<void>();
    final operation = ++_connectGeneration;
    bool cancelled() =>
        !ref.mounted ||
        operation != _connectGeneration ||
        _cancelRequested ||
        recoveryGeneration != null &&
            recoveryGeneration != _recovery?.generation;
    _cancelRequested = false;
    _awaitingSessionStart = true;

    try {
      await ref.read(serversProvider.notifier).setActive(server);

      final engine = ref.read(vpnEngineProvider);

      final native = await engine.getCurrentState();
      if (cancelled()) return;
      if (native.status == VpnStatus.connected) {
        _recovery?.connected();
        state = AsyncData(native);
        return;
      }
      if (native.status == VpnStatus.connecting) {
        // сервис уже поднят плиткой или уведомлением, отсечка больше не нужна
        _awaitingSessionStart = false;
        state = AsyncData(native);
        final settled = await _awaitNativeConnectOutcome(engine);
        state = AsyncData(settled);
        if (_cancelRequested ||
            settled.status == VpnStatus.connected ||
            settled.status == VpnStatus.error) {
          return;
        }
      } else {
        state = const AsyncData(VpnState(status: VpnStatus.connecting));
      }
      final storage = ref.read(storageProvider);
      final profile =
          profileForServer(await storage.getRoutingProfiles(), server);
      final saved = await storage.getSettings();
      // «Всё остальное» профиля только в эту сессию: на диск настройки пишет лишь _saveDuringConnect
      final stored = profile == null
          ? saved
          : saved.copyWith(finalOutbound: profile.finalOutbound);
      final routes = profile?.routes ?? await storage.getRoutes();
      if (profile != null) {
        AppLogger.instance.info('Routing profile: ${profile.name}');
      }

      // готовый конфиг исполняет ядро его языка, настройка решает только для обычной ссылки.
      // выбираем до свёртки маршрутов: от ядра зависит, какие другие серверы встанут в конфиг
      final choice = resolveVpnBackend(
        config: server.config,
        preference: stored.vpnCore,
        mihomoAvailable: mihomoShipsHere,
      );
      // режим сохранённый: если автозапуск откатится в прокси, генератор без туннеля правил по процессам и так не напишет
      final appsRun = appRoutesRun(TunnelSessionBuilder.resolveMode(stored));
      final routeServers = await _prepareRouteServers(
        routeServerOutbounds(
          routes: routes,
          servers: ref.read(serversProvider).servers,
          activeServerId: server.id,
          core: choice.backend,
          withApps: appsRun,
        ),
      );
      final appRoutes = appsRun
          ? await _prepareAppRoutes(
              routeAppRules(routes: routes, outbounds: routeServers),
            )
          : const <RouteAppRules>[];

      // маршрут на сервер без своего выхода (пропал, совпал с активным, не встаёт в ядро) уходит через VPN.
      // неизвестные geo-коды выбрасываем: xray на них падает целиком (SOCKS port not ready)
      final requestedSettings = foldRoutes(
        stored,
        routes,
        serverUsable: (r) => routeServers.any((o) => o.serverId == r.serverId),
      );
      var settings = await GeoAssetService.sanitizeRules(requestedSettings);
      if (cancelled()) return;
      if (settings.xrayCore.dnsUseCustom) {
        final dropped = XrayCoreSettings.xrayDnsServers(
          settings.xrayCore.dnsServers,
        ).dropped;
        if (dropped.isNotEmpty) {
          AppLogger.instance.warn(
            'Custom DNS: ${dropped.length} address(es) dropped — the core '
            'cannot run them: ${dropped.join(', ')}. Supported: plain ip[:port], '
            'https+local://, https://, h2c://, tcp://, quic+local://, '
            'localhost, fakedns.',
          );
        }
      }
      final ruleLists = await _cachedRuleLists(settings);

      final split = ref.read(splitTunnelingProvider);
      final excludePkgs = split.excludePackages.toList();
      final includePkgs = split.includePackages.toList();
      var routingMode = routingModeFromSplit(
        includePackages: split.includePackages,
        excludePackages: split.excludePackages,
      );
      final processNames = (Platform.isWindows || Platform.isLinux)
          ? processNamesForSplit(
              includePackages: split.includePackages,
              excludePackages: split.excludePackages,
            )
          : const <String>[];

      final macRouting = Platform.isMacOS
          ? await MacOSAppRoutingStore.load()
          : null;
      if (macRouting != null) routingMode = macRouting.mode;
      var connectionMode = TunnelSessionBuilder.resolveMode(settings);
      if (_recovery != null) _recovery!.mode = connectionMode;

      if (Platform.isMacOS &&
          (autostartTunFallback || automaticRecovery) &&
          engine.usesMacOSNetworkService) {
        final service = await engine.macOSBackend!.fetchServiceStatus();
        if (!MacOSTunnelBackend.canConnectWithoutPrompt(
          service,
          connectionMode,
        )) {
          throw const VpnPermissionDeniedException(
            'Automatic connection requires a matching macOS network service. TUN also requires prior account authorization.',
          );
        }
      }

      if (Platform.isAndroid && connectionMode != ConnectionMode.proxy) {
        final permitted = await engine.requestVpnPermission();
        if (!permitted) throw const VpnPermissionDeniedException();
      }
      if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
          connectionMode == ConnectionMode.proxy &&
          routingMode != AppRoutingMode.allProxy) {
        AppLogger.instance.warn(
          'Split tunneling rules are ignored in Proxy mode on desktop: without '
          'a tunnel the core cannot tell which process a connection belongs '
          'to. The session runs as "all traffic" instead — switch to TUN mode '
          'to apply per-process rules.',
        );
      }
      if (Platform.isWindows && connectionMode == ConnectionMode.tun) {
        final elevated = await engine.requestVpnPermission();
        if (!elevated) {
          if (autostartTunFallback) {
            connectionMode = ConnectionMode.proxy;
            AppLogger.instance.warn(
              'Autostart: TUN requires admin rights, falling back to Proxy',
            );
            // иначе интерфейс остаётся в TUN, и повторный выбор TUN не срабатывает (next == current)
            await _saveDuringConnect(
              (saved) => saved.copyWith(
                connectionMode: ConnectionMode.proxy.storageValue,
              ),
            );
          } else {
            AppLogger.instance.warn(
              'TUN mode: app is not elevated. The core may fail to create routes.',
            );
          }
        }
      }

      // настроенный порт может держать сосед, а на Windows диапазоны изымают Hyper-V и WSL,
      // поэтому подбираем рабочий и настройки не переписываем
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final portPlan = await LocalPortResolver.resolve(settings);
        for (final change in portPlan.changes) {
          AppLogger.instance.warn(change.describe());
        }
        settings = portPlan.applyTo(settings);
        ActiveLocalPorts().set(
          socksPort: portPlan.socksPort,
          httpPort: portPlan.httpPort,
          lanSocksPort: settings.lanSharing ? portPlan.lanSocksPort : null,
          lanHttpPort: settings.lanSharing ? portPlan.lanHttpPort : null,
        );
      }

      final processPaths =
          macRouting != null && connectionMode == ConnectionMode.tun
          ? await MacOSAppRoutingStore.resolvePaths(
              macRouting,
              routingMode == AppRoutingMode.allProxy
                  ? const []
                  : await engine.getInstalledApps(includeSystem: true),
            )
          : const <String>[];

      final creds = await engine.fetchSocksCredentials();
      // в режиме прокси креды вписывают руками в чужое приложение, сессионные протухали бы на реконнекте
      if (cancelled()) return;
      if (Platform.isAndroid &&
          connectionMode == ConnectionMode.proxy &&
          settings.proxyModeAuth) {
        var user = settings.proxyModeUser;
        var pass = settings.proxyModePass;
        if (user.isEmpty || pass.isEmpty) {
          user = randomProxyToken(12);
          pass = randomProxyToken(20);
          settings = settings.copyWith(proxyModeUser: user, proxyModePass: pass);
          await _saveDuringConnect(
            (saved) => saved.copyWith(proxyModeUser: user, proxyModePass: pass),
          );
        }
        Socks5Credentials().init(user, pass);
      } else {
        Socks5Credentials().init(creds.username, creds.password);
      }

      final serverIp = Platform.isMacOS
          ? server.address
          : await _resolveFirstAddress(server.address) ?? server.address;

      // системный прокси Windows/GNOME и поле прокси у Wi-Fi не умеют пароль: с auth браузеры
      // спрашивают его без конца, а на Android ядро отбивает каждое соединение
      final proxyModeNoAuth = connectionMode == ConnectionMode.proxy &&
          (!Platform.isAndroid || !settings.proxyModeAuth);

      // несовпадение ядра с выбором пишем в лог: раньше это выглядело как настройка не работает
      if (choice.skip != null) {
        AppLogger.instance.warn(
          'Core preference "${settings.vpnCore}" is not used for this server: '
          '${vpnCoreSkipLogReason(choice.skip!)}. Running it on '
          '${choice.backend.wireValue}.',
        );
      }

      final vpnBackend = choice.backend;
      final mihomoPicked = vpnBackend == VpnBackend.mihomo;

      final ownerGuard = ownerGuardFor(
        android: Platform.isAndroid,
        tun: connectionMode == ConnectionMode.tun,
        routingMode: routingMode,
        sdkInt: await ref.read(androidSdkIntProvider.future),
      );

      final mihomoApi = MihomoApiSession();
      if (mihomoPicked) {
        await mihomoApi.renew();
      } else {
        mihomoApi.clear();
      }

      final MihomoTunOptions? mihomoTun;
      if (!mihomoPicked) {
        mihomoTun = null;
      } else if (Platform.isAndroid) {
        mihomoTun = const MihomoTunOptions(
          fromFileDescriptor: true,
          // на Android без root работает только gvisor
          stack: TunSettings.stackGvisor,
          autoRoute: false,
        );
      } else if (connectionMode == ConnectionMode.tun) {
        mihomoTun = MihomoTunOptions(
          device: Platform.isMacOS ? null : kTunInterfaceName,
          stack: settings.tun.stack,
          mtu: settings.tun.mtu,
          autoRoute: settings.tun.autoRoute,
          strictRoute:
              !Platform.isMacOS &&
              settings.tun.strictRouteEnabled(windows: Platform.isWindows),
        );
      } else {
        mihomoTun = null;
      }

      final mihomoConfig = mihomoPicked
          ? MihomoConfigGen.generate(
              server.config,
              settings,
              socksPort: settings.localPort,
              // Dart HttpClient не умеет SOCKS, а пакет приложения исключён из TUN, так что http-порт нужен и тут
              httpPort: settings.httpPort,
              resolvedServerIp: serverIp,
              localInboundsNoAuth: proxyModeNoAuth,
              apiPort: mihomoApi.port,
              apiSecret: mihomoApi.secret,
              tun: mihomoTun,
              routingMode: routingMode,
              managedProcessNames: switch (routingMode) {
                AppRoutingMode.onlySelected ||
                AppRoutingMode.allExceptSelected => processNames,
                AppRoutingMode.allProxy => const <String>[],
              },
              managedProcessPaths: processPaths,
              appProcessPath: Platform.isMacOS
                  ? Platform.resolvedExecutable
                  : '',
              appProcessName: Platform.isAndroid || Platform.isMacOS
                  ? ''
                  : p.basename(Platform.resolvedExecutable),
              ruleLists: ruleLists,
              routeServers: routeServers,
              appRoutes: appRoutes,
              ownerGuard: ownerGuard,
            )
          : null;

      final customGeoIndex =
          server.protocol == 'custom' ? await GeoAssetService.index() : null;
      if (server.protocol == 'custom') {
        final parsed = CustomXrayConfig.tryParse(server.config);
        final dead = parsed == null
            ? (rules: 0, tags: const <String>[])
            : previewDeadInboundRules(
                parsed.json,
                ConfigGeneratorV2.appInboundTags,
              );
        if (dead.rules > 0) {
          AppLogger.instance.warn(
            'Provider config: ${dead.rules} routing rule(s) are bound to '
            'inbound tags this app does not create '
            '(${dead.tags.toSet().join(', ')}). The app replaces the config '
            'inbounds with its own — those rules will never match, and their '
            'traffic follows "unmatched traffic" in Settings → Routing.',
          );
        }
      }
      if (customGeoIndex != null && !customGeoIndex.isEmpty) {
        final parsed = CustomXrayConfig.tryParse(server.config);
        final lost = parsed == null
            ? (tokens: const <String>[], removedRules: 0)
            : previewUnknownGeo(parsed.json, customGeoIndex);
        if (lost.removedRules > 0) {
          final blocked =
              settings.finalOutbound == AppSettings.finalOutboundBlock;
          AppLogger.instance.warn(
            'Provider config: ${lost.removedRules} routing rule(s) were '
            'dropped — their geo codes are not in the bundled databases: '
            '${lost.tokens.toSet().join(', ')}. The core exits on an unknown '
            'code, so the rules cannot be kept. Their traffic now falls '
            'through to "unmatched traffic" in Settings → Routing'
            '${blocked ? ', which is set to BLOCK — that traffic will not '
                      'connect at all. Set it to Proxy or Bypass, or replace the '
                      'codes in the config.' : '.'}',
          );
        }
      }

      final desktop = Platform.isWindows || Platform.isLinux;
      final xrayDesktopTun =
          desktop && connectionMode == ConnectionMode.tun && !mihomoPicked;
      final strictRoute =
          settings.tun.strictRouteEnabled(windows: Platform.isWindows);
      // IPv6-адрес на TUN при выключенном в системе IPv6 роняет ядро. строгий маршрут на Linux закрывал IPv6
      // без маршрута (sing-tun, unreachable), теперь так же: захват и блок
      final captureIpv6 = xrayDesktopTun &&
          (settings.tun.blockIpv6Leak || (Platform.isLinux && strictRoute)) &&
          await hostHasGlobalIpv6(excludeInterfaceName: kTunInterfaceName);

      final listedSettings =
          mihomoPicked ? settings : ruleLists.expand(settings);

      final xrayConfig = mihomoPicked
          ? ''
          : ConfigGeneratorV2.generateConfig(
              server.config,
              listedSettings,
              resolvedServerIp: serverIp,
              localInboundsNoAuth: proxyModeNoAuth,
              geoIndex: customGeoIndex,
              nativeTunInbound: Platform.isAndroid &&
                  connectionMode == ConnectionMode.tun &&
                  !mihomoPicked,
              desktopTun: xrayDesktopTun
                  ? DesktopTunOptions(
                      windows: Platform.isWindows,
                      mtu: settings.tun.mtu,
                      autoRoute: settings.tun.autoRoute,
                      strictRoute: strictRoute,
                      captureIpv6: captureIpv6,
                      udpTimeoutSec: settings.tun.udpTimeoutSec,
                      routingMode: routingMode,
                      managedProcessNames:
                          routingMode == AppRoutingMode.allProxy
                              ? const []
                              : processNames,
                      appProcessName: p.basename(Platform.resolvedExecutable),
                      systemResolvers: Platform.isLinux
                          ? linuxSystemResolvers(ipv6: captureIpv6)
                          : const [],
                    )
                  : null,
              physicalBootstrapDns: TunnelSessionBuilder.usePhysicalBootstrapDns(connectionMode),
              macosTunRouting: Platform.isMacOS && connectionMode == ConnectionMode.tun,
              routeServers: routeServers,
              appRoutes: appRoutes,
              ownerGuard: ownerGuard,
            );

      if (mihomoPicked &&
          connectionMode == ConnectionMode.tun &&
          settings.tun.blockIpv6Leak &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
          await hostHasGlobalIpv6(excludeInterfaceName: kTunInterfaceName)) {
        if (Platform.isMacOS) {
          throw const VpnStartException(
            'Mihomo on macOS cannot guarantee IPv6 leak protection. Select the keqrnel core before connecting.',
          );
        }
        AppLogger.instance.warn(
          'This machine has global IPv6, but the tunnel here belongs to the '
          'mihomo core, which keeps its own IPv6 handling — the TUN option '
          '"keep IPv6 inside the tunnel" covers the xray core only. '
          'IPv6 traffic can therefore bypass the tunnel; switch the core to '
          'xray in Settings → About if that matters.',
        );
      }

      // macOS keeps the sing-box DNS frontend around Xray.
      if (!mihomoPicked &&
          Platform.isMacOS &&
          connectionMode == ConnectionMode.tun) {
        final ignored = SingBoxTunConfigGen.ignoredCustomDnsServers(settings);
        if (ignored.isNotEmpty) {
          AppLogger.instance.warn(
            'Custom DNS: TUN uses one address per DNS group. Not used: '
            '${ignored.join(', ')}.',
          );
        }
      }

      final chinaDnsDomains = !mihomoPicked &&
              Platform.isMacOS &&
              connectionMode == ConnectionMode.tun &&
              SingBoxTunConfigGen.needsChinaDnsDomains(requestedSettings)
          ? await GeoAssetService.chinaDnsDomains()
          : const <GeoDomain>[];

      final session = TunnelSessionBuilder.build(
        settings: listedSettings,
        resolvedServerIp: serverIp,
        socksUsername: creds.username,
        socksPassword: creds.password,
        hostHasIpv6: Platform.isMacOS && connectionMode == ConnectionMode.tun && settings.tun.blockIpv6Leak && !mihomoPicked
            ? await hostHasGlobalIpv6() : false,
        delegateRoutingToXray: Platform.isMacOS && connectionMode == ConnectionMode.tun && (routeServers.isNotEmpty || appRoutes.isNotEmpty),
        chinaDnsDomains: chinaDnsDomains,
        xrayConfig: xrayConfig,
        vpnBackend: vpnBackend,
        mihomoConfig: mihomoConfig,
        excludePackages: excludePkgs,
        includePackages: includePkgs,
        excludeProcesses: routingMode == AppRoutingMode.allExceptSelected
            ? processNames
            : const [],
        includeProcesses: routingMode == AppRoutingMode.onlySelected
            ? processNames
            : const [],
        routingMode: routingMode,
        managedProcessPaths: processPaths,
        serverName: server.displayName,
        modeOverride: connectionMode,
      );
      if (cancelled()) return;
      await engine.startSession(
        session,
        allowPermissionPrompt: !automaticRecovery && !autostartTunFallback,
      );
      _awaitingSessionStart = false;

      if (cancelled()) {
        // Отмена пришла, пока сессия поднималась — гасим её и выходим тихо.
        try {
          await engine.stopVpn();
        } catch (_) {
          if (engine.usesMacOSNetworkService) rethrow;
        }
        state = const AsyncData(VpnState(status: VpnStatus.disconnected));
        return;
      }

      var sessionState = await engine.getCurrentState();
      if (sessionState.status == VpnStatus.connecting) {
        sessionState = await _awaitNativeConnectOutcome(engine);
      }
      if (cancelled()) {
        state = AsyncData(
          engine.usesMacOSNetworkService
              ? await engine.getCurrentState()
              : VpnState.disconnected,
        );
        return;
      }
      if (sessionState.status == VpnStatus.connected) {
        _recovery?.connected();
        state = AsyncData(sessionState);
      } else if (sessionState.status == VpnStatus.error) {
        // явно: при смене сервера ошибки из стрима отбрасываются, и без поллинга на десктопе UI застревал в подключении
        state = AsyncData(sessionState);
      } else if (engine.usesMacOSNetworkService) {
        state = AsyncData(sessionState);
        throw const VpnStartException(
          'The macOS service did not confirm an active connection.',
        );
      } else {
        state = AsyncData(
          VpnState(
            status: VpnStatus.connected,
            activeMode: sessionState.activeMode,
          ),
        );
      }
    } catch (e, st) {
      if (operation != _connectGeneration || !ref.mounted) return;
      if (_cancelRequested &&
          !(ref.read(vpnEngineProvider).usesMacOSNetworkService &&
              MacOSTunnelBackend.activeInstance?.currentState.status !=
                  VpnStatus.disconnected)) {
        // Ошибка спровоцирована самой отменой (ядро убито стопом) —
        // это не сбой подключения, показываем спокойный «отключён».
        state = const AsyncData(VpnState(status: VpnStatus.disconnected));
        return;
      }
      AppLogger.instance.error(
        'VPN connect failed in VpnStateNotifier.connect()',
        error: e,
        stackTrace: st,
      );
      state = AsyncData(
        VpnState(status: VpnStatus.error, errorMessage: e.toString()),
      );
      if (_recovery?.wanted == true) {
        final backend = ref.read(vpnEngineProvider).macOSBackend;
        _recovery!.failed(
          macOSFailureCode(e),
          text: e.toString(),
          occurrence: backend?.lastSnapshot['errorCode'] == macOSFailureCode(e)
              ? backend?.failureOccurrence
              : null,
        );
        if (_recovery!.waiting || automaticRecovery) return;
      }
      Error.throwWithStackTrace(e, st);
    } finally {
      _connectInFlight = false;
      if (!finished.isCompleted) finished.complete();
      if (identical(_connectFinished, finished)) _connectFinished = null;
      _awaitingSessionStart = false;
      if (ref.mounted &&
          operation == _connectGeneration &&
          _recovery?.wanted == true &&
          _recovery?.phase == MacOSRecoveryPhase.retrying) {
        final backend = ref.read(vpnEngineProvider).macOSBackend;
        if (backend?.currentState.status == VpnStatus.connected) {
          _recovery!.connected();
        } else {
          _recovery!.failed(
            backend?.lastSnapshot['errorCode'] as String? ?? 'startFailed',
            text: state.value?.errorMessage,
            occurrence: backend?.failureOccurrence,
          );
        }
      }
      // Ветки connect() присваивают state напрямую, мимо _applyNativeState —
      // порт сессии на диск кладём здесь, каким бы ни был исход.
      _persistActiveLocalHttpPort(
        state.value?.status ?? VpnStatus.disconnected,
      );
      if (_recovery?.waiting == true) _showRecovery();
    }
  }

  Future<void> cancelConnect() async {
    _recovery?.cancel();
    ++_connectGeneration;
    if (!_connectInFlight) {
      await disconnect();
      return;
    }
    _cancelRequested = true;
    _awaitingSessionStart = false;
    state = const AsyncData(VpnState(status: VpnStatus.disconnecting));
    try {
      await ref.read(vpnEngineProvider).stopVpn();
    } catch (e, st) {
      AppLogger.instance.warn(
        'cancelConnect: stopVpn failed',
        error: e,
        stackTrace: st,
      );
      if (Platform.isMacOS) {
        state = AsyncData(
          VpnState(status: VpnStatus.error, errorMessage: e.toString()),
        );
        Error.throwWithStackTrace(e, st);
      }
    }
  }

  Future<void> disconnect() async {
    _cancelRequested = true;
    _awaitingSessionStart = false;
    ++_connectGeneration;
    _recovery?.cancel();
    state = const AsyncData(VpnState(status: VpnStatus.disconnecting));
    ActiveLocalPorts().clear();
    _persistActiveLocalHttpPort(VpnStatus.disconnecting);
    try {
      await ref.read(vpnEngineProvider).stopVpn();
    } catch (e, st) {
      AppLogger.instance.error(
        'VPN disconnect failed in VpnStateNotifier.disconnect()',
        error: e,
        stackTrace: st,
      );
      state = AsyncData(
        VpnState(status: VpnStatus.error, errorMessage: e.toString()),
      );
      Error.throwWithStackTrace(e, st);
    }
  }

  Future<_AutoTarget?> _autoSelectTarget() async {
    if (!ref.mounted ||
        _connectInFlight ||
        _serverSwitchInProgress ||
        _recovery?.waiting == true ||
        state.value?.status != VpnStatus.connected) {
      return null;
    }
    final generation = _connectGeneration;
    final revision = _autoSelectRevision;
    final identity = _autoSelectSessionIdentity;
    final server = ref.read(serversProvider).activeServer;
    final subId = server?.subscriptionId;
    if (server == null || subId == null) return null;
    final subs =
        ref.read(subscriptionsProvider).value ?? const <Subscription>[];
    final own = subs.where((s) => s.id == subId).firstOrNull;
    if (own != null && own.autoSelect) {
      return (server: server, subId: subId, ownerId: subId);
    }
    final owner = subs.where((s) => s.autoSelect).firstOrNull;
    if (owner == null) return null;
    // в соседней подписке ведём только сервер, куда увёз сам автовыбор: выбранный из трея или горячей клавишей не наш
    final home = await AutoSelectHomeStore.load();
    if (!ref.mounted ||
        generation != _connectGeneration ||
        revision != _autoSelectRevision ||
        identity != _autoSelectSessionIdentity ||
        state.value?.status != VpnStatus.connected ||
        ref.read(serversProvider).activeServer?.id != server.id) {
      return null;
    }
    if (home == null ||
        home.subscriptionId != owner.id ||
        home.pickedId != server.id ||
        !_autoSelectFamily(owner.id).contains(subId)) {
      return null;
    }
    return (server: server, subId: subId, ownerId: owner.id);
  }

  String? get _autoSelectSessionIdentity =>
      ref.read(vpnEngineProvider).macOSBackend?.activeSessionIdentity;

  _AutoToken _autoSelectToken(_AutoTarget target) => (
    generation: _connectGeneration,
    revision: _autoSelectRevision,
    session: _autoSelectSessionIdentity,
    target: target,
  );

  bool _autoSelectCurrent(_AutoToken token, {ServerItem? selected}) {
    if (!ref.mounted ||
        token.generation != _connectGeneration ||
        token.revision != _autoSelectRevision ||
        token.session != _autoSelectSessionIdentity ||
        _connectInFlight ||
        _serverSwitchInProgress ||
        _recovery?.waiting == true ||
        state.value?.status != VpnStatus.connected) {
      return false;
    }
    final server = ref.read(serversProvider).activeServer;
    final expected = selected ?? token.target.server;
    return server?.id == expected.id &&
        server?.subscriptionId == expected.subscriptionId &&
        (ref.read(subscriptionsProvider).value ?? const <Subscription>[]).any(
          (sub) => sub.id == token.target.ownerId && sub.autoSelect,
        );
  }

  @visibleForTesting
  Future<List<PingResult>> probeAutoSelectCandidates(
    List<ServerItem> servers,
    AppSettings settings, {
    required String testUrl,
    required void Function(PingResult) onResult,
  }) => PingService.pingUrlBatch(
    servers,
    settings,
    testUrl: testUrl,
    timeoutSeconds: AutoSelectWatchdog.judgeTimeoutSeconds,
    onResult: onResult,
  );

  List<String> _autoSelectFamily(String ownerId) {
    final subs =
        ref.read(subscriptionsProvider).value ?? const <Subscription>[];
    return [
      ownerId,
      ...AutoServerSelect.neighbourSubscriptions(
        [for (final s in subs) s.id],
        ownerId: ownerId,
        withServers: {
          for (final s in ref.read(serversProvider).servers) ?s.subscriptionId,
        },
      ),
    ];
  }

  int _autoSelectLimit(_AutoTarget target) =>
      _autoSelectOutage.suspects(target.subId)
      ? AutoSelectWatchdog.suspectLimit
      : AutoSelectWatchdog.candidateLimit;

  int _autoSelectScore(String id, int latencyMs) =>
      AutoServerSelect.switchScore(
        ref.read(serversProvider).servers.where((s) => s.id == id).firstOrNull,
        latencyMs,
        DateTime.now(),
      );

  // Android знает, есть ли под туннелем сеть вообще: без неё замер только жжёт батарею
  Future<bool> _autoSelectOffline(_AutoToken token) async {
    final net = await VpnNativeBridge.physicalNetworks();
    if (!_autoSelectCurrent(token)) return true;
    if (net == null || net.count > 0) return false;
    AppLogger.instance.info(
      'Auto select: no network under the tunnel, not measuring',
    );
    _autoSelectRest(net.changes);
    return true;
  }

  void _autoSelectRest(int? networkMark) {
    _autoSelectDeadRounds++;
    _autoSelectNetworkMark = networkMark;
    _autoSelectQuietUntil = DateTime.now().add(
      AutoSelectWatchdog.quietAfterRound(deadRounds: _autoSelectDeadRounds),
    );
  }

  // паузу мёртвой зоны кончает и новая сеть, а не только таймер
  Future<bool> _autoSelectQuiet(_AutoToken token) async {
    final until = _autoSelectQuietUntil;
    if (until == null || !DateTime.now().isBefore(until)) return false;
    final mark = _autoSelectNetworkMark;
    if (_autoSelectDeadRounds == 0 || mark == null) return true;
    final net = await VpnNativeBridge.physicalNetworks();
    if (!_autoSelectCurrent(token)) return true;
    if (net == null || net.count == 0 || net.changes == mark) return true;
    AppLogger.instance.info(
      'Auto select: the network changed, checking right away',
    );
    _autoSelectQuietUntil = null;
    _autoSelectDeadRounds = 0;
    _autoSelectNetworkMark = null;
    return false;
  }

  Future<String> _autoSelectTestUrl() async {
    final settings = await ref.read(storageProvider).getSettings();
    final custom = settings.pingTestUrlCustom.trim();
    return settings.pingTestTarget == 'custom' && custom.isNotEmpty
        ? custom
        : kDefaultPingTestUrl;
  }

  _AutoSelectMeasure _autoSelectStartMeasure(
    ServerItem current,
    String subId, {
    required _AutoToken token,
    int limit = AutoSelectWatchdog.candidateLimit,
    Set<String> include = const {},
  }) => _autoSelectMeasure(
    current.id,
    token,
    AutoServerSelect.candidatesToMeasure(
      ref.read(serversProvider).servers,
      subscriptionId: subId,
      current: current,
      limit: limit,
      include: include,
    ),
  );

  Future<void> _autoSelectRecord(List<PingResult> results) =>
      ref.read(serversProvider.notifier).updatePingResults({
        for (final r in results)
          r.serverId: (
            pingMs: r.success ? r.latencyMs : null,
            lastPingType: PingService.pingTypeToStored(r.pingType),
          ),
      });

  _AutoSelectMeasure _autoSelectMeasure(
    String currentId,
    _AutoToken token,
    List<ServerItem> servers,
  ) {
    final measure = _AutoSelectMeasure(currentId, token);
    ({String id, bool success, int? latencyMs}) entry(PingResult r) =>
        (id: r.serverId, success: r.success, latencyMs: r.latencyMs);
    measure.done = () async {
      try {
        final settings = await ref.read(storageProvider).getSettings();
        final testUrl = await _autoSelectTestUrl();
        if (!_autoSelectCurrent(token)) return;
        final results = await probeAutoSelectCandidates(
          servers,
          settings,
          testUrl: testUrl,
          onResult: (r) {
            if (!_autoSelectCurrent(token)) return;
            measure.pings = [
              ...measure.pings.where((p) => p.serverId != r.serverId),
              r,
            ];
            measure.add(entry(r));
          },
        );
        if (!_autoSelectCurrent(token)) return;
        for (final r in results) {
          measure.results.putIfAbsent(r.serverId, () => entry(r));
          if (!measure.pings.any((p) => p.serverId == r.serverId)) {
            measure.pings = [...measure.pings, r];
          }
        }
        if (AutoServerSelect.worthRecording(measure.results.values)) {
          unawaited(_autoSelectRecord(measure.pings));
        }
      } catch (e, st) {
        AppLogger.instance.debug(
          'Auto select measure failed',
          error: e,
          stackTrace: st,
        );
      } finally {
        measure.finish();
      }
    }();
    return measure;
  }

  // замер только после вызова судьи: трафик замера считается ответом сервера и сбивает счёт тишины
  Future<void> _autoSelectListenOnce() async {
    if (_autoSelectBusy || _autoSelectListening || !ref.mounted) return;
    _autoSelectListening = true;
    try {
      await _autoSelectListen();
    } finally {
      _autoSelectListening = false;
    }
  }

  Future<void> _autoSelectListen() async {
    if (_autoSelectBusy || !ref.mounted) return;
    final target = await _autoSelectTarget();
    if (!ref.mounted) return;
    if (target == null) {
      _autoSelectSeenFailures = null;
      _autoSelectSilence = const SilenceStreak();
      _autoSelectCounters = null;
      _autoSelectOutage = const SubscriptionOutage();
      _autoSelectDeadRounds = 0;
      return;
    }
    final token = _autoSelectToken(target);
    final sessionIdentity = _autoSelectSessionIdentity;
    if (_autoSelectSampleSession != sessionIdentity) {
      _autoSelectSampleSession = sessionIdentity;
      _autoSelectCounters = null;
      _autoSelectSeenFailures = null;
      _autoSelectSilence = const SilenceStreak();
    }
    final quietUntil = _autoSelectQuietUntil;
    final deadZone = _autoSelectDeadRounds > 0;
    if (!deadZone &&
        quietUntil != null &&
        DateTime.now().isBefore(quietUntil)) {
      return;
    }

    final second = await _autoSelectSecond(token);
    if (!_autoSelectCurrent(token) || _autoSelectBusy) return;
    // трафик пошёл сам: из мёртвой зоны вышли, и следующую тишину проверяем сразу, а не через две минуты
    if (deadZone && (second?.received ?? 0) > 0) {
      _autoSelectDeadRounds = 0;
      _autoSelectNetworkMark = null;
      _autoSelectQuietUntil = null;
    }
    if (await _autoSelectQuiet(token) || !_autoSelectCurrent(token)) return;
    if (second != null) {
      _autoSelectSilence = _autoSelectSilence.next(
        sent: second.sent,
        received: second.received,
      );
    }

    final failures = Platform.isAndroid
        ? await VpnNativeBridge.dialFailures()
        : CoreDialFailures.count;
    if (!_autoSelectCurrent(token) || _autoSelectBusy) return;
    var newFailures = 0;
    if (failures != null) {
      final previous = _autoSelectSeenFailures;
      _autoSelectSeenFailures = failures;
      // первое чтение только точка отсчёта: счётчик копится с запуска процесса
      if (previous != null) newFailures = failures - previous;
    }

    final stalled = AutoSelectWatchdog.trafficStalled(
      _autoSelectSilence.silent,
      desktop: !Platform.isAndroid,
    );
    if (!stalled &&
        !AutoSelectWatchdog.dialFailuresSuggestDeadServer(newFailures)) {
      return;
    }
    if (await _autoSelectOffline(token) || !_autoSelectCurrent(token)) return;
    await _autoSelectDecide(
      target,
      _autoSelectStartMeasure(
        target.server,
        target.subId,
        token: token,
        limit: _autoSelectLimit(target),
      ),
      reason: stalled
          ? 'nothing came back for ${_autoSelectSilence.silent} s'
          : '$newFailures failed dial(s) in the core log',
    );
  }

  Future<({int sent, int received})?> _autoSelectSecond(
    _AutoToken token,
  ) async {
    final engine = ref.read(vpnEngineProvider);
    if (Platform.isAndroid) {
      final now = await engine.getCurrentState();
      if (!_autoSelectCurrent(token)) return null;
      return (sent: now.uploadSpeed ?? 0, received: now.downloadSpeed ?? 0);
    }
    final counters = await engine.sessionTrafficCounters();
    if (!_autoSelectCurrent(token)) return null;
    final previous = _autoSelectCounters;
    _autoSelectCounters = counters;
    if (counters == null || previous == null) return null;
    if (counters.up < previous.up || counters.down < previous.down) return null;
    return (
      sent: counters.up - previous.up,
      received: counters.down - previous.down,
    );
  }

  Future<void> _autoSelectTick() async {
    if (_autoSelectBusy || _autoSelectListening || !ref.mounted) return;
    final target = await _autoSelectTarget();
    if (target == null) return;
    final token = _autoSelectToken(target);
    final received = state.value?.totalDownload ?? 0;
    final sent = state.value?.totalUpload ?? 0;
    // меньше прошлого значит новая сессия, раньше такой сброс будил судью зря
    final newSession =
        received < _autoSelectSeenReceived || sent < _autoSelectSeenSent;
    final moved = newSession || received > _autoSelectSeenReceived;
    final wentOut = !newSession && sent > _autoSelectSeenSent;
    _autoSelectSeenReceived = received;
    _autoSelectSeenSent = sent;
    if (await _autoSelectQuiet(token) || !_autoSelectCurrent(token)) return;
    if (!AutoSelectWatchdog.shouldProbe(
      connected: true,
      autoSelectOn: true,
      trafficMoved: moved,
      trafficSent: wentOut,
    )) {
      return;
    }
    if (await _autoSelectOffline(token) || !_autoSelectCurrent(token)) return;
    await _autoSelectDecide(
      target,
      _autoSelectStartMeasure(
        target.server,
        target.subId,
        token: token,
        limit: _autoSelectLimit(target),
      ),
      reason:
          'nothing received for ${AutoSelectWatchdog.probeEvery.inSeconds} s',
    );
  }

  Future<void> _autoSelectDecide(
    _AutoTarget target,
    _AutoSelectMeasure measure, {
    required String reason,
  }) async {
    final token = measure.token;
    bool isCurrent() => _autoSelectCurrent(token);
    if (_autoSelectBusy || !isCurrent()) return;
    _autoSelectBusy = true;
    final server = target.server;
    var switched = false;
    var dead = false;
    AppLogger.instance.info(
      'Auto select: checking ${server.displayName} — $reason',
    );
    try {
      var verdict = AutoServerSelect.judge(
        currentId: server.id,
        results: measure.results.values,
        batchComplete: measure.complete,
        score: _autoSelectScore,
      );
      while (!verdict.decided) {
        await measure.changed;
        if (!isCurrent()) return;
        verdict = AutoServerSelect.judge(
          currentId: server.id,
          results: measure.results.values,
          batchComplete: measure.complete,
          score: _autoSelectScore,
        );
      }
      if (!isCurrent()) return;
      var nextId = verdict.nextId;
      if (nextId == null) {
        if (measure.results[server.id]?.success == true) {
          _autoSelectOutage = const SubscriptionOutage();
          AppLogger.instance.info(
            'Auto select: ${server.displayName} answered, staying',
          );
          return;
        }
        final across = await _autoSelectAcross(target, measure);
        if (!isCurrent()) return;
        dead = !across.answered;
        nextId = across.nextId;
        if (nextId == null) return;
      } else {
        _autoSelectOutage = const SubscriptionOutage();
      }
      if (state.value?.status != VpnStatus.connected) return;
      if (ref.read(serversProvider).activeServer?.id != server.id) return;

      final now = DateTime.now();
      _autoSelectSwitches.removeWhere(
        (t) => now.difference(t) >= AutoSelectWatchdog.switchWindow,
      );
      if (!AutoSelectWatchdog.switchAllowed(_autoSelectSwitches, now)) {
        AppLogger.instance.warn(
          'Auto select: ${AutoSelectWatchdog.maxSwitchesPerWindow} switches '
          'in ${AutoSelectWatchdog.switchWindow.inMinutes} min already, '
          'leaving ${server.displayName} alone for now',
        );
        return;
      }
      final next = ref
          .read(serversProvider)
          .servers
          .where((s) => s.id == nextId)
          .firstOrNull;
      if (next == null) return;
      AppLogger.instance.info(
        'Auto select: ${server.displayName} did not answer, '
        '${next.displayName} did — switching',
      );
      if (!isCurrent()) return;
      await _autoSelectRecord(measure.pings);
      if (!isCurrent()) return;
      final previous = await AutoSelectHomeStore.load();
      if (!isCurrent()) return;
      await AutoSelectHomeStore.save(
        target.subId == target.ownerId
            ? AutoSelectHome.afterFailover(
                previous,
                subscriptionId: target.ownerId,
                fromId: server.id,
                toId: next.id,
              )
            : AutoSelectHome.afterNeighbourFailover(
                previous,
                subscriptionId: target.ownerId,
                fromId: server.id,
                toId: next.id,
              ),
      );
      if (!isCurrent()) return;
      await ref.read(serversProvider.notifier).setActive(next);
      if (!_autoSelectCurrent(token, selected: next)) return;
      switched = true;
      _autoSelectSwitches.add(now);
      _autoSelectSeenFailures = null;
      _autoSelectSilence = const SilenceStreak();
      _autoSelectCounters = null;
      _autoSelectOutage = const SubscriptionOutage();
      _autoSelectDeadRounds = 0;
      _autoSelectQuietUntil = now.add(AutoSelectWatchdog.quietAfterSwitch);
      await reconnectToActiveServer(expectedGeneration: token.generation);
    } catch (e, st) {
      AppLogger.instance.debug(
        'Auto select decision failed',
        error: e,
        stackTrace: st,
      );
    } finally {
      if (!switched && isCurrent()) {
        // после переезда считаем заново: само переподключение даёт отказы и тихие секунды
        _autoSelectSeenFailures = null;
        _autoSelectSilence = const SilenceStreak();
        _autoSelectCounters = null;
        if (switched) _autoSelectOutage = const SubscriptionOutage();
        if (dead) {
          final net = await VpnNativeBridge.physicalNetworks();
          if (isCurrent()) _autoSelectRest(net?.changes);
        } else {
          _autoSelectDeadRounds = 0;
          // подписка под подозрением, а сеть жива: второй раунд нужен скоро, человек сидит без связи
          final soon = switched || _autoSelectOutage.suspects(target.subId);
          _autoSelectQuietUntil = DateTime.now().add(
            soon
                ? AutoSelectWatchdog.quietAfterSwitch
                : AutoSelectWatchdog.quietAfterCheck,
          );
        }
      }
      _autoSelectBusy = false;
    }
  }

  // вся своя подписка молчит: соседние по экрану служат контролем. молчат и они, значит сеть, а не серверы
  Future<({String? nextId, bool answered})> _autoSelectAcross(
    _AutoTarget target,
    _AutoSelectMeasure own,
  ) async {
    final server = target.server;
    if (!own.results.containsKey(server.id)) {
      return (nextId: null, answered: true);
    }
    final controls = AutoServerSelect.controls(
      ref.read(serversProvider).servers,
      subscriptionIds: [
        for (final id in _autoSelectFamily(target.ownerId))
          if (id != target.subId) id,
      ],
      perSubscription: AutoSelectWatchdog.controlsPerSubscription,
      skip: own.results.keys.toSet(),
    );
    if (controls.isEmpty) {
      AppLogger.instance.info(
        'Auto select: nobody answered, staying on ${server.displayName}',
      );
      return (nextId: null, answered: false);
    }
    AppLogger.instance.info(
      'Auto select: nobody in the subscription answered, '
      'asking ${controls.length} servers of the neighbouring ones',
    );
    final control = _autoSelectMeasure(server.id, own.token, controls);
    await control.done;
    if (!_autoSelectCurrent(own.token)) return (nextId: null, answered: false);
    final answered = AutoServerSelect.worthRecording(control.results.values);
    _autoSelectOutage = _autoSelectOutage.afterRound(
      subscriptionId: target.subId,
      ownAnswered: false,
      othersAnswered: answered,
      now: DateTime.now(),
    );
    if (!answered) {
      AppLogger.instance.info(
        'Auto select: the neighbours are silent too, it is the network; '
        'staying on ${server.displayName}',
      );
      return (nextId: null, answered: false);
    }
    // сеть жива, значит отказы своей подписки настоящие
    unawaited(_autoSelectRecord(own.pings));
    if (!_autoSelectOutage.shouldJump) {
      AppLogger.instance.info(
        'Auto select: the subscription is silent while a neighbour answers '
        '(${_autoSelectOutage.rounds} of ${SubscriptionOutage.roundsBeforeJump}), '
        'staying on ${server.displayName} for now',
      );
      return (nextId: null, answered: true);
    }
    final verdict = AutoServerSelect.judge(
      currentId: server.id,
      results: [
        (id: server.id, success: false, latencyMs: null),
        ...control.results.values,
      ],
      batchComplete: true,
      score: _autoSelectScore,
    );
    AppLogger.instance.info(
      'Auto select: the subscription stayed silent '
      '${_autoSelectOutage.rounds} rounds while a neighbour answered, moving there',
    );
    return (nextId: verdict.nextId, answered: true);
  }

  // один таймер на обе: два одновременных накладывали бы замеры каждые 5 минут
  Future<void> _autoSelectRecheckTick() {
    final now = DateTime.now();
    final last = _autoSelectRecheckAt ??= now;
    final scheduled =
        now.difference(last) >=
        AutoSelectWatchdog.recheckEvery - NeighbourHomePace.every ~/ 2;
    if (scheduled) _autoSelectRecheckAt = now;
    return _autoSelectRecheck(homeOnly: !scheduled);
  }

  Future<void> _autoSelectRecheck({bool homeOnly = false}) async {
    if (_autoSelectBusy || _autoSelectListening || !ref.mounted) return;
    final target = await _autoSelectTarget();
    if (!ref.mounted) return;
    final token = target == null ? null : _autoSelectToken(target);
    var home = await AutoSelectHomeStore.load();
    if (!ref.mounted || token != null && !_autoSelectCurrent(token)) return;
    if (target == null) {
      final subs =
          ref.read(subscriptionsProvider).value ?? const <Subscription>[];
      if (home != null &&
          !subs.any((s) => s.id == home!.subscriptionId && s.autoSelect)) {
        await AutoSelectHomeStore.save(null);
      }
      _autoSelectRecheckSeenBytes = null;
      _autoSelectHomePace = const NeighbourHomePace();
      return;
    }
    if (home != null) {
      final waiting = home.stillWaiting(
        activeId: target.server.id,
        autoSubscriptionId: target.ownerId,
        homeExists: ref
            .read(serversProvider)
            .servers
            .any((s) => s.id == home!.homeId),
      );
      if (waiting == null) await AutoSelectHomeStore.save(null);
      home = waiting;
    }
    if (token == null || !_autoSelectCurrent(token)) return;
    final away = home != null && target.subId != target.ownerId;
    if (!away) _autoSelectHomePace = const NeighbourHomePace();
    if (homeOnly && (!away || !_autoSelectHomePace.due(DateTime.now()))) return;

    final bytes = await _autoSelectTotalBytes();
    if (!_autoSelectCurrent(token) || _autoSelectBusy) return;
    final seen = _autoSelectRecheckSeenBytes;
    _autoSelectRecheckSeenBytes = bytes;
    if (bytes != null && (seen == null || bytes <= seen)) return;

    final quietUntil = _autoSelectQuietUntil;
    if (quietUntil != null && DateTime.now().isBefore(quietUntil)) return;

    final homeId = home?.homeId;
    final measure = _autoSelectStartMeasure(
      target.server,
      target.subId,
      token: token,
      limit: homeOnly
          ? NeighbourHomePace.measureLimit
          : AutoSelectWatchdog.recheckLimit,
      include: {?homeId},
    );
    await _autoSelectDecide(
      target,
      measure,
      reason: homeOnly ? 'checking the own subscription' : 'scheduled check',
    );
    if (home == null || !_autoSelectCurrent(token)) return;

    _autoSelectBusy = true;
    try {
      await measure.done;
      if (!_autoSelectCurrent(token)) return;
      if (state.value?.status != VpnStatus.connected) return;
      if (ref.read(serversProvider).activeServer?.id != target.server.id) {
        return;
      }
      final homeAnswered = measure.results[home.homeId]?.success == true;
      if (homeOnly) {
        _autoSelectHomePace = _autoSelectHomePace.afterCheck(
          homeAnswered: homeAnswered,
          now: DateTime.now(),
        );
        if (_autoSelectHomePace.pausedUntil != null) {
          AppLogger.instance.info(
            'Auto select: the own subscription did not answer '
            '${NeighbourHomePace.missesBeforePause} checks in a row, '
            'next tries in ${NeighbourHomePace.pause.inMinutes} min',
          );
        }
      }
      home = home.afterCheck(homeAnswered: homeAnswered);
      if (!home.shouldReturn) {
        await AutoSelectHomeStore.save(home);
        return;
      }
    } finally {
      _autoSelectBusy = false;
    }
    if (_autoSelectCurrent(token)) await _autoSelectReturnHome(token, home);
  }

  Future<void> _autoSelectReturnHome(
    _AutoToken token,
    AutoSelectHome home,
  ) async {
    bool isCurrent() => _autoSelectCurrent(token);
    if (!isCurrent()) return;
    final from = token.target.server;
    final back = ref
        .read(serversProvider)
        .servers
        .where((s) => s.id == home.homeId)
        .firstOrNull;
    if (back == null) {
      await AutoSelectHomeStore.save(null);
      return;
    }
    final now = DateTime.now();
    _autoSelectSwitches.removeWhere(
      (t) => now.difference(t) >= AutoSelectWatchdog.switchWindow,
    );
    if (!AutoSelectWatchdog.switchAllowed(_autoSelectSwitches, now)) {
      await AutoSelectHomeStore.save(home);
      return;
    }
    AppLogger.instance.info(
      'Auto select: ${back.displayName} answered ${home.aliveStreak} checks '
      'in a row — returning from ${from.displayName}',
    );
    await AutoSelectHomeStore.save(null);
    if (!isCurrent()) return;
    _autoSelectBusy = true;
    var switched = false;
    try {
      await ref.read(serversProvider.notifier).setActive(back);
      if (!_autoSelectCurrent(token, selected: back)) return;
      switched = true;
      _autoSelectSwitches.add(now);
      _autoSelectSeenFailures = null;
      _autoSelectSilence = const SilenceStreak();
      _autoSelectCounters = null;
      _autoSelectQuietUntil = DateTime.now().add(
        AutoSelectWatchdog.quietAfterSwitch,
      );
      await reconnectToActiveServer(expectedGeneration: token.generation);
    } catch (e, st) {
      AppLogger.instance.debug(
        'Auto select return failed',
        error: e,
        stackTrace: st,
      );
    } finally {
      if (!switched && isCurrent()) {
        _autoSelectSeenFailures = null;
        _autoSelectSilence = const SilenceStreak();
        _autoSelectCounters = null;
        _autoSelectQuietUntil = DateTime.now().add(
          AutoSelectWatchdog.quietAfterSwitch,
        );
      }
      _autoSelectBusy = false;
    }
  }

  Future<int?> _autoSelectTotalBytes() async {
    final engine = ref.read(vpnEngineProvider);
    try {
      if (Platform.isAndroid) {
        final now = await engine.getCurrentState();
        final down = now.totalDownload;
        final up = now.totalUpload;
        if (down == null && up == null) return null;
        return (down ?? 0) + (up ?? 0);
      }
      final counters = await engine.sessionTrafficCounters();
      return counters == null ? null : counters.down + counters.up;
    } catch (_) {
      return null;
    }
  }
  Future<void> reconnectToActiveServer({
    int? expectedGeneration,
    Future<void> Function()? afterDisconnect,
  }) async {
    final ticket = expectedGeneration ?? _connectGeneration;
    if (!isConnectionChangeCurrent(ticket)) return;
    if (_serverSwitchInProgress) {
      await _serverSwitchFinished?.future;
      if (!isConnectionChangeCurrent(ticket)) return;
    }
    final generation = ++_connectGeneration;
    if (_recovery != null) {
      _cancelRequested = true;
      _recovery!.cancel();
    }

    final status = state.value?.status;
    final stop =
        _connectInFlight ||
        status == VpnStatus.connected ||
        status == VpnStatus.connecting;
    _serverSwitchInProgress = true;
    final finished = _serverSwitchFinished = Completer<void>();
    ref.read(vpnServerSwitchInProgressProvider.notifier).set(true);
    try {
      if (stop) {
        state = const AsyncData(VpnState(status: VpnStatus.disconnecting));
        await ref.read(vpnEngineProvider).stopVpn();
        await _waitForDisconnected();
      }
      await _connectFinished?.future;
      if (!isConnectionChangeCurrent(generation)) return;
      await afterDisconnect?.call();
      if (!isConnectionChangeCurrent(generation)) return;
      await connect();
    } finally {
      _serverSwitchInProgress = false;
      if (!finished.isCompleted) finished.complete();
      if (identical(_serverSwitchFinished, finished)) {
        _serverSwitchFinished = null;
      }
      if (ref.mounted) {
        ref.read(vpnServerSwitchInProgressProvider.notifier).set(false);
      }
    }
  }

  Future<void> _waitForDisconnected() async {
    final status = state.value?.status;
    if (status != null && status != VpnStatus.disconnected) {
      final waiter = _disconnectWaiter = Completer<void>();
      try {
        await waiter.future.timeout(const Duration(seconds: 4));
      } on TimeoutException {
        // не дождались disconnected, переподключаемся всё равно
      } finally {
        if (identical(_disconnectWaiter, waiter)) _disconnectWaiter = null;
      }
    }
    // ядру и туннелю нужно осесть перед новым connect
    await Future.delayed(const Duration(milliseconds: 350));
  }

  Future<void> toggle() async {
    final status = state.value?.status ?? VpnStatus.disconnected;
    if (status == VpnStatus.connected || status == VpnStatus.connecting) {
      await disconnect();
    } else {
      await connect();
    }
  }
}

final vpnStateProvider =
    AsyncNotifierProvider<VpnStateNotifier, VpnState>(VpnStateNotifier.new);

typedef _AutoTarget = ({ServerItem server, String subId, String ownerId});
typedef _AutoToken = ({int generation, int revision, String? session, _AutoTarget target});

class _AutoSelectMeasure {
  _AutoSelectMeasure(this.serverId, this.token);

  final _AutoToken token;

  final String serverId;

  final results = <String, ({String id, bool success, int? latencyMs})>{};
  List<PingResult> pings = const [];
  bool complete = false;
  Future<void> done = Future<void>.value();
  var _changed = Completer<void>();

  Future<void> get changed => complete ? Future<void>.value() : _changed.future;

  void add(({String id, bool success, int? latencyMs}) result) {
    results[result.id] = result;
    _signal();
  }

  void finish() {
    complete = true;
    _signal();
  }

  void _signal() {
    final fired = _changed;
    _changed = Completer<void>();
    fired.complete();
  }
}
