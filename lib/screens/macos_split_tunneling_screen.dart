import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/macos_app_routing.dart';
import '../providers/providers.dart';
import '../services/macos_app_routing_store.dart';
import '../services/file_dialog_service.dart';
import '../shared/ui/expressive_page.dart';
import '../tunnel/app_routing_mode.dart';
import '../tunnel/connection_mode.dart';

class MacOSSplitTunnelingScreen extends ConsumerStatefulWidget {
  const MacOSSplitTunnelingScreen({super.key});

  @override
  ConsumerState<MacOSSplitTunnelingScreen> createState() =>
      _MacOSSplitTunnelingScreenState();
}

class _MacOSSplitTunnelingScreenState
    extends ConsumerState<MacOSSplitTunnelingScreen> {
  static const _channel = MethodChannel('keqdis_vpn_channel');
  MacOSAppRoutingSettings _settings = const MacOSAppRoutingSettings();
  Map<String, MacOSAppEntry> _installed = {};
  bool _loading = true;
  bool _saving = false;
  bool _showSystem = false;
  String _search = '';
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await MacOSAppRoutingStore.load();
      final raw = await _channel.invokeListMethod<dynamic>('getInstalledApps', {
        'includeSystem': _showSystem,
      });
      final entries = <String, MacOSAppEntry>{};
      for (final map in raw ?? const []) {
        if (map is! Map) continue;
        try {
          final entry = MacOSAppEntry.fromNative(
            Map<String, dynamic>.from(map),
          );
          entries[entry.id] = entry;
        } on FormatException {
          continue;
        }
      }
      if (mounted) {
        setState(() {
          _settings = settings;
          _installed = entries;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(MacOSAppRoutingSettings next) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await MacOSAppRoutingStore.save(next);
      if (mounted) setState(() => _settings = next);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addExecutable() async {
    final selected = await AppFileDialogs.pickFile(
      dialogTitle: AppLocalizations.of(context)!.splitAddAppTitle,
    );
    final path = selected?.path;
    if (path == null || !mounted) return;
    try {
      final stat = await File(path).stat();
      if (!isMacOSExecutablePath(path) ||
          stat.type != FileSystemEntityType.file ||
          stat.mode & 0x49 == 0) {
        throw const FormatException('Select an executable file.');
      }
      final entry = MacOSAppEntry(
        displayName: path.split('/').last,
        executablePath: path,
        executablePaths: [path],
      );
      setState(() => _installed[entry.id] = entry);
      final apps = {
        for (final app in _settings.apps) app.id: app,
        entry.id: entry,
      };
      await _save(
        MacOSAppRoutingSettings(
          mode: _settings.mode,
          apps: apps.values.toList(),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final selected = {for (final app in _settings.apps) app.id: app};
    final combined = {...selected, ..._installed};
    final entries =
        combined.values
            .where(
              (entry) => '${entry.displayName} ${entry.id}'
                  .toLowerCase()
                  .contains(_search.toLowerCase()),
            )
            .toList()
          ..sort((a, b) {
            final selectedOrder =
                (selected.containsKey(b.id) ? 1 : 0) -
                (selected.containsKey(a.id) ? 1 : 0);
            return selectedOrder != 0
                ? selectedOrder
                : a.displayName.toLowerCase().compareTo(
                    b.displayName.toLowerCase(),
                  );
          });
    final proxyMode =
        ref.watch(settingsNotifierProvider).value?.connectionModeEnum ==
        ConnectionMode.proxy;
    return ExpressivePage(
      title: l10n.splitTunnelingTitle,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final mode in AppRoutingMode.values)
              ChoiceChip(
                label: Text(switch (mode) {
                  AppRoutingMode.allProxy => l10n.splitModeAllApps,
                  AppRoutingMode.onlySelected => l10n.splitModeSelectedOnly,
                  AppRoutingMode.allExceptSelected =>
                    l10n.splitModeAllExceptSelected,
                }),
                selected: _settings.mode == mode,
                onSelected: _loading || _saving
                    ? null
                    : (_) => _save(
                        MacOSAppRoutingSettings(
                          mode: mode,
                          apps: _settings.apps,
                        ),
                      ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          proxyMode
              ? l10n.splitProxyModeWarning
              : l10n.splitTunnelingReconnectHint,
        ),
        const SizedBox(height: 8),
        Text(l10n.macosSplitProcessHint),
        const SizedBox(height: 16),
        TextField(
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: l10n.splitSearchHint,
          ),
          onChanged: (value) => setState(() => _search = value),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChip(
              label: Text(l10n.splitShowSystemApps),
              selected: _showSystem,
              onSelected: _loading
                  ? null
                  : (value) {
                      setState(() => _showSystem = value);
                      _load();
                    },
            ),
            TextButton.icon(
              onPressed: _loading || _saving ? null : _addExecutable,
              icon: const Icon(Icons.add),
              label: Text(l10n.splitAddApp),
            ),
            Text(l10n.splitSelectedAppsCount(selected.length)),
          ],
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null)
          ListTile(
            title: Text(l10n.splitFailedLoadApps('$_error')),
            trailing: IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          ),
        if (!_loading && entries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.splitNoAppsFound),
          ),
        if (!_loading)
          ...entries.map(
            (entry) => CheckboxListTile(
              key: ValueKey(entry.id),
              title: Text(entry.displayName),
              subtitle: Text(
                '${entry.bundlePath ?? entry.executablePath}${_installed.containsKey(entry.id) ? '' : '\n${l10n.macosAppNeedsMatching}'}',
              ),
              secondary: _MacOSApplicationIcon(
                path: entry.bundlePath ?? entry.executablePath,
              ),
              value: selected.containsKey(entry.id),
              onChanged: _saving || _settings.mode == AppRoutingMode.allProxy
                  ? null
                  : (checked) {
                      final apps = Map<String, MacOSAppEntry>.of(selected);
                      if (checked == true) {
                        apps[entry.id] = entry;
                      } else {
                        apps.remove(entry.id);
                      }
                      _save(
                        MacOSAppRoutingSettings(
                          mode: _settings.mode,
                          apps: apps.values.toList(),
                        ),
                      );
                    },
            ),
          ),
      ],
    );
  }
}

class _MacOSApplicationIcon extends StatefulWidget {
  const _MacOSApplicationIcon({required this.path});
  final String path;
  @override
  State<_MacOSApplicationIcon> createState() => _MacOSApplicationIconState();
}

class _MacOSApplicationIconState extends State<_MacOSApplicationIcon> {
  late final _icon = const MethodChannel(
    'keqdis_vpn_channel',
  ).invokeMethod<String>('getAppIcon', {'path': widget.path});
  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _icon,
    builder: (context, snapshot) {
      final data = snapshot.data;
      if (data == null) return const Icon(Icons.apps);
      try {
        return Image.memory(base64Decode(data), width: 32, height: 32);
      } on FormatException {
        return const Icon(Icons.apps);
      }
    },
  );
}
