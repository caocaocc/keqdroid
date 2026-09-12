import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/app_logger.dart';
import '../core/exceptions.dart';
import '../services/ephemeral_xray_ping.dart';
import '../utils/mihomo_api_session.dart';
import 'connection_mode.dart';
import 'desktop_traffic_stats.dart';
import 'desktop_dns_diagnostics.dart';
import '../platform/desktop_lan_state.dart';
import 'macos_network_context.dart';
import 'macos_session_config.dart';
import 'macos_service_observation.dart';
import 'socks_credential_generator.dart';
import 'tunnel_backend.dart';
import 'tunnel_session_request.dart';
import 'tunnel_state.dart';
import 'vpn_backend.dart';
import 'url_test_diagnostics.dart';

/// Helper владеет сетевыми настройками и процессами даже при падении UI.
/// Dart передаёт конфиги и отображает подтверждённое сервисом состояние.
class MacOSTunnelBackend extends TunnelBackend with DesktopTrafficStats {
  static const networkChannel = MethodChannel(
    'io.github.caocaocc.keqdroid/network',
  );
  static MacOSTunnelBackend? activeInstance;
  static const desktopChannel = MethodChannel('keqdis_vpn_channel');
  static String lastSessionLogs = '';

  final MethodChannel _channel;
  final MethodChannel _desktopChannel;
  final bool _enablePolling;
  final _states = StreamController<VpnState>.broadcast();
  final _observations = StreamController<MacOSServiceObservation>.broadcast();
  Map<String, dynamic> _serviceInfo = const {};
  Map<String, dynamic> _snapshot = const {'status': 'disconnected'};
  Future<void> _operations = Future.value();
  Timer? _pollTimer;
  bool _polling = false;
  bool _disposed = false;
  bool _stopRequested = false;
  int _operationGeneration = 0;
  MacOSNetworkContext? _context;
  bool _networkChangePending = false;
  String? _networkChangeSession;
  String? _sessionId;
  bool _startOutcomeUnknown = false;
  String? _pendingStartEpoch;
  String _logs = '';
  Map<String, int> _pids = const {};
  VpnState _state = VpnState.disconnected;
  int? _apiPort;
  String _apiSecret = '';
  DateTime? _lastStats;

  MacOSTunnelBackend({
    MethodChannel channel = networkChannel,
    MethodChannel desktop = desktopChannel,
    bool enablePolling = true,
  }) : _channel = channel,
       _desktopChannel = desktop,
       _enablePolling = enablePolling;

  VpnState get currentState => _state;
  int? get clashApiPort => _apiPort;
  String get clashApiSecret => _apiSecret;
  Map<String, int> get activeCorePids => Map.unmodifiable(_pids);
  @override
  ConnectionMode? get activeMode => _state.activeMode;
  @override
  Stream<VpnState> get stateStream => _states.stream;
  Stream<MacOSServiceObservation> get observations => _observations.stream;
  Map<String, dynamic> get lastSnapshot => Map.unmodifiable(_snapshot);
  String get failureOccurrence =>
      '${_serviceInfo['helperEpoch']}/${_snapshot['sessionId']}/${_snapshot['errorCode']}/${_snapshot['errorStage']}';
  Future<Map<String, dynamic>> fetchServiceStatus() async {
    final info = await _call('getServiceStatus');
    _serviceInfo = info;
    return info;
  }

  bool takeNetworkChangeRequest() {
    final pending = _networkChangePending && !_stopRequested;
    _networkChangePending = false;
    return pending;
  }

  static Future<Map<String, dynamic>> serviceStatus() async {
    final result = await networkChannel.invokeMapMethod<String, dynamic>(
      'getServiceStatus',
    );
    return result ?? const {'installed': false, 'authorized': false};
  }

  static bool canConnectWithoutPrompt(
    Map<String, dynamic> service,
    ConnectionMode mode,
  ) =>
      service['installed'] == true &&
      service['protocolVersion'] == 1 &&
      (mode == ConnectionMode.proxy
          ? service['proxyWithoutElevation'] == true
          : service['authorized'] == true);

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    final result = await _channel
        .invokeMapMethod<String, dynamic>(method, args)
        .timeout(
          Duration(
            seconds: method == 'startSession' || method == 'startProxySession'
                ? 90
                : 15,
          ),
        );
    if (result == null) {
      throw PlatformChannelException(
        'The macOS network service returned no result.',
        channel: _channel.name,
      );
    }
    return result;
  }

  @override
  void init() {
    if (_disposed) return;
    activeInstance = this;
    if (_enablePolling && _pollTimer == null) {
      _pollTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_poll()),
      );
      unawaited(_poll());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    stopStatsLoop();
    if (identical(activeInstance, this)) {
      activeInstance = null;
      desktopDnsDiagnostics.value = null;
    }
    unawaited(_states.close());
    unawaited(_observations.close());
  }

  @override
  void emit(VpnState state) {
    if (_disposed) return;
    if (state.status != VpnStatus.connected) desktopLanState.value = null;
    if (state.status != VpnStatus.connected &&
        desktopDnsDiagnostics.value?.sessionId == _sessionId) {
      desktopDnsDiagnostics.value = null;
    }
    final changed = !_state.telemetryEquals(state);
    _state = state;
    if (changed) _states.add(state);
  }

  String exportSessionLogs({int maxLines = 400}) {
    final lines = _logs.split('\n');
    return lines
        .skip(lines.length > maxLines ? lines.length - maxLines : 0)
        .join('\n');
  }

  @override
  Future<({String username, String password})> fetchSocksCredentials() async =>
      SocksCredentialGenerator.generatePair();

  Future<void> _serial(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  @override
  Future<void> startSession(
    TunnelSessionRequest request, {
    bool allowPermissionPrompt = true,
  }) {
    _stopRequested = false;
    final generation = ++_operationGeneration;
    return _serial(() => _start(request, generation, allowPermissionPrompt));
  }

  Future<void> _start(
    TunnelSessionRequest request,
    int generation,
    bool allowPermissionPrompt,
  ) async {
    if (generation != _operationGeneration) return;
    init();
    if (_startOutcomeUnknown) {
      if (await _reconcileUnknownStart(generation)) return;
      if (generation != _operationGeneration) return;
    }
    if (!allowPermissionPrompt &&
        (_sessionId != null || _serviceInfo['recoveryRequired'] == true)) {
      _serviceInfo = await _call('getServiceStatus');
      if (generation != _operationGeneration) return;
      if (_serviceInfo['recoveryRequired'] == true) {
        throw _recoveryFailure(_serviceInfo);
      }
    }
    if (_sessionId != null || _serviceInfo['recoveryRequired'] == true) {
      await _stop();
    }
    if (generation != _operationGeneration) return;
    _logs = '';
    emit(VpnState(status: VpnStatus.connecting, activeMode: request.mode));
    try {
      final service = await _call('getServiceStatus');
      _serviceInfo = service;
      if (generation != _operationGeneration) return;
      if (service['recoveryRequired'] == true) {
        throw _recoveryFailure(service);
      }
      if (service['installed'] != true) {
        throw const VpnPermissionDeniedException(
          'Install the macOS network service using the package inside the DMG.',
        );
      }
      if (service['protocolVersion'] != 1) {
        throw const VpnStartException(
          'The macOS network service needs to be updated with this application.',
        );
      }
      if (request.mode == ConnectionMode.proxy &&
          service['proxyWithoutElevation'] != true) {
        throw const VpnStartException(
          'The macOS network service needs to be updated for Proxy without administrator authorization.',
        );
      }
      if (request.mode == ConnectionMode.tun &&
          service['authorized'] != true &&
          (!allowPermissionPrompt || !await requestTunnelPermission())) {
        throw const VpnPermissionDeniedException(
          'TUN is not authorized for this macOS account.',
        );
      }
      if (generation != _operationGeneration) return;
      final context = request.mode == ConnectionMode.tun
          ? MacOSNetworkContext.fromMap(await _call('prepareNetworkContext'))
          : null;
      final ports = <int>{
        request.socksPort,
        request.httpPort,
        if (request.lan != null) ...[
          request.lan!.socksPort,
          request.lan!.httpPort,
        ],
      };
      final apiPort = await _freePort(ports);
      ports.add(apiPort);
      final secret = SocksCredentialGenerator.randomToken(32);
      final sessionId = SocksCredentialGenerator.randomToken(32);
      final payload = MacOSSessionConfig.build(
        request: request,
        sessionId: sessionId,
        context: context,
        apiPort: apiPort,
        apiSecret: secret,
      );
      if (generation != _operationGeneration) return;
      _context = context;
      _sessionId = sessionId;
      _apiPort = apiPort;
      _apiSecret = secret;
      _networkChangeSession = null;
      _networkChangePending = false;
      _pids = const {};
      totalUpload = 0;
      totalDownload = 0;
      _lastStats = null;
      sessionStartedAt = DateTime.now();
      _pendingStartEpoch = service['helperEpoch'] as String?;
      final snapshot = await _call(
        request.mode == ConnectionMode.proxy
            ? 'startProxySession'
            : 'startSession',
        payload,
      );
      if (generation != _operationGeneration) {
        await _stop();
        return;
      }
      _pendingStartEpoch = null;
      _acceptSnapshot(snapshot);
      if (_state.status != VpnStatus.connected) {
        throw VpnStartException(
          _state.errorMessage ??
              'The macOS service did not establish the connection.',
        );
      }
      if (_apiPort != null) {
        MihomoApiSession().restore(port: _apiPort, secret: _apiSecret);
      }
    } catch (error) {
      final cancelled = generation != _operationGeneration;
      Object failure = error;
      final unknownStart =
          macOSFailureCode(error) == 'requestOutcomeUnknown' &&
          _sessionId != null;
      if (unknownStart) {
        _startOutcomeUnknown = true;
        if (!cancelled) {
          try {
            if (await _reconcileUnknownStart(generation)) return;
          } catch (reconciliationError) {
            failure = reconciliationError;
          }
        }
      }
      if (!unknownStart &&
          !_isRecoveryFailure(failure) &&
          _serviceInfo['recoveryRequired'] != true) {
        try {
          await _stop();
        } catch (cleanupError) {
          // A failed cleanup is the actionable error and must not be hidden by
          // the original core/start failure or reset by an automatic retry.
          failure = cleanupError;
        }
      }
      if (cancelled || generation != _operationGeneration) return;
      emit(
        VpnState(
          status: VpnStatus.error,
          errorMessage: failure.toString(),
          activeMode: request.mode,
        ),
      );
      if (failure is AppException) throw failure;
      throw VpnStartException(failure.toString(), cause: failure);
    }
  }

  static bool _isRecoveryFailure(Object error) => const {
    'recoveryRequired',
    'recoveryFailed',
    'recoveryCorrupt',
    'unsafeInstallation',
  }.contains(macOSFailureCode(error));

  static PlatformException _recoveryFailure(Map<String, dynamic> service) =>
      PlatformException(
        code:
            service['recoveryErrorCode'] as String? ??
            service['errorCode'] as String? ??
            'recoveryRequired',
        message:
            service['recoveryError'] as String? ??
            'The previous network state has not been restored.',
      );

  /// An unanswered start is not proof of failure. These bounded, read-only RPCs
  /// resolve it without replaying the start or stopping a possibly healthy core.
  Future<bool> _reconcileUnknownStart(int generation) async {
    try {
      final id = _sessionId;
      final epoch = _pendingStartEpoch;
      final service = await _call('getServiceStatus');
      if (_disposed || generation != _operationGeneration) {
        throw _unknownStartFailure();
      }
      _serviceInfo = service;
      if (service['recoveryRequired'] == true) throw _recoveryFailure(service);
      final snapshot = await _call('getSession');
      if (_disposed || generation != _operationGeneration) {
        throw _unknownStartFailure();
      }
      if (snapshot['recoveryRequired'] == true) {
        throw _recoveryFailure(snapshot);
      }
      final sameSession =
          id != null &&
          snapshot['sessionId'] == id &&
          epoch != null &&
          service['helperEpoch'] == epoch &&
          snapshot['helperEpoch'] == epoch;
      if (service['busy'] != true &&
          sameSession &&
          snapshot['status'] == 'connected') {
        _acceptSnapshot(snapshot);
        _startOutcomeUnknown = false;
        _pendingStartEpoch = null;
        return true;
      }
      if (service['busy'] != true &&
          snapshot['status'] == 'disconnected' &&
          (snapshot['sessionId'] == null || snapshot['sessionId'] == id)) {
        _acceptSnapshot(snapshot);
        return false;
      }
      if (service['busy'] != true &&
          sameSession &&
          snapshot['status'] == 'error') {
        _acceptSnapshot(snapshot);
        _startOutcomeUnknown = false;
        _pendingStartEpoch = null;
        throw PlatformException(
          code: snapshot['errorCode'] as String? ?? 'startFailed',
          message: snapshot['error'] as String?,
        );
      }
      throw _unknownStartFailure();
    } catch (error) {
      if (_isRecoveryFailure(error) || !_startOutcomeUnknown) rethrow;
      throw _unknownStartFailure();
    }
  }

  static PlatformException _unknownStartFailure() => PlatformException(
    code: 'requestOutcomeUnknown',
    message:
        'The start result is not confirmed. Waiting for the network service before starting another session.',
  );

  @override
  Future<void> stopSession() {
    ++_operationGeneration;
    _stopRequested = true;
    _networkChangePending = false;
    return _serial(_stop);
  }

  Future<void> _stop() async {
    final id = _sessionId;
    if (id != null || _serviceInfo['recoveryRequired'] == true) {
      emit(
        VpnState(
          status: VpnStatus.disconnecting,
          activeMode: _state.activeMode,
        ),
      );
      try {
        final snapshot = await _call('stopSession', {'sessionId': ?id});
        _acceptSnapshot(snapshot);
        if (_state.status != VpnStatus.disconnected) {
          throw VpnStartException(
            _state.errorMessage ??
                'The macOS service has not restored the network.',
          );
        }
      } catch (error) {
        emit(
          VpnState(
            status: VpnStatus.error,
            errorMessage: error.toString(),
            activeMode: _state.activeMode,
          ),
        );
        rethrow;
      }
    }
    _clearSession();
    emit(VpnState.disconnected);
  }

  void _clearSession() {
    desktopLanState.value = null;
    lastSessionLogs = exportSessionLogs(maxLines: 2000);
    if (desktopDnsDiagnostics.value?.sessionId == _sessionId) {
      desktopDnsDiagnostics.value = null;
    }
    _sessionId = null;
    _startOutcomeUnknown = false;
    _pendingStartEpoch = null;
    _apiPort = null;
    _apiSecret = '';
    _pids = const {};
    _context = null;
    MacOSNetworkContext.active = null;
    sessionStartedAt = null;
    resetStatsHttp();
    MihomoApiSession().clear();
  }

  @override
  Future<bool> requestTunnelPermission() async {
    final result = await _call('authorize');
    return result['installed'] == true && result['authorized'] == true;
  }

  @override
  Future<VpnState> getCurrentState() async {
    await _poll();
    return _state;
  }

  Future<void> _poll() async {
    if (_polling ||
        _disposed ||
        _state.status == VpnStatus.connecting ||
        _state.status == VpnStatus.disconnecting) {
      return;
    }
    _polling = true;
    final generation = _operationGeneration;
    try {
      if (_startOutcomeUnknown) {
        await _reconcileUnknownStart(generation);
        if (_disposed || generation != _operationGeneration) return;
        if (_observations.hasListener) {
          _observations.add(MacOSServiceObservation(_serviceInfo, _snapshot));
        }
        return;
      }
      if (_observations.hasListener) {
        final previousEpoch = _serviceInfo['helperEpoch'];
        _serviceInfo = await _call('getServiceStatus');
        if (_disposed || generation != _operationGeneration) return;
        if (previousEpoch != null &&
            _serviceInfo['helperEpoch'] != null &&
            previousEpoch != _serviceInfo['helperEpoch']) {
          _clearSession();
        }
      }
      final snapshot = await _call('getSession');
      if (_disposed || generation != _operationGeneration) return;
      if (_observations.hasListener) {
        _observations.add(MacOSServiceObservation(_serviceInfo, snapshot));
      }
      // Preserve a startup error until a new user action or an actual session.
      if (_state.status == VpnStatus.error &&
          _sessionId == null &&
          snapshot['status'] == 'disconnected' &&
          snapshot['requiresReconnect'] != true) {
        return;
      }
      _acceptSnapshot(snapshot);
      if (_state.status == VpnStatus.connected && statsPollingEnabled) {
        await pollTrafficStats(_state.activeMode ?? ConnectionMode.proxy);
      }
    } catch (error) {
      if (!_disposed &&
          generation == _operationGeneration &&
          _observations.hasListener) {
        _observations.add(
          MacOSServiceObservation(_serviceInfo, {
            'status': 'error',
            'sessionId': _sessionId,
            'errorCode': macOSFailureCode(error),
            'error': error.toString(),
            'transportUnavailable': true,
          }),
        );
      }
      if (_sessionId != null &&
          !_disposed &&
          generation == _operationGeneration) {
        AppLogger.instance.warn('macOS network service unavailable: $error');
        emit(
          VpnState(
            status: VpnStatus.error,
            errorMessage: 'The macOS network service is unavailable: $error',
            activeMode: _state.activeMode,
          ),
        );
      }
    } finally {
      _polling = false;
    }
  }

  void _acceptSnapshot(Map<String, dynamic> snapshot) {
    final status = snapshot['status'] as String?;
    if (!const {
      'connected',
      'disconnected',
      'connecting',
      'disconnecting',
      'error',
    }.contains(status)) {
      throw const FormatException(
        'Invalid session state from the macOS network service.',
      );
    }
    final incomingId = snapshot['sessionId'] as String?;
    if (_sessionId != null && incomingId != null && incomingId != _sessionId) {
      return;
    }
    _snapshot = Map.of(snapshot);
    if (status == 'connected' && incomingId == null) {
      throw const FormatException(
        'The macOS service did not identify its active session.',
      );
    }
    _sessionId ??= incomingId;
    final log = snapshot['log'] as String?;
    if (log != null) {
      _logs = log.length > 256000 ? log.substring(log.length - 256000) : log;
    }
    _apiPort = (snapshot['apiPort'] as num?)?.toInt() ?? _apiPort;
    _apiSecret = snapshot['apiSecret'] as String? ?? _apiSecret;
    if (snapshot['pids'] is Map) {
      _pids = {
        for (final entry in (snapshot['pids'] as Map).entries)
          if (entry.value is num)
            entry.key.toString(): (entry.value as num).toInt(),
      };
    }
    if (snapshot['requiresReconnect'] == true &&
        !_stopRequested &&
        _networkChangeSession != (incomingId ?? _sessionId ?? 'network')) {
      _networkChangeSession = incomingId ?? _sessionId ?? 'network';
      _networkChangePending = true;
    }
    final mapped = VpnState.fromMap(snapshot);
    final mode = mapped.activeMode ?? _state.activeMode;
    if (mapped.status == VpnStatus.connected && mode == ConnectionMode.tun) {
      final raw = snapshot['dnsDiagnostics'];
      final diagnostic = DesktopDnsDiagnostics.fromSnapshot(raw, incomingId!);
      if (raw == null || diagnostic != null) {
        if (diagnostic != desktopDnsDiagnostics.value &&
            diagnostic?.status == 'warning') {
          AppLogger.instance.warn('TUN DNS: ${diagnostic!.message}');
        }
        desktopDnsDiagnostics.value = diagnostic;
      }
    } else if (desktopDnsDiagnostics.value?.sessionId == _sessionId) {
      desktopDnsDiagnostics.value = null;
    }
    if (mapped.status == VpnStatus.connected) {
      desktopLanState.value = DesktopLanState.fromSnapshot(snapshot['lan']);
      if (snapshot['networkContext'] is Map) {
        _context = MacOSNetworkContext.fromMap(
          snapshot['networkContext'] as Map,
        );
      }
      final mode = mapped.activeMode ?? _state.activeMode;
      if (mode == ConnectionMode.tun && _context == null) {
        throw const FormatException(
          'The active TUN session has no physical DNS context.',
        );
      }
      MacOSNetworkContext.active = mode == ConnectionMode.tun ? _context : null;
      sessionStartedAt ??= DateTime.now().subtract(
        mapped.duration ?? Duration.zero,
      );
      if (_apiPort != null && _apiSecret.isNotEmpty) {
        MihomoApiSession().restore(port: _apiPort, secret: _apiSecret);
      }
      emit(
        VpnState(
          status: mapped.status,
          activeMode: mapped.activeMode ?? _state.activeMode,
          totalUpload: mapped.totalUpload ?? totalUpload,
          totalDownload: mapped.totalDownload ?? totalDownload,
          duration:
              mapped.duration ?? DateTime.now().difference(sessionStartedAt!),
          errorMessage: mapped.errorMessage,
        ),
      );
    } else {
      if (mapped.status == VpnStatus.error &&
          snapshot['networkContext'] == null) {
        MacOSNetworkContext.active = null;
        _context = null;
      }
      if (mapped.status == VpnStatus.disconnected) _clearSession();
      emit(mapped);
    }
  }

  @override
  Future<void> pollTrafficStats(
    ConnectionMode mode, {
    bool force = false,
  }) async {
    if ((!statsPollingEnabled && !force) ||
        _state.status != VpnStatus.connected) {
      return;
    }
    final id = _sessionId;
    int? down;
    int? up;
    if (_apiPort != null) {
      final counters = await queryClashTraffic(_apiPort!, secret: _apiSecret);
      down = counters?.down;
      up = counters?.up;
    }
    if (id != _sessionId ||
        down == null ||
        up == null ||
        _state.status != VpnStatus.connected) {
      return;
    }
    final now = DateTime.now();
    final elapsed = _lastStats == null
        ? 0
        : now.difference(_lastStats!).inMilliseconds;
    final downloadSpeed = elapsed <= 0 || resumeBaselinePending
        ? 0
        : ((down - totalDownload).clamp(0, down) * 1000 ~/ elapsed);
    final uploadSpeed = elapsed <= 0 || resumeBaselinePending
        ? 0
        : ((up - totalUpload).clamp(0, up) * 1000 ~/ elapsed);
    totalDownload = down;
    totalUpload = up;
    _lastStats = now;
    resumeBaselinePending = false;
    emitConnectedTelemetry(
      mode,
      downloadSpeed: downloadSpeed,
      uploadSpeed: uploadSpeed,
    );
  }

  @override
  void setTrafficStatsPollingEnabled(bool enabled) {
    if (statsPollingEnabled == enabled) return;
    statsPollingEnabled = enabled;
    resumeBaselinePending = enabled;
    if (!enabled) resetStatsHttp();
  }

  static Future<int> _freePort(Set<int> occupied) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      if (!occupied.contains(port)) return port;
    }
    throw const VpnStartException('Could not allocate distinct local ports.');
  }

  @override
  Future<int?> getPing(String address, int port) async {
    final timer = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 5),
      );
      timer.stop();
      await socket.close();
      return timer.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getInstalledApps({
    bool includeSystem = false,
  }) async {
    final apps = await _desktopChannel.invokeListMethod<dynamic>(
      'getInstalledApps',
      {'includeSystem': includeSystem},
    );
    return (apps ?? const [])
        .whereType<Map>()
        .map((app) => Map<String, dynamic>.from(app))
        .toList();
  }

  @override
  Future<String?> getAppIcon(String path) =>
      _desktopChannel.invokeMethod<String>('getAppIcon', {'path': path});

  @override
  Future<
    List<
      ({
        String id,
        bool success,
        int? latencyMs,
        String error,
        int? httpStatus,
        UrlTestDiagnostics? diagnostics,
      })
    >
  >
  xrayUrlTestBatch({
    required List<(String id, String xrayConfig)> items,
    required int socksPort,
    VpnBackend core = VpnBackend.xray,
    String testUrl = 'https://connectivitycheck.gstatic.com/generate_204',
    int timeoutMs = 15000,
    bool keepAlive = true,
  }) async {
    final results = await EphemeralXrayPing.urlTestBatch(
      items: items
          .map((item) => (id: item.$1, xrayConfigJson: item.$2))
          .toList(),
      socksPort: socksPort,
      core: core,
      testUrl: testUrl,
      timeoutMs: timeoutMs,
      keepAlive: keepAlive,
    );
    return results
        .map(
          (result) => (
            id: result.id,
            success: result.success,
            latencyMs: result.latencyMs,
            error: result.error,
            httpStatus: result.httpStatus,
            diagnostics: result.diagnostics,
          ),
        )
        .toList();
  }

  @override
  Future<List<({String id, bool success, int? kbps, String error})>>
  xraySpeedTestBatch({
    required List<(String id, String xrayConfig)> items,
    required int socksPort,
    VpnBackend core = VpnBackend.xray,
    String downloadUrl = kDefaultSpeedTestUrl,
    int timeoutMs = 20000,
  }) => EphemeralXrayPing.speedTestBatch(
    items: items.map((item) => (id: item.$1, xrayConfigJson: item.$2)).toList(),
    socksPort: socksPort,
    core: core,
    downloadUrl: downloadUrl,
    timeoutMs: timeoutMs,
  );
}
