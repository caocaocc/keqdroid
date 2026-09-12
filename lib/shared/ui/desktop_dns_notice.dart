import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../tunnel/desktop_dns_diagnostics.dart';
import 'app_theme.dart';
import 'expressive_elements.dart';

/// The home screen shows failures; the existing diagnostics page shows all results.
class DesktopDnsNotice extends StatelessWidget {
  const DesktopDnsNotice({super.key, this.showDetails = false});

  final bool showDetails;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<DesktopDnsDiagnostics?>(
        valueListenable: desktopDnsDiagnostics,
        builder: (context, diagnostic, child) {
          if (diagnostic == null ||
              (!showDetails && diagnostic.status != 'warning')) {
            return const SizedBox.shrink();
          }
          final l10n = AppLocalizations.of(context)!;
          final label = switch (diagnostic.status) {
            'checking' => l10n.macosTunDnsChecking,
            'ok' => l10n.macosTunDnsOk,
            _ => l10n.macosTunDnsWarning,
          };
          return Padding(
            padding: const EdgeInsets.all(12),
            child: ExpressiveNotice(
              color: diagnostic.status == 'warning'
                  ? AppTheme.orange(context)
                  : Theme.of(context).colorScheme.primary,
              icon: diagnostic.status == 'warning'
                  ? Icons.warning_amber_rounded
                  : Icons.dns_outlined,
              text: showDetails
                  ? '${l10n.macosTunDnsTitle}: $label\n${diagnostic.message}'
                  : label,
            ),
          );
        },
      );
}
