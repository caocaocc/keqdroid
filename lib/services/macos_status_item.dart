import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import '../tunnel/desktop_recovery_status.dart';
import '../tunnel/macos_recovery_controller.dart';
import '../tunnel/tunnel_state.dart';

/// Presentation consumes the existing statistics stream, including while hidden.
class MacOSStatusItem {
  MacOSStatusItem({
    required this.send,
    required AppLocalizations labels,
    Duration Function()? clock,
  }) : _labels = labels {
    final watch = Stopwatch()..start();
    _clock = clock ?? (() => watch.elapsed);
  }

  final void Function(Map<String, Object> payload) send;
  late final Duration Function() _clock;
  AppLocalizations _labels;
  VpnStatus _status = VpnStatus.disconnected;
  DesktopRecoveryStatus? _recovery;
  bool _showSpeed = true;
  bool _disposed = false;
  int? _up;
  int? _down;
  Duration? _sampleAt;
  Timer? _expiry;
  Map<String, Object>? _sent;
  static const freshness = Duration(seconds: 3);

  void updateLabels(AppLocalizations value) {
    _labels = value;
    _publish();
  }

  void setShowSpeed(bool value) {
    if (_showSpeed != value) _clearSample();
    _showSpeed = value;
    _publish();
  }

  void invalidateSample() {
    _clearSample();
    _publish();
  }

  void updateRecovery(DesktopRecoveryStatus? recovery) {
    _recovery = recovery;
    if (_recovering) _clearSample();
    _publish();
  }

  bool get _recovering =>
      _recovery != null && _recovery!.phase != MacOSRecoveryPhase.idle;

  void updateState(VpnState state) {
    if (_disposed) return;
    _status = state.status;
    if (_status != VpnStatus.connected || _recovering || !_showSpeed) {
      _clearSample();
    } else if (state.uploadSpeed != null &&
        state.downloadSpeed != null &&
        state.uploadSpeed! >= 0 &&
        state.downloadSpeed! >= 0) {
      _up = state.uploadSpeed;
      _down = state.downloadSpeed;
      _sampleAt = _clock();
      _expiry?.cancel();
      // One expiry deadline, not another statistics poll. A status-only event
      // must not refresh this deadline or make a stale rate appear live.
      _expiry = Timer(freshness, _publish);
    }
    _publish();
  }

  VpnStatus get visualStatus => switch (_recovery?.phase) {
    MacOSRecoveryPhase.waitingNetwork ||
    MacOSRecoveryPhase.backoff ||
    MacOSRecoveryPhase.retrying => VpnStatus.connecting,
    MacOSRecoveryPhase.recovering => VpnStatus.disconnecting,
    MacOSRecoveryPhase.paused => VpnStatus.error,
    _ => _status,
  };

  String get statusText => switch (_recovery?.phase) {
    MacOSRecoveryPhase.waitingNetwork => _labels.macosWaitingNetwork,
    MacOSRecoveryPhase.recovering => _labels.macosRestoringNetwork,
    MacOSRecoveryPhase.backoff => _labels.macosRetryingNetwork,
    // Initial manual connection also uses retrying internally.
    MacOSRecoveryPhase.retrying => _labels.vpnConnecting,
    MacOSRecoveryPhase.paused => _labels.macosRecoveryPaused,
    _ => macOSConnectionLabel(_labels, _status),
  };

  void _publish() {
    if (_disposed) return;
    final age = _sampleAt == null ? null : _clock() - _sampleAt!;
    final valid =
        !_recovering &&
        _status == VpnStatus.connected &&
        age != null &&
        age >= Duration.zero &&
        age < freshness;
    final payload = <String, Object>{
      'status': visualStatus.name,
      'statusText': statusText,
      'showSpeed': _showSpeed,
      'uploadText': formatMacOSMenuRate(valid ? _up : null),
      'downloadText': formatMacOSMenuRate(valid ? _down : null),
      'uploadLabel': _labels.statsUploadLabel,
      'downloadLabel': _labels.statsDownloadLabel,
    };
    if (mapEquals(_sent, payload)) return;
    _sent = payload;
    send(payload);
  }

  void _clearSample() {
    _expiry?.cancel();
    _expiry = null;
    _sampleAt = null;
    _up = _down = null;
  }

  void dispose() {
    _disposed = true;
    _clearSample();
  }
}

String macOSConnectionLabel(AppLocalizations labels, VpnStatus status) =>
    switch (status) {
      VpnStatus.connected => labels.trayStatusConnected,
      VpnStatus.connecting => labels.vpnConnecting,
      VpnStatus.disconnecting => labels.vpnDisconnecting,
      VpnStatus.error => labels.trayStatusError,
      VpnStatus.disconnected => labels.trayStatusDisconnected,
    };

String formatMacOSMenuRate(int? bytes) {
  if (bytes == null || bytes < 0) return '— KB/s';
  if (bytes < 1024 * 1024) return '${bytes ~/ 1024} KB/s';
  final megabytes = bytes ~/ (1024 * 1024);
  // Keep even a corrupt/implausible counter inside the fixed native text slot.
  return megabytes > 9999 ? '>9999 MB/s' : '$megabytes MB/s';
}

bool desktopTrafficPollingNeeded({
  required bool visible,
  required bool foreground,
  required bool macOS,
  required bool showMenuBarSpeed,
}) => (visible && foreground) || (macOS && showMenuBarSpeed);
