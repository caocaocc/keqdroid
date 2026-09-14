import 'package:flutter/foundation.dart';

/// A session's DNS check is independent of whether its tunnel is connected.
class DesktopDnsDiagnostics {
  const DesktopDnsDiagnostics({
    required this.sessionId,
    required this.status,
    required this.message,
  });

  final String sessionId;
  final String status;
  final String message;

  static DesktopDnsDiagnostics? fromSnapshot(Object? raw, String sessionId) {
    if (raw is! Map || raw['sessionId'] != sessionId) return null;
    final status = raw['status'];
    final message = raw['message'];
    if (!const {'checking', 'ok', 'warning'}.contains(status) ||
        message is! String ||
        message.length > 4096) {
      return null;
    }
    return DesktopDnsDiagnostics(
      sessionId: sessionId,
      status: status as String,
      message: message,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopDnsDiagnostics &&
      sessionId == other.sessionId &&
      status == other.status &&
      message == other.message;

  @override
  int get hashCode => Object.hash(sessionId, status, message);
}

/// Updated by the desktop backend; reading this never starts a DNS query.
final desktopDnsDiagnostics = ValueNotifier<DesktopDnsDiagnostics?>(null);
