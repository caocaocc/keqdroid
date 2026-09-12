import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/providers.dart';
import '../../tunnel/desktop_recovery_status.dart';
import '../../tunnel/macos_recovery_controller.dart';
import 'app_theme.dart';
import 'expressive_elements.dart';

class DesktopRecoveryNotice extends ConsumerWidget {
  const DesktopRecoveryNotice({super.key, this.showDetails = false});
  final bool showDetails;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ValueListenableBuilder<DesktopRecoveryStatus?>(
        valueListenable: desktopRecoveryStatus,
        builder: (context, status, _) {
          if (status == null) return const SizedBox.shrink();
          final l10n = AppLocalizations.of(context)!;
          final label = switch (status.phase) {
            MacOSRecoveryPhase.waitingNetwork => l10n.macosWaitingNetwork,
            MacOSRecoveryPhase.recovering => l10n.macosRestoringNetwork,
            MacOSRecoveryPhase.backoff => l10n.macosRetryingNetwork,
            MacOSRecoveryPhase.retrying => l10n.macosRetryingNetwork,
            MacOSRecoveryPhase.paused => l10n.macosRecoveryPaused,
            MacOSRecoveryPhase.idle => '',
          };
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExpressiveNotice(
                  color: AppTheme.orange(context),
                  icon: Icons.network_check,
                  text: showDetails && status.message != null
                      ? '$label\n${status.message}'
                      : label,
                ),
                if (status.phase == MacOSRecoveryPhase.paused &&
                    const {
                      'recoveryFailed',
                      'recoveryRequired',
                    }.contains(status.reason))
                  TextButton(
                    onPressed: () async {
                      try {
                        await ref.read(vpnStateProvider.notifier).disconnect();
                      } catch (_) {
                        /* The provider preserves the recovery failure. */
                      }
                    },
                    child: Text(l10n.macosRetryRecovery),
                  ),
              ],
            ),
          );
        },
      );
}
