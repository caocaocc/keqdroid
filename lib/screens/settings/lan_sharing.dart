part of '../settings_tab.dart';

class _LanSharingCard extends ConsumerStatefulWidget {
  final AsyncValue<AppSettings> settingsAsync;
  const _LanSharingCard({required this.settingsAsync});

  @override
  ConsumerState<_LanSharingCard> createState() => _LanSharingCardState();
}

class _LanSharingCardState extends ConsumerState<_LanSharingCard> {
  List<String> _localIps = const [];
  late TextEditingController _socksCtrl;
  late TextEditingController _httpCtrl;
  late TextEditingController _userCtrl;
  late TextEditingController _passCtrl;
  bool _lanPassVisible = false;

  @override
  void initState() {
    super.initState();
    final s = widget.settingsAsync.value ?? const AppSettings();
    _socksCtrl = TextEditingController(text: s.lanSocksPort.toString());
    _httpCtrl = TextEditingController(text: s.lanHttpPort.toString());
    _userCtrl = TextEditingController(text: s.lanUsername);
    _passCtrl = TextEditingController(text: s.lanPassword);
    _fetchLocalIp();
    desktopLanState.addListener(_runtimeChanged);
  }

  @override
  void dispose() {
    desktopLanState.removeListener(_runtimeChanged);
    _socksCtrl.dispose();
    _httpCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _runtimeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _fetchLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = DesktopLanState.physicalAddresses(
        interfaces.map((i) => (name: i.name, addresses: i.addresses.map((a) => a.address).toList())),
        macos: Platform.isMacOS,
      );
      if (mounted) setState(() => _localIps = addresses);
    } catch (_) {}
  }

  Future<void> _saveSettings(
    AppSettings current, {
    bool? lanSharing,
    int? socksPort,
    int? httpPort,
    String? username,
    String? password,
  }) async {
    await ref.read(settingsNotifierProvider.notifier).save(current.copyWith(
      lanSharing: lanSharing,
      lanSocksPort: socksPort,
      lanHttpPort: httpPort,
      lanUsername: username,
      lanPassword: password,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final settings = widget.settingsAsync.value ?? const AppSettings();
    final isLan = settings.lanSharing;
    final status = ref.watch(vpnStateProvider.select((a) => a.value?.status));
    final isConnected = status == VpnStatus.connected ||
        status == VpnStatus.connecting || status == VpnStatus.disconnecting;
    final canEdit = Platform.isMacOS || !isConnected;
    final runtime = Platform.isMacOS ? desktopLanState.value : null;
    final sharing = status == VpnStatus.connected &&
        (Platform.isMacOS ? runtime != null : isLan);
    final addresses = runtime?.addresses ?? _localIps;
    final ip = addresses.isEmpty ? '...' : addresses.join('\n');
    final socksPort = sharing
        ? runtime?.socksPort ?? ActiveLocalPorts().lanSocksPort ?? settings.lanSocksPort
        : settings.lanSocksPort;
    final httpPort = sharing
        ? runtime?.httpPort ?? ActiveLocalPorts().lanHttpPort ?? settings.lanHttpPort
        : settings.lanHttpPort;

    // Включённое состояние показываем цветом иконки-контейнера, а не рамкой:
    // у M3E `tertiary` — это ровно роль «обратите внимание, тут что-то
    // изменилось», а группа сама держит форму сегмента.
    final iconAccent =
        isLan ? ExpressiveAccent.tertiary : ExpressiveAccent.secondary;

    return ExpressiveGroupTile(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExpressiveIconBadge(
                icon: Icons.lan_rounded,
                accent: iconAccent,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.settingsLanProxyTitle,
                        style: textTheme.titleMedium?.copyWith(color: AppTheme.text(context))),
                    Text(
                      sharing ? l10n.settingsLanSharingOnIp(addresses.join(', '))
                          : !isLan ? l10n.settingsOff
                          : status == VpnStatus.connecting ? l10n.vpnConnecting : l10n.trayStatusDisconnected,
                      style: textTheme.bodyMedium?.copyWith(
                        color: isLan ? AppTheme.accent(context) : AppTheme.textLight(context),
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: isLan,
                activeThumbColor: AppTheme.accent(context),
                onChanged: canEdit ? (_) => _saveSettings(settings, lanSharing: !isLan) : null,
              ),
            ],
          ),
          if (isLan || sharing) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.inset(context),
                borderRadius: BorderRadius.circular(ExpressiveShape.medium),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.settingsDeviceIpListTitle,
                      style: textTheme.bodySmall?.copyWith(color: AppTheme.textLight(context))),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(child: Text(
                        ip,
                        style: textTheme.titleMedium?.copyWith(
                          fontFamily: 'monospace',
                          color: AppTheme.text(context),
                        ),
                      )),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: ip));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.settingsIpCopied), duration: const Duration(seconds: 1)),
                          );
                        },
                        child: Icon(Icons.copy_rounded, size: 16, color: AppTheme.textLight(context)),
                      ),
                      IconButton(
                        tooltip: l10n.settingsRefresh,
                        onPressed: _fetchLocalIp,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(l10n.settingsSetupAnotherDeviceTitle,
                      style: textTheme.bodySmall?.copyWith(color: AppTheme.textLight(context))),
                  const SizedBox(height: 4),
                  for (final address in addresses.isEmpty ? ['...'] : addresses) ...[
                    _proxyLine(context, 'SOCKS5', address, socksPort),
                    const SizedBox(height: 2),
                    _proxyLine(context, 'HTTP', address, httpPort),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _portField(context, l10n.settingsSocks5PortLabel, _socksCtrl, (v) {
                    final port = int.tryParse(v);
                    if (port != null && port > 0 && port < 65536) {
                      _saveSettings(settings, socksPort: port);
                    }
                  }, enabled: canEdit),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _portField(context, l10n.settingsHttpPortLabel, _httpCtrl, (v) {
                    final port = int.tryParse(v);
                    if (port != null && port > 0 && port < 65536) {
                      _saveSettings(settings, httpPort: port);
                    }
                  }, enabled: canEdit),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _textField(
                    context,
                    l10n.settingsLanUsernameLabel,
                    _userCtrl,
                    (v) => _saveSettings(settings, username: v.trim()),
                    enabled: canEdit,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _textField(
                    context,
                    l10n.settingsLanPasswordLabel,
                    _passCtrl,
                    (v) => _saveSettings(settings, password: v),
                    obscurable: true,
                    enabled: canEdit,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.settingsLanAuthHint,
              style: textTheme.bodySmall?.copyWith(color: AppTheme.textLight(context)),
            ),
          ],
          if (isConnected && !Platform.isMacOS && isLan)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(l10n.settingsTurnOffToChange,
                  style: textTheme.bodySmall?.copyWith(color: AppTheme.orange(context))),
            ),
        ],
      ),
    );
  }

  Widget _proxyLine(BuildContext context, String label, String ip, int port) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final text = '$ip:$port';
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(label,
              style: textTheme.labelSmall?.copyWith(color: AppTheme.textLight(context))),
        ),
        Expanded(
          child: Text(
            text,
            style: textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w500,
              color: AppTheme.text(context),
            ),
          ),
        ),
        InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.settingsProxyCopied(label, text)), duration: const Duration(seconds: 1)),
            );
          },
          child: Icon(Icons.copy_rounded, size: 14, color: AppTheme.textLight(context)),
        ),
      ],
    );
  }

  Widget _textField(BuildContext context, String label, TextEditingController ctrl, ValueChanged<String> onSubmit, {bool obscurable = false, bool enabled = true}) {
    return TextField(
      enabled: enabled,
      controller: ctrl,
      obscureText: obscurable && !_lanPassVisible,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.text(context)),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:
            Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textLight(context)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(ExpressiveShape.medium)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ExpressiveShape.medium),
          borderSide: BorderSide(color: AppTheme.textLight(context).withValues(alpha: 0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ExpressiveShape.medium),
          borderSide: BorderSide(color: AppTheme.accent(context)),
        ),
        suffixIcon: obscurable
            ? IconButton(
                icon: Icon(
                  _lanPassVisible ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                  size: 18,
                  color: AppTheme.textLight(context),
                ),
                onPressed: () => setState(() => _lanPassVisible = !_lanPassVisible),
              )
            : null,
        isDense: true,
      ),
      onSubmitted: onSubmit,
      onEditingComplete: () => onSubmit(ctrl.text),
    );
  }

  Widget _portField(BuildContext context, String label, TextEditingController ctrl, ValueChanged<String> onSubmit, {bool enabled = true}) {
    return TextField(
      enabled: enabled,
      controller: ctrl,
      keyboardType: TextInputType.number,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.text(context)),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:
            Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textLight(context)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(ExpressiveShape.medium)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ExpressiveShape.medium),
          borderSide: BorderSide(color: AppTheme.textLight(context).withValues(alpha: 0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ExpressiveShape.medium),
          borderSide: BorderSide(color: AppTheme.accent(context)),
        ),
        isDense: true,
      ),
      onSubmitted: onSubmit,
      onEditingComplete: () => onSubmit(ctrl.text),
    );
  }
}
