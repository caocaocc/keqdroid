import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';

// Preserve the saved-settings baseline; this suite does not test China DNS.
final _legacySettings = AppSettings.fromJson({});

// Darwin chooses a free utun interface for each session.
void main() {
  test('macOS leaves utun interface allocation to the core', () {
    final config =
        jsonDecode(
              SingBoxTunConfigGen.generate(
                localSocksPort: 2080,
                socksUsername: 'u',
                socksPassword: 'p',
                serverIpToExclude: '203.0.113.10',
                settings: _legacySettings,
              ),
            )
            as Map<String, dynamic>;

    final tun = (config['inbounds'] as List).first as Map<String, dynamic>;
    expect(tun['type'], 'tun');
    expect(tun.containsKey('interface_name'), isFalse);
  });
}
