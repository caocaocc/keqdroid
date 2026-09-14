import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/tunnel/app_routing_mode.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';

import '../helpers/singbox_route.dart';

// Preserve the saved-settings baseline; this suite does not test China DNS.
final _legacySettings = AppSettings.fromJson({});

String _routeFinal(String json) => effectiveRouteFinal(json);

String _gen(AppSettings settings,
        {AppRoutingMode routingMode = AppRoutingMode.allProxy}) =>
    SingBoxTunConfigGen.generate(
      localSocksPort: 10808,
      socksUsername: 'u',
      socksPassword: 'p',
      serverIpToExclude: '1.2.3.4',
      settings: settings,
      routingMode: routingMode,
    );

void main() {
  group('SingBoxTunConfigGen route.final', () {
    test('allProxy + proxy → final proxy', () {
      expect(_routeFinal(_gen(_legacySettings)), 'proxy');
    });

    test('allProxy + direct → final direct (bypass)', () {
      expect(
        _routeFinal(_gen(
            _legacySettings.copyWith(finalOutbound: AppSettings.finalOutboundDirect))),
        'direct',
      );
    });

    test('allProxy + block → final block', () {
      expect(
        _routeFinal(_gen(
            _legacySettings.copyWith(finalOutbound: AppSettings.finalOutboundBlock))),
        'block',
      );
    });

    test('onlySelected split keeps final direct regardless of finalOutbound',
        () {
      final json = _gen(
        _legacySettings.copyWith(finalOutbound: AppSettings.finalOutboundProxy),
        routingMode: AppRoutingMode.onlySelected,
      );
      expect(_routeFinal(json), 'direct');
    });

    test('allExceptSelected split keeps final proxy (per-app mode governs)', () {
      final json = _gen(
        _legacySettings.copyWith(finalOutbound: AppSettings.finalOutboundDirect),
        routingMode: AppRoutingMode.allExceptSelected,
      );
      expect(_routeFinal(json), 'proxy');
    });
  });
}
