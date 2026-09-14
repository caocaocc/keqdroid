import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/platform/desktop_lan_state.dart';
import 'package:keqdroid/tunnel/local_port_plan.dart';

void main() {
  test(
    'confirmed LAN snapshot carries only actual ports and IPv4 addresses',
    () {
      final state = DesktopLanState.fromSnapshot({
        'socksPort': 11080,
        'httpPort': 18080,
        'addresses': [
          '192.168.1.8',
          '192.168.1.8',
          '10.0.0.8',
          '127.0.0.1',
          '172.19.0.1',
          '198.18.0.1',
          '::1',
          'bad',
        ],
        'password': 'ignored-synthetic-password',
      })!;
      expect(state.addresses, ['192.168.1.8', '10.0.0.8']);
      expect(state.socksPort, 11080);
      expect(state.httpPort, 18080);
      expect(() => state.addresses.add('192.168.1.9'), throwsUnsupportedError);
      expect(DesktopLanState.fromSnapshot(null), isNull);
      for (final ports in [(80, 8080), (1080, 1080), (1080, 65536)]) {
        expect(
          DesktopLanState.fromSnapshot({
            'socksPort': ports.$1,
            'httpPort': ports.$2,
          }),
          isNull,
        );
      }
    },
  );
  test('macOS address display excludes virtual network interfaces', () {
    final addresses = DesktopLanState.physicalAddresses([
      (name: 'utun8', addresses: ['10.1.0.2']),
      (name: 'en0', addresses: ['192.168.1.2']),
      (name: 'bridge0', addresses: ['172.20.0.2']),
      (name: 'lo0', addresses: ['127.0.0.1']),
      (name: 'vlan0', addresses: ['192.168.1.2', '10.0.0.2']),
      (name: 'wg0', addresses: ['10.8.0.2']),
    ], macos: true);
    expect(addresses, ['192.168.1.2', '172.20.0.2', '10.0.0.2']);
  });
  test('actual LAN ports clear with the active connection', () {
    final ports = ActiveLocalPorts()..clear();
    addTearDown(ports.clear);
    ports.set(
      socksPort: 2080,
      httpPort: 2081,
      lanSocksPort: 11080,
      lanHttpPort: 18080,
    );
    expect(ports.lanSocksPort, 11080);
    expect(ports.lanHttpPort, 18080);
    ports.set(socksPort: 2080, httpPort: 2081);
    expect(ports.lanSocksPort, isNull);
    ports.set(
      socksPort: 2080,
      httpPort: 2081,
      lanSocksPort: 11080,
      lanHttpPort: 18080,
    );
    ports.clear();
    expect(ports.lanHttpPort, isNull);
  });
}
