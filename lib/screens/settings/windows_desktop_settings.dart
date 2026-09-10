part of '../settings_tab.dart';

class _WindowsDesktopSettingsScreen extends ConsumerWidget {
  const _WindowsDesktopSettingsScreen();

  Future<void> _save(WidgetRef ref, AppSettings next) async {
    if (Platform.isMacOS) {
      try {
        final previous = ref.read(settingsNotifierProvider).value;
        await MacOSDesktopService.applySettings(
          next,
          updateLoginItem: previous?.launchAtStartup != next.launchAtStartup,
        );
      } catch (error) {
        if (ref.context.mounted) {
          ScaffoldMessenger.of(
            ref.context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
        return;
      }
    }
    await ref.read(settingsNotifierProvider.notifier).save(next);
    if (Platform.isWindows) await WindowsDesktopService.applySettings(next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings =
        ref.watch(settingsNotifierProvider).value ?? const AppSettings();

    Widget toggleRow({
      required String title,
      required String subtitle,
      required bool value,
      required ValueChanged<bool>? onChanged,
    }) {
      return ExpressiveCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textLight(context),
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              activeThumbColor: AppTheme.accent(context),
              onChanged: onChanged,
            ),
          ],
        ),
      );
    }

    return ExpressivePage(
      title: Platform.isMacOS ? 'macOS' : l10n.settingsDesktopTitle,
      physics: const ClampingScrollPhysics(),
      children: [
        toggleRow(
          title: l10n.settingsMinimizeToTray,
          subtitle: l10n.settingsMinimizeToTrayHint,
          value: settings.minimizeToTray,
          onChanged: (v) => _save(ref, settings.copyWith(minimizeToTray: v)),
        ),
        const SizedBox(height: 12),
        toggleRow(
          title: Platform.isMacOS
              ? l10n.macosLaunchAtLogin
              : l10n.settingsLaunchAtStartup,
          subtitle: l10n.settingsLaunchAtStartupHint,
          value: settings.launchAtStartup,
          onChanged: (v) => _save(ref, settings.copyWith(launchAtStartup: v)),
        ),
        const SizedBox(height: 12),
        toggleRow(
          title: Platform.isMacOS
              ? l10n.macosAutoConnectOnLogin
              : l10n.settingsAutoConnectOnAutostart,
          subtitle: Platform.isMacOS
              ? l10n.macosAutoConnectOnLoginHint
              : l10n.settingsAutoConnectOnAutostartHint,
          value: settings.autoConnectLastServer,
          onChanged: settings.launchAtStartup
              ? (v) => _save(ref, settings.copyWith(autoConnectLastServer: v))
              : null,
        ),
        if (!settings.launchAtStartup)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
            child: Text(
              Platform.isMacOS
                  ? l10n.macosAutoConnectRequiresLogin
                  : l10n.settingsAutoConnectRequiresAutostart,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textLight(context),
              ),
            ),
          ),
      ],
    );
  }
}
