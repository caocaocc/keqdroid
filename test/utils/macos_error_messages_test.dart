import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/core/exceptions.dart';
import 'package:keqdroid/l10n/app_localizations_zh.dart';
import 'package:keqdroid/utils/error_messages.dart';

void main() {
  const nativeMessage = 'Core, tunnel, or TCP/UDP DNS readiness timed out.';
  PlatformException readinessFailure() => PlatformException(
    code: 'readinessTimeout',
    message: nativeMessage,
    details: {
      'method': 'startSession',
      'serviceCode': 'readinessTimeout',
      'stage': 'virtualDNS',
    },
  );

  test(
    'native readiness failure preserves cause and stage for object or state string',
    () {
      final failure = readinessFailure();
      final wrapped = VpnStartException(failure.toString(), cause: failure);
      for (final error in [
        failure,
        failure.toString(),
        wrapped,
        wrapped.toString(),
      ]) {
        final described = explainErrorLocalized(error, AppLocalizationsZh());
        expect(described.code, UiErrorCode.unknown);
        expect(
          described.message,
          '$nativeMessage\n[readinessTimeout · virtualDNS]',
        );
        expect(described.message, isNot(contains('目前无法连接服务器')));
        expect(described.message, isNot(contains('PlatformException')));
      }
    },
  );

  test(
    'legacy macos_network timeout still displays its actual service failure',
    () {
      final failure = PlatformException(
        code: 'macos_network',
        message: 'Network service request timed out.',
      );
      for (final error in [failure, failure.toString()]) {
        final described = explainError(error);
        expect(described.code, UiErrorCode.unknown);
        expect(
          described.message,
          'Network service request timed out.\n[macos_network]',
        );
      }
    },
  );

  test('polling failure prefix preserves native timeout provenance', () {
    const prefix = 'The macOS network service is unavailable: ';
    final failure = PlatformException(
      code: 'timeout',
      message: 'Network service request timed out.',
      details: {'serviceCode': 'timeout', 'method': 'getSession'},
    );
    expect(
      explainErrorLocalized('$prefix$failure', AppLocalizationsZh()).message,
      'Network service request timed out.\n[timeout · getSession]',
    );
    final legacy = PlatformException(
      code: 'macos_network',
      message: 'Network service request timed out.',
    );
    expect(
      explainError('$prefix$legacy').message,
      'Network service request timed out.\n[macos_network]',
    );
    for (final error in [
      'A different service is unavailable: $failure',
      '${prefix}Connection timed out',
      '$prefix${PlatformException(code: 'timeout', message: 'Request timed out.', details: {'serviceCode': 'different', 'method': 'getSession'})}',
    ]) {
      expect(explainError(error).code, UiErrorCode.network);
      expect(
        explainErrorLocalized(error, AppLocalizationsZh()).message,
        AppLocalizationsZh().errorNetworkMessage,
      );
    }
  });

  test(
    'native early errors retain method when no startup stage is available',
    () {
      final failure = PlatformException(
        code: 'vpnRouteConflict',
        message:
            'Another VPN routes IPv4 traffic through utun6. Disconnect that VPN before enabling TUN.',
        details: {
          'serviceCode': 'vpnRouteConflict',
          'method': 'prepareNetworkContext',
        },
      );
      for (final error in [failure, failure.toString()]) {
        expect(
          explainError(error).message,
          endsWith('[vpnRouteConflict · prepareNetworkContext]'),
        );
      }
    },
  );

  test(
    'generic and other platform network errors keep existing localization',
    () {
      final l10n = AppLocalizationsZh();
      for (final error in [
        const SocketException('Connection timed out'),
        const SocketException('Connection timed out').toString(),
        const RequestTimeoutException('request expired'),
        PlatformException(code: 'readinessTimeout', message: nativeMessage),
        PlatformException(
          code: 'windows_network',
          message: nativeMessage,
          details: {'method': 'startSession'},
        ),
        PlatformException(
          code: 'readinessTimeout',
          message: nativeMessage,
          details: {
            'method': 'unrelatedPluginCall',
            'serviceCode': 'readinessTimeout',
          },
        ),
      ]) {
        final described = explainErrorLocalized(error, l10n);
        expect(described.code, UiErrorCode.network);
        expect(described.message, l10n.errorNetworkMessage);
      }
    },
  );

  test(
    'native diagnostic summary omits stacktrace and trailing core log lines',
    () {
      final failure = PlatformException(
        code: 'coreExited',
        message: 'keqrnel exited during startup.\nextra core log',
        details: {
          'method': 'startSession',
          'serviceCode': 'coreExited',
          'stage': 'localEndpoints',
        },
        stacktrace: 'native frame',
      );
      for (final error in [failure, failure.toString()]) {
        expect(
          explainError(error).message,
          'keqrnel exited during startup.\n[coreExited · localEndpoints]',
        );
      }
    },
  );
}
