import 'dart:async';

import 'connection_mode.dart';

enum MacOSRecoveryPhase {
  idle,
  waitingNetwork,
  recovering,
  backoff,
  retrying,
  paused,
}

/// Only connection intent lives here. Each attempt rebuilds its configuration in
/// the provider; network observations never grant permission to start a core.
class MacOSRecoveryController {
  MacOSRecoveryController({
    required this.attempt,
    required this.onChanged,
    DateTime Function()? now,
  }) : now = now ?? _monotonicClock();

  static DateTime Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => DateTime.fromMicrosecondsSinceEpoch(clock.elapsedMicroseconds);
  }

  final Future<void> Function(int generation) attempt;
  final void Function() onChanged;
  final DateTime Function() now;
  static const retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];
  int generation = 0;
  bool wanted = false;
  bool _disposed = false;
  bool _attempting = false;
  bool _connected = false;
  int retries = 0;
  ConnectionMode mode = ConnectionMode.proxy;
  MacOSRecoveryPhase phase = MacOSRecoveryPhase.idle;
  String? reason;
  String? message;
  DateTime? _readySince;
  DateTime? _connectedSince;
  DateTime? _retryAt;
  String? _revision;
  String? _handledFailure;
  Map<String, dynamic> _service = const {};

  bool get waiting => wanted && phase != MacOSRecoveryPhase.idle;

  int begin(ConnectionMode selectedMode) {
    generation++;
    wanted = true;
    mode = selectedMode;
    retries = 0;
    _connected = false;
    _connectedSince = null;
    _readySince = null;
    _handledFailure = null;
    _retryAt = null;
    _set(MacOSRecoveryPhase.retrying);
    return generation;
  }

  void cancel() {
    generation++;
    wanted = false;
    _connected = false;
    _readySince = null;
    _connectedSince = null;
    _retryAt = null;
    _set(MacOSRecoveryPhase.idle);
  }

  void dispose() {
    cancel();
    _disposed = true;
  }

  void _set(MacOSRecoveryPhase next, {String? code, String? text}) {
    if (_disposed) return;
    if (phase == next && reason == code && message == text) return;
    phase = next;
    reason = code;
    message = text;
    onChanged();
  }

  void connected() {
    if (!wanted) return;
    if (!_connected) _handledFailure = null;
    _connectedSince ??= now();
    _connected = true;
    _retryAt = null;
    _set(MacOSRecoveryPhase.idle);
  }

  /// A failure is handled once per native occurrence, not once per poll.
  void failed(String code, {String? text, String? occurrence}) {
    if (!wanted || _disposed) return;
    if (occurrence != null && occurrence == _handledFailure) return;
    _handledFailure = occurrence;
    _connected = false;
    _connectedSince = null;
    _readySince = null;
    if (const {
      'physicalNetworkUnavailable',
      'physicalDNSUnavailable',
      'ipv4RoutesUnavailable',
      'staleNetworkContext',
      'network_changed',
      'systemWake',
    }.contains(code)) {
      _set(MacOSRecoveryPhase.waitingNetwork, code: code, text: text);
      return;
    }
    if (code == 'recoveryRequired') {
      _set(MacOSRecoveryPhase.recovering, code: code, text: text);
      return;
    }
    if (const {
      'coreExited',
      'serviceInterrupted',
      'serviceUnavailable',
      'serviceInvalidated',
      'requestOutcomeUnknown',
      'unavailable',
      'timeout',
      'clientDisconnected',
      'networkSettingsBusy',
    }.contains(code)) {
      if (retries < retryDelays.length) {
        _retryAt = now().add(retryDelays[retries++]);
        _set(MacOSRecoveryPhase.backoff, code: code, text: text);
        return;
      }
    }
    wanted = false;
    generation++;
    _set(MacOSRecoveryPhase.paused, code: code, text: text);
  }

  /// Called by the existing backend poll even when VpnState did not change.
  void observe({
    required Map<String, dynamic> service,
    required Map<String, dynamic> session,
  }) {
    _service = service;
    if (!wanted ||
        _disposed ||
        _attempting ||
        phase == MacOSRecoveryPhase.retrying) {
      return;
    }
    final time = now();
    final status = session['status'];
    // A restarted helper can expose recovery status while its previous owner
    // prevents getSession. Cleanup must win over that transport/identity error.
    if (service['recoveryRequired'] == true ||
        session['recoveryRequired'] == true) {
      final code =
          service['recoveryErrorCode'] as String? ??
          (session['recoveryRequired'] == true
              ? session['errorCode'] as String?
              : null) ??
          'recoveryRequired';
      if (code != 'recoveryRequired') {
        failed(code, text: session['recoveryError'] as String?);
      } else {
        _connected = false;
        _connectedSince = null;
        _set(MacOSRecoveryPhase.recovering, code: code);
      }
      return;
    }
    if (session['transportUnavailable'] == true) {
      failed(
        session['errorCode'] as String? ?? 'serviceInterrupted',
        text: session['error'] as String?,
        occurrence: 'transport/${session['sessionId']}',
      );
      return;
    }
    if (status == 'connected') {
      connected();
      if (_connectedSince != null &&
          time.difference(_connectedSince!) >= const Duration(minutes: 5)) {
        retries = 0;
      }
      return;
    }
    if (service['busy'] == true) {
      failed(
        'busy',
        text: 'Another application instance owns the network session.',
      );
      return;
    }
    if (service['installed'] != true || service['protocolVersion'] != 1) {
      failed(
        'protocolMismatch',
        text: 'Install matching application and network service versions.',
      );
      return;
    }
    if (mode == ConnectionMode.tun && service['authorized'] != true ||
        mode == ConnectionMode.proxy &&
            service['proxyWithoutElevation'] != true) {
      failed(
        'authorizationRequired',
        text: 'Connect manually to authorize the network service.',
      );
      return;
    }
    if (status == 'error') {
      final code = session['errorCode'] as String?;
      if (code != null) {
        failed(
          code,
          text: session['error'] as String?,
          occurrence:
              '${service['helperEpoch']}/${session['sessionId']}/$code/${session['errorStage']}',
        );
        if (!wanted) return;
      }
    } else if (_connected && status == 'disconnected') {
      failed(
        'serviceInterrupted',
        occurrence: '${service['helperEpoch']}/disconnected',
      );
    }
    if (phase == MacOSRecoveryPhase.retrying ||
        phase == MacOSRecoveryPhase.idle) {
      return;
    }
    final network = service['networkStatus'];
    final entry = network is Map ? network[mode.storageValue] : null;
    // Old helpers have no readiness summary. Do not loop against them.
    if (entry is! Map) {
      failed(
        'protocolMismatch',
        text: 'Update the macOS network service to enable automatic recovery.',
      );
      return;
    }
    final networkCode =
        entry['reason'] as String? ?? 'physicalNetworkUnavailable';
    if (entry['state'] == 'blocked') {
      failed(networkCode, text: entry['message'] as String?);
      return;
    }
    if (entry['state'] != 'ready') {
      _readySince = null;
      _set(
        MacOSRecoveryPhase.waitingNetwork,
        code: networkCode,
        text: entry['message'] as String?,
      );
      return;
    }
    final revision = network['revision'] as String? ?? '';
    if (_readySince == null || revision != _revision) {
      _readySince = time;
      _revision = revision;
    }
    if (time.difference(_readySince!) < const Duration(seconds: 2) ||
        _retryAt != null && time.isBefore(_retryAt!)) {
      return;
    }
    _attempting = true;
    final ticket = generation;
    _set(MacOSRecoveryPhase.retrying);
    unawaited(() async {
      try {
        await attempt(ticket);
      } catch (error) {
        if (ticket == generation && wanted) {
          failed('startFailed', text: error.toString());
        }
      } finally {
        _attempting = false;
      }
    }());
  }

  Map<String, dynamic> get lastService => _service;
}
