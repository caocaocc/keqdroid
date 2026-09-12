import '../tunnel/url_test_diagnostics.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../core/app_logger.dart';
import '../tunnel/desktop_core_paths.dart';
import '../tunnel/macos_network_context.dart';
import '../tunnel/vpn_backend.dart';
import '../utils/keqrnel_config.dart';
import 'windows_desktop_service.dart';
import 'desktop_http_probe.dart';

final _ansiEscape = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

/// Снимает ANSI-раскраску со строки лога ядра.
///
/// Ядро красит уровень сообщения даже в трубу, и без чистки в текст ошибки
/// приезжало `\x1B[31mFATAL\x1B[0m` вместо слова FATAL.
@visibleForTesting
String stripAnsi(String value) => value.replaceAll(_ansiEscape, '');

/// Хвост вывода временного ядра — и страховка, и единственная улика.
///
/// Трубы дочернего процесса обязаны вычитываться. Их не читал никто: стоило
/// ядру наговорить больше буфера трубы, и оно вставало на записи навсегда —
/// читать было некому. Снаружи это выглядело ровно как «порт не поднялся»,
/// потому что порт после этого и правда не открывался.
///
/// Заодно это единственное место, где ядро объясняет, почему не поднялось.
/// Держим последние строки: раньше они уходили в никуда.
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

  /// Готовая приписка к сообщению об ошибке; пусто, если ядро молчало.
  String get tail => _lines.isEmpty ? '' : ': ${_lines.join(' | ')}';
}

/// короткоживущий xray для url-пинга, как на android
class EphemeralXrayPing {
  EphemeralXrayPing._();

  // Desktop core resolution is platform-specific; the rest (config, socks probe)
  // is platform-neutral so url/speed ping work on Windows and Linux alike.
  static Future<String?> _resolveXray() => DesktopCorePaths.keqrnelExecutable();

  static Future<String?> _resolveMihomo() =>
      DesktopCorePaths.mihomoExecutable();

  /// Бинарь ядра, которым меряем.
  static Future<String?> _resolveCore(VpnBackend core) =>
      core == VpnBackend.mihomo ? _resolveMihomo() : _resolveXray();

  /// Аргументы запуска. У ядер они разные, и у mihomo домашний каталог —
  /// каталог сессии замера, а не общий с туннелем.
  ///
  /// Общий стоил бы блокировки: mihomo держит `cache.db` через bbolt с
  /// секундным таймаутом на захват файла (`initCache` в ядре), и замер во
  /// время живого подключения ждал бы эту секунду впустую — прямо в измеряемое
  /// время. Geo-базы замеру не нужны, его конфиг правил с ними не содержит.
  static List<String> _coreArgs(
    VpnBackend core,
    String configPath,
    String sessionDirPath,
  ) => core == VpnBackend.mihomo
      ? ['-d', sessionDirPath, '-f', configPath]
      : ['run', '-c', configPath];

  /// The ephemeral test runs through keqrnel, so the xray config is wrapped into
  /// keqrnel's embedded-xray outbound (its own socks inbound binds the test port
  /// exactly like standalone xray).
  ///
  /// [port] переписывает порт инбаунда уже в готовом конфиге: на повторной
  /// попытке номер другой, а пересобирать ради этого весь xray-конфиг (он
  /// приезжает сюда строкой от генератора) значило бы тащить сюда и генератор,
  /// и настройки.
  static String _coreConfig(String configJson, int port, VpnBackend core) {
    if (core == VpnBackend.mihomo) return _mihomoConfig(configJson, port);
    if (!DesktopCorePaths.supported) return configJson;
    final box =
        jsonDecode(KeqrnelConfig.wrapXray(configJson)) as Map<String, dynamic>;
    if (Platform.isMacOS && MacOSNetworkContext.active != null) {
      (box['route'] as Map)['default_interface'] =
          MacOSNetworkContext.active!.interfaceName;
    }
    final inbounds = box['inbounds'];
    if (inbounds is List) {
      for (final inbound in inbounds) {
        if (inbound is Map<String, dynamic>) inbound['listen_port'] = port;
      }
    }
    return jsonEncode(box);
  }

  /// mihomo оборачивать не во что — он сам себе ядро. Меняем только номер
  /// порта инбаунда, по той же причине, что и у xray: на повторной попытке он
  /// другой, а пересобирать конфиг заново значило бы тащить сюда генератор.
  ///
  /// Какой из двух ключей выставлен, решает генератор (`port` — HTTP, десктоп;
  /// `socks-port` — Android), поэтому правим тот, что уже есть, и не добавляем
  /// второй: лишний инбаунд занял бы ещё один порт.
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

  /// Свободный порт на петле. Тот же способ, что у PingService: занять сокет с
  /// нулевым портом и сразу отпустить.
  static Future<int> _freeLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  static Future<Directory> _sessionDir() => DesktopCorePaths.sessionDir();

  static String get _binariesHint => DesktopCorePaths.binariesHint;

  /// Windows registers cores for taskkill cleanup; no-op elsewhere.
  static Future<void> _attachCoreProcess(int pid) async {
    if (Platform.isWindows) {
      await WindowsDesktopService.attachCoreProcess(pid);
    }
  }

  static Future<void>? _serialGate;

  /// Пропускает по одному замеру за раз.
  ///
  /// Нужен только спидтесту: он меряет полосу канала, и параллельные качалки
  /// делили бы её между собой, выдавая N заниженных цифр вместо одной честной.
  /// URL-пинг через эту калитку не идёт — каждый его замер живёт в своём
  /// временном каталоге ([_sessionDir] делает `createTemp`) и на своём порту,
  /// общего состояния между замерами нет. Сколько их идёт разом, решает
  /// PingService.urlPingConcurrency — одна точка на все платформы.
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

        // Ядро выпало сразу — самая частая причина этого на десктопе в
        // TUN-режиме: порт увели у нас из-под рук. Свободный номер мы
        // выбираем, заняв и тут же отпустив сокет, а между этим и bind'ом
        // ядра проходит время старта процесса. В TUN через машину идёт весь
        // трафик, динамических портов расходуется много, и в это окно порт
        // достаётся чужому исходящему соединению — тогда ядро падает на
        // «address already in use», а пользователь видит мёртвый сервер при
        // живом. Одна повторная попытка со свежим портом это закрывает;
        // настоящую поломку конфига она не чинит, но и стоит меньше секунды —
        // упавшее ядро замечается по коду выхода, а не по таймауту.
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
      final result = await _httpProbeViaSocks(
        testUrl: testUrl,
        socksPort: port,
        timeoutMs: timeoutMs,
        keepAlive: keepAlive,
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
      // HTTP proxy ('PROXY host:port'), not SOCKS: dart:io HttpClient.findProxy
      // supports only PROXY (HTTP CONNECT) and DIRECT — never SOCKS/SOCKS5. The
      // ephemeral ping config exposes an HTTP inbound on this port for exactly this
      // reason (see ConfigGeneratorV2 ping mode). The port arg is still named
      // socksPort for historical reasons.
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

      // Time only the body transfer (TLS/connect excluded) for cleaner numbers.
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

  /// Сколько ждём, пока временное ядро откроет свой порт.
  ///
  /// Было 5 секунд, и на десктопе в TUN-режиме этого не хватало: батч поднимает
  /// до шести ядер разом (PingService.urlPingConcurrency), они делят диск и
  /// антивирусную проверку, а срок у всех шести общий — стартуют-то они в одну
  /// секунду. Успевали первые, остальные краснели «порт не поднялся» на живых
  /// серверах. Упавшее ядро ждать не заставляет: выход процесса замечается
  /// сразу и без таймаута, так что запас платят только те, кто реально
  /// поднимается медленно.
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

  /// Почему ядро не открыло порт — словами, а не одной строкой на все случаи.
  ///
  /// Прежнее «port not ready» одинаково значило «упало на конфиге» и «не успело
  /// подняться», а последние слова самого ядра уходили в никуда. Разбирать по
  /// такому сообщению было нечего.
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
