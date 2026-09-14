import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/app_settings.dart';
import '../../providers/providers.dart';
import '../../services/vpn_engine.dart';
import '../../services/windows_desktop_service.dart';
import '../../shared/ui/app_theme.dart';
import '../../utils/error_messages.dart';

// у Ref и WidgetRef нет общего предка, а меню трея знает только Ref, поэтому зависимости явно
class DesktopModeDeps {
  const DesktopModeDeps({
    required this.vpn,
    required this.settings,
    required this.status,
  });

  final VpnStateNotifier vpn;
  final SettingsNotifier settings;

  // функцией: статус перечитывается после await
  final VpnStatus? Function() status;

  factory DesktopModeDeps.of(WidgetRef ref) => DesktopModeDeps(
        vpn: ref.read(vpnStateProvider.notifier),
        settings: ref.read(settingsNotifierProvider.notifier),
        status: () => ref.read(vpnStateProvider).value?.status,
      );

  factory DesktopModeDeps.ofRef(Ref ref) => DesktopModeDeps(
        vpn: ref.read(vpnStateProvider.notifier),
        settings: ref.read(settingsNotifierProvider.notifier),
        status: () => ref.read(vpnStateProvider).value?.status,
      );
}

Future<void> applyDesktopConnectionMode(
  BuildContext context,
  DesktopModeDeps deps,
  AppSettings settings,
  ConnectionMode next,
) async {
  if (next == settings.connectionModeEnum) return;
  final wasActive = deps.vpn.hasConnectionIntent;
  var generation = deps.vpn.connectionGeneration;
  bool current() => deps.vpn.isConnectionChangeCurrent(generation);

  // на Linux права даёт pkexec при подключении, перезапуск с админом нужен только Windows
  if (next == ConnectionMode.tun && Platform.isWindows) {
    final elevated = await WindowsDesktopService.isProcessElevated();
    if (!current()) return;
    if (!elevated) {
      if (!context.mounted) return;
      final restart = await showDesktopTunAdminDialog(context);
      if (restart != true || !current()) return;

      generation = deps.vpn.beginConnectionChange();
      final stopping = stopSessionBeforeElevation(
        notifier: deps.vpn,
        status: deps.status(),
      );
      generation = deps.vpn.connectionGeneration;
      await stopping;
      if (!current()) return;
      await deps.settings.save(
        settings.copyWith(
          connectionMode: ConnectionMode.tun.storageValue,
          connectionModeChosen: true,
        ),
      );
      if (!current()) return;
      final ok = await WindowsDesktopService.restartAsAdministrator();
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.desktopTunAdminRestartFailed,
            ),
          ),
        );
      }
      return;
    }
  }

  if (!current()) return;
  generation = deps.vpn.beginConnectionChange();
  Future<void> saveMode() => deps.settings.save(
    settings.copyWith(
      connectionMode: next.storageValue,
      connectionModeChosen: true,
    ),
  );
  if (!wasActive) {
    await saveMode();
    return;
  }
  try {
    await deps.vpn.reconnectToActiveServer(
      expectedGeneration: generation,
      afterDisconnect: saveMode,
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyError(e, context))));
    }
  }
}

// перезапуск с правами просто зовёт PostQuitMessage: без остановки ядро жило дальше,
// а системный прокси смотрел на порт, который вот-вот исчезнет
Future<void> stopSessionBeforeElevation({
  required VpnStateNotifier notifier,
  required VpnStatus? status,
}) async {
  if (status != VpnStatus.connected && status != VpnStatus.connecting) return;
  try {
    await notifier.disconnect();
  } catch (_) {}
}

Future<bool?> showDesktopTunAdminDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.card(ctx),
      title: Text(
        l10n.desktopTunAdminTitle,
        style: TextStyle(color: AppTheme.text(ctx)),
      ),
      content: Text(
        l10n.desktopTunAdminMessage,
        style: TextStyle(
          color: AppTheme.textLight(ctx),
          height: 1.4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.desktopTunAdminCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.desktopTunAdminRestart),
        ),
      ],
    ),
  );
}
