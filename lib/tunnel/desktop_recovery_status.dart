import 'package:flutter/foundation.dart';
import 'macos_recovery_controller.dart';

class DesktopRecoveryStatus {
  final MacOSRecoveryPhase phase;
  final String? reason;
  final String? message;
  final int retries;
  const DesktopRecoveryStatus(
    this.phase,
    this.reason,
    this.message,
    this.retries,
  );
}

final desktopRecoveryStatus = ValueNotifier<DesktopRecoveryStatus?>(null);
