import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../tunnel/desktop_dns_diagnostics.dart';
import '../../tunnel/desktop_recovery_status.dart';
import '../../tunnel/macos_recovery_controller.dart';
import '../../tunnel/tunnel_state.dart';
import 'app_theme.dart';
import 'desktop_dns_notice.dart';
import 'desktop_recovery_notice.dart';

/// Uses the header's existing status slot; diagnostics never resize the page.
class DesktopConnectionNotice extends StatelessWidget {
  const DesktopConnectionNotice({
    super.key,
    required this.status,
    required this.child,
  });

  final VpnStatus status;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      desktopRecoveryStatus,
      desktopDnsDiagnostics,
    ]),
    builder: (context, _) {
      final l10n = AppLocalizations.of(context)!;
      final recovery = desktopRecoveryStatus.value;
      if (recovery != null && recovery.phase != MacOSRecoveryPhase.idle) {
        final label = desktopRecoveryLabel(l10n, recovery.phase);
        return Tooltip(
          message: l10n.settingsAdvancedGroupDiagnostics,
          child: TextButton(
            key: const ValueKey('desktop-recovery-status'),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.orange(context),
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _showDetails(context),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppTheme.orange(context)),
            ),
          ),
        );
      }
      if (status != VpnStatus.connected ||
          desktopDnsDiagnostics.value?.status != 'warning') {
        return child;
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(child: child),
          IconButton(
            key: const ValueKey('desktop-dns-warning'),
            tooltip: l10n.macosTunDnsWarning,
            color: AppTheme.orange(context),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.warning_amber_rounded),
            onPressed: () => _showDetails(context),
          ),
        ],
      );
    },
  );

  void _showDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          AppLocalizations.of(context)!.settingsAdvancedGroupDiagnostics,
        ),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DesktopRecoveryNotice(showDetails: true),
              DesktopDnsNotice(showDetails: true),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      ),
    );
  }
}
