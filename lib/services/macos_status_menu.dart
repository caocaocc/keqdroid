import '../l10n/app_localizations.dart';
import '../models/server_item.dart';
import '../tunnel/connection_mode.dart';
import '../tunnel/tunnel_state.dart';
import 'macos_status_item.dart';

bool macOSMenuToggleMatches(VpnStatus status, String? intent) =>
    switch (status) {
      VpnStatus.connected || VpnStatus.connecting => intent == 'disconnect',
      VpnStatus.disconnected || VpnStatus.error => intent == 'connect',
      VpnStatus.disconnecting => false,
    };

/// The macOS menu follows the existing Windows grouping and connection actions.
Map<String, Object> buildMacOSStatusMenu({
  required AppLocalizations labels,
  required VpnStatus status,
  required ConnectionMode mode,
  required List<ServerItem> servers,
  required String? activeId,
  required Map<String, String> subscriptionNames,
  bool operationBusy = false,
  String? statusText,
}) {
  final busy =
      operationBusy ||
      status == VpnStatus.connecting ||
      status == VpnStatus.disconnecting;
  final active = servers.where((s) => s.id == activeId).firstOrNull;
  final connected =
      status == VpnStatus.connected || status == VpnStatus.connecting;
  final manual = <ServerItem>[];
  final subscriptions = <String, List<ServerItem>>{};
  for (final server in servers) {
    final id = server.subscriptionId;
    if (id == null || id.isEmpty) {
      manual.add(server);
    } else {
      (subscriptions[id] ??= []).add(server);
    }
  }
  String groupTitle(String id) {
    final title = subscriptionNames[id]?.trim() ?? '';
    if (title.isNotEmpty) return title;
    final fallback = subscriptions[id]!.first.subscriptionName?.trim() ?? '';
    return fallback.isEmpty ? labels.subscriptionsTitle : fallback;
  }

  final ids = subscriptions.keys.toList()
    ..sort(
      (a, b) =>
          groupTitle(a).toLowerCase().compareTo(groupTitle(b).toLowerCase()),
    );
  final groups = <(String, List<ServerItem>)>[
    if (manual.isNotEmpty) (labels.serversManualServers, manual),
    for (final id in ids) (groupTitle(id), subscriptions[id]!),
  ];
  List<Map<String, Object>> entries(List<ServerItem> list) {
    final sorted = [...list]
      ..sort(
        (a, b) =>
            a.cleanName.toLowerCase().compareTo(b.cleanName.toLowerCase()),
      );
    return _chunk([
      for (final server in sorted)
        {
          'title': _title(server.cleanName),
          'id': server.id,
          'checked': server.id == activeId,
        },
    ]);
  }

  final tree = groups.length <= 1
      ? entries(groups.isEmpty ? const [] : groups.first.$2)
      : _chunk([
          for (final (name, list) in groups)
            {'title': _title(name), 'children': entries(list)},
        ]);
  var count = 0;
  bool fits(List<Map<String, Object>> nodes, [int depth = 1]) {
    if (depth > 8) return false;
    for (final node in nodes) {
      if (++count > 12000) return false;
      final children = node['children'];
      if (children is List<Map<String, Object>>) {
        if (!fits(children, depth + 1)) return false;
      } else {
        final id = node['id']! as String;
        if (id.isEmpty ||
            id.runes.length > 256 ||
            RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(id)) {
          return false;
        }
      }
    }
    return true;
  }

  final overflow = !fits(tree);
  return {
    'statusText': _title(statusText ?? macOSConnectionLabel(labels, status)),
    'toggleText': connected ? labels.trayDisconnect : labels.trayConnect,
    'toggleConnects': !connected,
    // Starting a connection must never disable the action that cancels it.
    'toggleEnabled':
        status == VpnStatus.connecting ||
        (!operationBusy &&
            status != VpnStatus.disconnecting &&
            (connected || active != null)),
    'mode': mode.storageValue,
    'modeEnabled': !busy,
    'proxyText': labels.trayModeProxy,
    'tunText': labels.trayModeTun,
    'serversTitle': overflow
        ? labels.macosMenuOpenServers
        : _title(active?.cleanName ?? labels.trayPickServer),
    'serversEnabled': !busy && servers.isNotEmpty,
    'servers': overflow ? <Map<String, Object>>[] : tree,
    'serversOverflow': overflow,
    'openText': labels.trayOpenApp,
    'quitText': labels.trayExit,
  };
}

String _title(String value, [int limit = 100]) {
  final text = value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]'), ' ')
      .trim();
  if (text.isEmpty) return '—';
  return text.runes.length <= limit
      ? text
      : '${String.fromCharCodes(text.runes.take(limit - 1))}…';
}

List<Map<String, Object>> _chunk(List<Map<String, Object>> entries) {
  if (entries.length <= 24) return entries;
  final result = <Map<String, Object>>[];
  for (var i = 0; i < entries.length; i += 24) {
    final part = entries.skip(i).take(24).toList();
    result.add({
      'title':
          '${_title(part.first['title']! as String, 14)} … '
          '${_title(part.last['title']! as String, 14)}',
      'children': part,
    });
  }
  return _chunk(result);
}
