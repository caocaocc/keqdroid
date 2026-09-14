import '../tunnel/url_test_diagnostics.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../core/app_logger.dart';
import '../tunnel/desktop_core_paths.dart';
import '../tunnel/macos_network_context.dart';
import '../utils/keqrnel_config.dart';
import '../tunnel/vpn_backend.dart';
import 'windows_desktop_service.dart';
import 'desktop_http_probe.dart';

final _ansiEscape = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

@visibleForTesting
String stripAnsi(String value) => value.replaceAll(_ansiEscape, '');

// трубы обязаны вычитываться: ядро, наговорившее больше буфера, встаёт на записи навсегда
class _CoreLog {
  _CoreLog(Process process) {
    for (final stream in [process.stdout, process.stderr]) {
      stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_add, onError: (Object _) {}, cancelOnError: false);
    }
  }

  static const _keep = 6;
  final _lines = <String>[];

  void _add(String line) {
    final trimmed = stripAnsi(line).trim();
    if (trimmed.isEmpty) return;
    _lines.add(trimmed.length > 1024 ? trimmed.substring(0, 1024) : trimmed);
    if (_lines.length > _keep) _lines.removeAt(0);
  }

  String get tail => _lines.isEmpty ? '' : ': ${_lines.join(' | ')}';
}

class EphemeralXrayPing {
  EphemeralXrayPing._();

  // Desktop core resolution is platform-specific; the rest (config, socks probe)
  // is platform-neutral so url/speed ping work on Windows and Linux alike.
  static Future<String?> _resolveXray() => DesktopCorePaths.xrayExecutable();

  static Future<String?> _resolveMihomo() =>
      DesktopCorePaths.mihomoExecutable();

  static Future<String?> _resolveCore(VpnBackend core) =>
      core == VpnBackend.mihomo ? _resolveMihomo() : _resolveXray();

  // свой каталог: mihomo держит cache.db через bbolt с секундным таймаутом на захват
  static List<String> _coreArgs(
    VpnBackend core,
    String configPath,
    String sessionDirPath,
  ) => core == VpnBackend.mihomo
      ? ['-d', sessionDirPath, '-f', configPath]
      : ['run', '-c', configPath];

  static String _coreConfig(String configJson, int port, VpnBackend core) {
    if (core == VpnBackend.mihomo) return _mihomoConfig(configJson, port);
    final macos = Platform.isMacOS;
    final config = jsonDecode(macos ? KeqrnelConfig.wrapXray(configJson) : configJson)
        as Map<String, dynamic>;
    if (macos && MacOSNetworkContext.active != null) {
      (config['route'] as Map)['default_interface'] =
          MacOSNetworkContext.active!.interfaceName;
    }
    final inbounds = config['inbounds'];
    if (inbounds is List) {
      for (final inbound in inbounds) {
        if (inbound is Map<String, dynamic>) {
          inbound[macos ? 'listen_port' : 'port'] = port;
        }
      }
    }
    return jsonEncode(config);
  }

  static String _mihomoConfig(String configJson, int port) {
    final config = jsonDecode(configJson) as Map<String, dynamic>;
    if (Platform.isMacOS && MacOSNetworkContext.active != null) {
      config['interface-name'] = MacOSNetworkContext.active!.interfaceName;
    }
    for (final key in const ['port', 'socks-port', 'mixed-port']) {
      if (config.containsKey(key)) config[key] = port;
    }
    return jsonEncode(config);
  }

  static Future<int> _freeLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  static Future<Directory> _sessionDir() => DesktopCorePaths.sessionDir();

  static String get _binariesHint => DesktopCorePaths.binariesHint;

  static Future<void> _attachCoreProcess(int pid) async {
    if (Platform.isWindows) {
      await WindowsDesktopService.attachCoreProcess(pid);
    }
  }

  static Future<void>? _serialGate;

  static Future<T> _runSerial<T>(Future<T> Function() body) async {
    while (_serialGate != null) {
      await _serialGate;
    }
    final done = Completer<void>();
    _serialGate = done.future;
    try {
      return await body();
    } finally {
      done.complete();
      _serialGate = null;
    }
  }

  static Future<
    ({
      bool success,
      int? latencyMs,
      String error,
      int? httpStatus,
      UrlTestDiagnostics? diagnostics,
    })
  >
  urlTest({
    required String xrayConfigJson,
    required int socksPort,
    required String testUrl,
    required int timeoutMs,
    VpnBackend core = VpnBackend.xray,
  }) async {
    return _runSingle(
      xrayConfigJson: xrayConfigJson,
      socksPort: socksPort,
      core: core,
      testUrl: testUrl,
      timeoutMs: timeoutMs,
    );
  }

  static Future<
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
  urlTestBatch({
    required List<({String id, String xrayConfigJson})> items,
    required int socksPort,
    required String testUrl,
    required int timeoutMs,
    VpnBackend core = VpnBackend.xray,
    bool keepAlive = true,
  }) async {
    if (items.isEmpty) return [];
    // Внутри батча — по очереди: все элементы приходят с одним socksPort, и
    // параллельно они дрались бы за него. Параллелит вызовы PingService, он же
    // и выдаёт каждому замеру свой порт.
    final out =
        <
          ({
            String id,
            bool success,
            int? latencyMs,
            String error,
            int? httpStatus,
            UrlTestDiagnostics? diagnostics,
          })
        >[];
    for (final item in items) {
      final r = await _runSingle(
        xrayConfigJson: item.xrayConfigJson,
        socksPort: socksPort,
        core: core,
        testUrl: testUrl,
        timeoutMs: timeoutMs,
        keepAlive: keepAlive,
      );
      out.add((
        id: item.id,
        success: r.success,
        latencyMs: r.latencyMs,
        error: r.error,
        httpStatus: r.httpStatus,
        diagnostics: r.diagnostics,
      ));
    }
    return out;
  }

  /// Boots an ephemeral Xray per server and downloads [downloadUrl] through its
  /// SOCKS, returning throughput in kbps.
  static Future<List<({String id, bool success, int? kbps, String error})>>
  speedTestBatch({
    required List<({String id, String xrayConfigJson})> items,
    required int socksPort,
    required String downloadUrl,
    required int timeoutMs,
    VpnBackend core = VpnBackend.xray,
  }) async {
    if (items.isEmpty) return [];
    return _runSerial(() async {
      final out = <({String id, bool success, int? kbps, String error})>[];
      for (final item in items) {
        final r = await _runSpeedSingle(
          xrayConfigJson: item.xrayConfigJson,
          socksPort: socksPort,
          core: core,
          downloadUrl: downloadUrl,
          timeoutMs: timeoutMs,
        );
        out.add((
          id: item.id,
          success: r.success,
          kbps: r.kbps,
          error: r.error,
        ));
      }
      return out;
    });
  }

  // открытый порт у mihomo ещё не готовность: до Running он молча закрывает соединения.
  // на Pixel 6a при живом туннеле это 1.3-1.8 с
  static const coreWakeupGrace = Duration(seconds: 3);

  @visibleForTesting
  static bool retryProbeWhileCoreWakesUp({
    required VpnBackend core,
    required Duration sinceCoreStart,
  }) => core == VpnBackend.mihomo && sinceCoreStart < coreWakeupGrace;

  static Future<
    ({
      bool success,
      int? latencyMs,
      String error,
      int? httpStatus,
      UrlTestDiagnostics? diagnostics,
    })
  >
  _runSingle({
    required String xrayConfigJson,
    required int socksPort,
    required String testUrl,
    required int timeoutMs,
    VpnBackend core = VpnBackend.xray,
    bool keepAlive = true,
  }) async {
    final preparation = Stopwatch()..start();
    final startupBudget = timeoutMs.clamp(500, _startupBudgetMs);
    UrlTestDiagnostics startupDetails() {
      final elapsed = preparation.elapsedMilliseconds;
      return UrlTestDiagnostics(
        stage: 'coreStartup',
        elapsedMs: elapsed,
        budgetMs: startupBudget,
        stageDurationsMs: {'coreStartup': elapsed},
        coreStartupBudgetMs: startupBudget,
      );
    }

    if (!DesktopCorePaths.supported) {
      return (
        success: false,
        latencyMs: null,
        error: 'Ephemeral Xray ping is only implemented on desktop in Dart',
        httpStatus: null,
        diagnostics: startupDetails(),
      );
    }

    final coreBin = await _resolveCore(core);
    if (coreBin == null) {
      return (
        success: false,
        latencyMs: null,
        error: '${core.wireValue} not found. $_binariesHint',
        httpStatus: null,
        diagnostics: startupDetails(),
      );
    }

    final sessionDir = await _sessionDir();
    final configFile = File(
      p.join(
        sessionDir.path,
        '${core.wireValue}_ping_${DateTime.now().microsecondsSinceEpoch}.json',
      ),
    );
    Process? process;
    _CoreLog? coreLog;
    int? observedExit;
    // Порт может смениться на второй попытке — см. ниже.
    var port = socksPort;

    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        await configFile.writeAsString(_coreConfig(xrayConfigJson, port, core));
        process = await Process.start(
          coreBin,
          _coreArgs(core, configFile.path, sessionDir.path),
          workingDirectory: sessionDir.path,
          environment: Platform.isMacOS
              ? MacOSNetworkContext.active?.bootstrapEnvironment
              : null,
          mode: ProcessStartMode.normal,
        );
        unawaited(_attachCoreProcess(process.pid));
        final log = _CoreLog(process);
        coreLog = log;
        observedExit = null;
        final launched = process;
        unawaited(
          launched.exitCode.then((code) {
            if (identical(process, launched)) observedExit = code;
          }),
        );

        final startup = await _waitForPort(
          '127.0.0.1',
          port,
          Duration(
            milliseconds: (startupBudget - preparation.elapsedMilliseconds)
                .clamp(0, startupBudget),
          ),
          process: process,
        );
        if (startup.ready) break;

        // в TUN свободный порт уводит чужое исходящее соединение, пока ядро стартует, отсюда address already in use
        await _killProcess(process);
        process = null;
        if (startup.exitCode == null || attempt == 1) {
          return (
            success: false,
            latencyMs: null,
            error:
                'GET probe failed at coreStartup: ${AppLogger.redactSensitive(_startupError(startup.exitCode, port, log))}',
            httpStatus: null,
            diagnostics: startupDetails(),
          );
        }
        port = await _freeLoopbackPort();
      }

      final coreStartupMs = preparation.elapsedMilliseconds;
      final result = await probeWhileCoreWakesUp(
        core: core,
        timeoutMs: timeoutMs,
        coreExited: () => observedExit != null,
        probe: (remaining) => _httpProbeViaSocks(
          testUrl: testUrl,
          socksPort: port,
          timeoutMs: remaining,
          keepAlive: keepAlive,
        ),
      );
      final diagnostic = result.diagnostics?.withCoreStartup(
        elapsedMs: coreStartupMs,
        budgetMs: startupBudget,
      );
      if (diagnostic != null) {
        AppLogger.instance.debug(
          'Desktop GET probe: ${jsonEncode(diagnostic.toMap())}',
        );
      }
      if (result.success) {
        return (
          success: true,
          latencyMs: result.latencyMs,
          error: result.error,
          httpStatus: result.httpStatus,
          diagnostics: diagnostic,
        );
      }
      final coreFailure = observedExit == null
          ? ''
          : ' Core exited with code $observedExit.';
      return (
        success: false,
        latencyMs: null,
        httpStatus: result.httpStatus,
        diagnostics: diagnostic,
        error:
            '${result.error}$coreFailure${AppLogger.redactSensitive(coreLog?.tail ?? '')}',
      );
    } catch (e) {
      AppLogger.instance.debug('EphemeralXrayPing failed: $e');
      return (
        success: false,
        latencyMs: null,
        error:
            'GET probe failed at coreStartup: ${AppLogger.redactSensitive(e.toString())}',
        httpStatus: null,
        diagnostics: startupDetails(),
      );
    } finally {
      await _killProcess(process);
      try {
        await sessionDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<({bool success, int? kbps, String error})> _runSpeedSingle({
    required String xrayConfigJson,
    required int socksPort,
    required String downloadUrl,
    required int timeoutMs,
    VpnBackend core = VpnBackend.xray,
  }) async {
    if (!DesktopCorePaths.supported) {
      return (
        success: false,
        kbps: null,
        error: 'Speed test runs on desktop only',
      );
    }

    final coreBin = await _resolveCore(core);
    if (coreBin == null) {
      return (
        success: false,
        kbps: null,
        error: '${core.wireValue} not found. $_binariesHint',
      );
    }

    final sessionDir = await _sessionDir();
    final configFile = File(
      p.join(
        sessionDir.path,
        '${core.wireValue}_speed_${DateTime.now().microsecondsSinceEpoch}.json',
      ),
    );
    Process? process;

    try {
      await configFile.writeAsString(
        _coreConfig(xrayConfigJson, socksPort, core),
      );
      process = await Process.start(
        coreBin,
        _coreArgs(core, configFile.path, sessionDir.path),
        workingDirectory: sessionDir.path,
        environment: Platform.isMacOS
            ? MacOSNetworkContext.active?.bootstrapEnvironment
            : null,
        mode: ProcessStartMode.normal,
      );
      unawaited(_attachCoreProcess(process.pid));
      final log = _CoreLog(process);

      final startup = await _waitForPort(
        '127.0.0.1',
        socksPort,
        Duration(milliseconds: timeoutMs.clamp(500, _startupBudgetMs)),
        process: process,
      );
      if (!startup.ready) {
        return (
          success: false,
          kbps: null,
          error: _startupError(startup.exitCode, socksPort, log),
        );
      }

      return await _downloadProbeViaSocks(
        downloadUrl: downloadUrl,
        socksPort: socksPort,
        timeoutMs: timeoutMs,
      );
    } catch (e) {
      AppLogger.instance.debug('EphemeralXrayPing speed failed: $e');
      return (success: false, kbps: null, error: e.toString());
    } finally {
      await _killProcess(process);
      try {
        await sessionDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Downloads the payload through the SOCKS proxy and computes kbps from the
  /// bytes received over the body-transfer time.
  static Future<({bool success, int? kbps, String error})>
  _downloadProbeViaSocks({
    required String downloadUrl,
    required int socksPort,
    required int timeoutMs,
  }) async {
    final client = HttpClient();
    try {
      // dart:io HttpClient умеет только PROXY и DIRECT, поэтому у ядра замера HTTP-инбаунд
      client.findProxy = (_) => 'PROXY 127.0.0.1:$socksPort';
      // Сертификат проверяем: с badCertificateCallback=true MITM мог
      // «нарисовать» успешный замер мёртвому/подменённому серверу.
      client.connectionTimeout = Duration(
        milliseconds: timeoutMs.clamp(1000, 8000),
      );

      final request = await client.getUrl(Uri.parse(_ensureHttps(downloadUrl)));
      request.headers.set('User-Agent', 'KEQDIS/1.0');
      final response = await request.close().timeout(
        Duration(milliseconds: timeoutMs.clamp(2000, 30000)),
      );

      if (response.statusCode < 200 || response.statusCode >= 400) {
        await response.drain<void>();
        return (
          success: false,
          kbps: null,
          error: 'HTTP ${response.statusCode}',
        );
      }

      final sw = Stopwatch()..start();
      var bytes = 0;
      await for (final chunk in response.timeout(
        Duration(milliseconds: timeoutMs.clamp(2000, 30000)),
      )) {
        bytes += chunk.length;
      }
      sw.stop();

      final seconds = sw.elapsedMilliseconds / 1000.0;
      if (bytes <= 0 || seconds <= 0) {
        return (success: false, kbps: null, error: 'No data received');
      }
      final kbps = (bytes * 8 / 1000.0 / seconds).round();
      return (success: true, kbps: kbps, error: '');
    } on TimeoutException {
      return (success: false, kbps: null, error: 'Timeout');
    } catch (e) {
      return (success: false, kbps: null, error: e.toString());
    } finally {
      client.close(force: true);
    }
  }

  // Открытый порт — ещё не готовность (см. [coreWakeupGrace]). Повторы
  // делят один бюджет замера; подготовка ядра учитывается отдельно.
  @visibleForTesting
  static Future<UrlTestResult> probeWhileCoreWakesUp({
    required VpnBackend core,
    required int timeoutMs,
    required bool Function() coreExited,
    required Future<UrlTestResult> Function(int remainingMs) probe,
  }) async {
    final coreLife = Stopwatch()..start();
    var result = await probe(timeoutMs);
    var retryPreparationMs = 0;
    while (!result.success &&
        !coreExited() &&
        retryProbeWhileCoreWakesUp(
          core: core,
          sinceCoreStart: coreLife.elapsed,
        ) &&
        coreLife.elapsedMilliseconds + 200 < timeoutMs) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final remaining = timeoutMs - coreLife.elapsedMilliseconds;
      if (remaining <= 0 || coreExited()) break;
      retryPreparationMs = coreLife.elapsedMilliseconds;
      result = await probe(remaining);
    }
    final diagnostic = result.diagnostics;
    if (retryPreparationMs == 0 || diagnostic == null) return result;
    return (
      success: result.success,
      latencyMs: result.latencyMs,
      error: result.error,
      httpStatus: result.httpStatus,
      diagnostics: UrlTestDiagnostics(
        stage: diagnostic.stage,
        elapsedMs: coreLife.elapsedMilliseconds,
        budgetMs: timeoutMs,
        timingKind: diagnostic.timingKind,
        completedRequests: diagnostic.completedRequests,
        warning: diagnostic.warning,
        stageDurationsMs: {
          'coreWakeup': retryPreparationMs,
          ...diagnostic.stageDurationsMs,
        },
        coreStartupBudgetMs: diagnostic.coreStartupBudgetMs,
      ),
    );
  }

  static Future<UrlTestResult> _httpProbeViaSocks({
    required String testUrl,
    required int socksPort,
    required int timeoutMs,
    bool keepAlive = true,
  }) => DesktopHttpProbe.run(
    testUrl: testUrl,
    proxyPort: socksPort,
    timeout: Duration(milliseconds: timeoutMs),
    keepAlive: keepAlive,
  );

  static String _ensureHttps(String url) {
    final trimmed = url.trim();
    if (trimmed.toLowerCase().startsWith('http://')) {
      return 'https://${trimmed.substring(7)}';
    }
    return trimmed;
  }

  // до шестнадцати ядер стартуют разом и делят диск с антивирусом, 5 с не хватало
  static const int _startupBudgetMs = 12000;

  /// Ждёт порт временного ядра. `exitCode` не null — ядро вышло само.
  @visibleForTesting
  static Future<({bool ready, int? exitCode})> waitForCorePort({
    required Process process,
    required int port,
    Duration timeout = const Duration(seconds: 1),
  }) => _waitForPort('127.0.0.1', port, timeout, process: process);

  static Future<({bool ready, int? exitCode})> _waitForPort(
    String host,
    int port,
    Duration maxWait, {
    Process? process,
  }) async {
    final deadline = DateTime.now().add(maxWait);
    int? exited;
    if (process != null) {
      unawaited(
        process.exitCode.then((code) {
          exited = code;
        }),
      );
    }
    var delay = const Duration(milliseconds: 20);
    while (DateTime.now().isBefore(deadline)) {
      // POSIX signal exits are negative; they are exits, not a timeout sentinel.
      if (exited != null) return (ready: false, exitCode: exited);
      try {
        final s = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 200),
        );
        await s.close();
        return (ready: true, exitCode: null);
      } catch (_) {
        await Future<void>.delayed(delay);
        if (delay.inMilliseconds < 80) {
          delay = Duration(milliseconds: delay.inMilliseconds + 15);
        }
      }
    }
    return (ready: false, exitCode: null);
  }

  static String _startupError(int? exitCode, int port, _CoreLog log) =>
      exitCode != null
      ? 'Core exited with code $exitCode before opening port $port${log.tail}'
      : 'Core did not open port $port in time${log.tail}';

  static Future<void> _killProcess(Process? process) async {
    if (process == null) return;
    try {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}
