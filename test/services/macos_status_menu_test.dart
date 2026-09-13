import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations_en.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/services/macos_status_menu.dart';
import 'package:keqdroid/tunnel/connection_mode.dart';
import 'package:keqdroid/tunnel/tunnel_state.dart';

void main() {
  final labels = AppLocalizationsEn();
  ServerItem server(String id, String name, [String? sub]) => ServerItem(
    id: id,
    config: 'private-config-never-sent',
    customName: name,
    subscriptionId: sub,
    type: sub == null ? ServerItemType.manual : ServerItemType.subscription,
  );
  Map<String, Object> menu(
    List<ServerItem> servers, {
    VpnStatus status = VpnStatus.disconnected,
    String? active = 'a',
    bool busy = false,
  }) => buildMacOSStatusMenu(
    labels: labels,
    status: status,
    mode: ConnectionMode.tun,
    servers: servers,
    activeId: active,
    subscriptionNames: {'sub': 'Subscription'},
    operationBusy: busy,
  );

  test('selection, empty list and transition action availability', () {
    expect(menu([])['toggleEnabled'], false);
    expect(menu([])['serversEnabled'], false);
    final servers = [server('a', 'A')];
    expect(menu(servers)['toggleEnabled'], true);
    final starting = menu(servers, status: VpnStatus.connecting, busy: true);
    expect(starting['toggleText'], labels.trayDisconnect);
    expect(starting['toggleEnabled'], true);
    expect(starting['toggleConnects'], false);
    expect(starting['modeEnabled'], false);
    expect(starting['serversEnabled'], false);
    final stopping = menu(servers, status: VpnStatus.disconnecting);
    expect(stopping['toggleEnabled'], false);
    expect(stopping['serversEnabled'], false);
    expect(menu(servers, status: VpnStatus.connected)['modeEnabled'], true);
  });

  test('stale menu intention cannot turn disconnect into a new connection', () {
    expect(macOSMenuToggleMatches(VpnStatus.disconnected, 'disconnect'), false);
    expect(macOSMenuToggleMatches(VpnStatus.connected, 'connect'), false);
    expect(macOSMenuToggleMatches(VpnStatus.connecting, 'disconnect'), true);
    expect(macOSMenuToggleMatches(VpnStatus.disconnecting, 'connect'), false);
    expect(macOSMenuToggleMatches(VpnStatus.error, 'connect'), true);
    expect(macOSMenuToggleMatches(VpnStatus.disconnected, null), false);
  });

  test(
    'grouped nodes preserve checks, sorted titles and exclude configuration',
    () {
      final result = menu([
        server('b', 'Zulu', 'sub'),
        server('a', 'Alpha'),
        server('c', 'Beta', 'sub'),
      ]);
      final groups = result['servers']! as List<Map<String, Object>>;
      expect(groups.first['title'], labels.serversManualServers);
      final manual = groups.first['children']! as List<Map<String, Object>>;
      expect(manual.single['checked'], true);
      final subscribed = groups.last['children']! as List<Map<String, Object>>;
      expect(subscribed.map((s) => s['title']), ['Beta', 'Zulu']);
      expect(jsonEncode(result), isNot(contains('private-config-never-sent')));
      expect(result['mode'], 'tun');
    },
  );

  test('large and hostile labels stay bounded and selectable', () {
    final servers = List.generate(
      1000,
      (i) => server('$i', '${i.toString().padLeft(4, '0')} Node'),
    );
    servers.add(server('last', 'Bad\nname\t${'a' * 200}'));
    final tree = menu(servers)['servers']! as List<Map<String, Object>>;
    var leaves = 0;
    void visit(List<Map<String, Object>> nodes) {
      expect(nodes.length, lessThanOrEqualTo(24));
      for (final node in nodes) {
        final title = node['title']! as String;
        expect(title.contains('\n'), false);
        expect(title.runes.length, lessThanOrEqualTo(100));
        if (node['children'] != null) {
          visit(node['children']! as List<Map<String, Object>>);
        } else {
          expect(node['id'], isNotNull);
          leaves++;
        }
      }
    }

    visit(tree);
    expect(leaves, servers.length);
  });

  test(
    'invalid legacy IDs fall back to opening the window, not stale nodes',
    () {
      final result = menu([server('a' * 257, 'Legacy')]);
      expect(result['serversOverflow'], true);
      expect(result['servers'], isEmpty);
      expect(result['serversTitle'], labels.macosMenuOpenServers);
      expect(result['openText'], labels.trayOpenApp);
    },
  );

  test(
    'over-budget subscriptions keep window selection and connection actions',
    () {
      final result = menu(List.generate(12001, (i) => server('$i', 'Node $i')));
      expect(result['serversOverflow'], true);
      expect(result['servers'], isEmpty);
      expect(result['modeEnabled'], true);
    },
  );
}
