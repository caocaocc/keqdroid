import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/app_logger.dart';
import '../core/exceptions.dart';
import '../services/ephemeral_xray_ping.dart';
import '../utils/mihomo_api_session.dart';
import 'connection_mode.dart';
import 'desktop_traffic_stats.dart';
import 'macos_network_context.dart';
import 'macos_session_config.dart';
import 'socks_credential_generator.dart';
import 'tunnel_backend.dart';
import 'tunnel_session_request.dart';
import 'tunnel_state.dart';
import 'vpn_backend.dart';

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
  String _logs = '';
  Map<String, int> _pids = const {};
  VpnState _state = VpnState.disconnected;
  int? _apiPort;
  String _apiSecret = '';
  int? _wireproxyInfoPort;
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
    if (identical(activeInstance, this)) activeInstance = null;
    unawaited(_states.close());
  }

  @override
  void emit(VpnState state) {
    if (_disposed) return;
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
  Future<void> startSession(TunnelSessionRequest request) {
    _stopRequested = false;
    final generation = ++_operationGeneration;
    return _serial(() => _start(request, generation));
  }

  Future<void> _start(TunnelSessionRequest request, int generation) async {
    if (generation != _operationGeneration) return;
    init();
    if (_sessionId != null) await _stop();
    if (generation != _operationGeneration) return;
    _logs = '';
    emit(VpnState(status: VpnStatus.connecting, activeMode: request.mode));
    try {
      final service = await _call('getServiceStatus');
      if (generation != _operationGeneration) return;
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
          !await requestTunnelPermission()) {
        throw const VpnPermissionDeniedException(
          'TUN is not authorized for this macOS account.',
        );
      }
      if (generation != _operationGeneration) return;
      final context = request.mode == ConnectionMode.tun
          ? MacOSNetworkContext.fromMap(await _call('prepareNetworkContext'))
          : null;
      final ports = <int>{request.socksPort, request.httpPort};
      final apiPort = await _freePort(ports);
      ports.add(apiPort);
      final metricsPort = await _freePort(ports);
      final secret = SocksCredentialGenerator.randomToken(32);
      final sessionId = SocksCredentialGenerator.randomToken(32);
      final payload = MacOSSessionConfig.build(
        request: request,
        sessionId: sessionId,
        context: context,
        apiPort: apiPort,
        apiSecret: secret,
        wireproxyInfoPort: metricsPort,
      );
      if (generation != _operationGeneration) return;
      _context = context;
      _sessionId = sessionId;
      _apiPort =
          request.vpnBackend == VpnBackend.awg &&
              request.mode == ConnectionMode.proxy
          ? null
          : apiPort;
      _apiSecret = secret;
      _wireproxyInfoPort = request.vpnBackend == VpnBackend.awg
          ? metricsPort
          : null;
      _networkChangeSession = null;
      _networkChangePending = false;
      _pids = const {};
      totalUpload = 0;
      totalDownload = 0;
      _lastStats = null;
      sessionStartedAt = DateTime.now();
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
      try {
        await _stop();
      } catch (_) {}
      if (cancelled) return;
      emit(
        VpnState(
          status: VpnStatus.error,
          errorMessage: error.toString(),
          activeMode: request.mode,
        ),
      );
      if (error is AppException) rethrow;
      throw VpnStartException(error.toString(), cause: error);
    }
  }

  @override
  Future<void> stopSession() {
    ++_operationGeneration;
    _stopRequested = true;
    _networkChangePending = false;
    return _serial(_stop);
  }

  Future<void> _stop() async {
    final id = _sessionId;
    if (id != null) {
      emit(
        VpnState(
          status: VpnStatus.disconnecting,
          activeMode: _state.activeMode,
        ),
      );
      try {
        final snapshot = await _call('stopSession', {'sessionId': id});
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
    lastSessionLogs = exportSessionLogs(maxLines: 2000);
    _sessionId = null;
    _apiPort = null;
    _apiSecret = '';
    _wireproxyInfoPort = null;
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
      final snapshot = await _call('getSession');
      if (_disposed || generation != _operationGeneration) return;
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
    _wireproxyInfoPort =
        (snapshot['wireproxyInfoPort'] as num?)?.toInt() ?? _wireproxyInfoPort;
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
    if (mapped.status == VpnStatus.connected) {
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
    } else if (_wireproxyInfoPort != null) {
      final counters = await queryWireproxyMetrics(_wireproxyInfoPort!);
      down = counters?.rx;
      up = counters?.tx;
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
      ({String id, bool success, int? latencyMs, String error, int? httpStatus})
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
