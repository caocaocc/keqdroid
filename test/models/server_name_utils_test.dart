import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/server_name_utils.dart';

void main() {
  group('ServerNameUtils.extractCountryCode', () {
    test('extracts country code from regional indicator flag emoji', () {
      expect(ServerNameUtils.extractCountryCode('🇩🇪 Germany 01'), 'DE');
      expect(ServerNameUtils.extractCountryCode('🇺🇸 US node'), 'US');
    });

    test('does not fabricate a flag from unrelated words', () {
      // Регресс: "cloudflARE" содержит "are" (ARE=ОАЭ) → раньше ложный флаг 🇦🇪.
      expect(ServerNameUtils.extractCountryCode('Cloudflare Warp-1'), isNull);
      expect(ServerNameUtils.extractCountryCode('Cloudflare Warp'), isNull);
      // "southamPTon" → "pt", "united kiNGdom" → "ng" — тоже больше не ловятся.
      expect(ServerNameUtils.extractCountryCode('Southampton'), isNull);
      expect(ServerNameUtils.extractCountryCode('United Kingdom'), isNot('NG'));
    });

    test('resolves real country names and codes as whole words', () {
      expect(ServerNameUtils.extractCountryCode('Estonia | 2 | HY2'), 'EE');
      expect(ServerNameUtils.extractCountryCode('Germany-Frankfurt'), 'DE');
      expect(ServerNameUtils.extractCountryCode('US-NYC'), 'US');
      expect(ServerNameUtils.extractCountryCode('Россия 1'), 'RU');
      expect(ServerNameUtils.extractCountryCode('Hong Kong 01'), 'HK');
    });

    test(
      'recognizes Chinese names without whitespace and traditional forms',
      () {
        for (final entry in {
          '香港高速01': 'HK',
          '中国香港 01': 'HK',
          '中國香港 01': 'HK',
          '台湾专线': 'TW',
          '臺灣專線': 'TW',
          '澳門 01': 'MO',
          '新加坡01': 'SG',
          '日本东京': 'JP',
          '美国洛杉矶': 'US',
          '美國洛杉磯': 'US',
          '英国01': 'GB',
          '德國 02': 'DE',
          '韩国01': 'KR',
          '加拿大01': 'CA',
          '中国01': 'CN',
        }.entries) {
          expect(
            ServerNameUtils.extractCountryCode(entry.key),
            entry.value,
            reason: entry.key,
          );
        }
      },
    );

    test('explicit names take priority over ambiguous route codes', () {
      expect(ServerNameUtils.extractCountryCode('CN2 香港 01'), 'HK');
      expect(ServerNameUtils.extractCountryCode('CN2 Japan 01'), 'JP');
      expect(ServerNameUtils.extractCountryCode('香港 CN2'), 'HK');
      expect(ServerNameUtils.extractCountryCode('CN2 专线'), isNull);
      expect(ServerNameUtils.extractCountryCode('🇺🇸 香港 CN2'), 'US');
    });

    test('does not join letters across punctuation or internal digits', () {
      for (final name in [
        'S.G relay',
        'C1N relay',
        'u.s.test',
        'i.r.example',
        'node.jp.example',
        'sg.example',
      ]) {
        expect(ServerNameUtils.extractCountryCode(name), isNull, reason: name);
      }
      expect(ServerNameUtils.extractCountryCode('[HK01]'), 'HK');
      expect(ServerNameUtils.extractCountryCode('JP2 | relay'), 'JP');
      expect(ServerNameUtils.extractCountryCode('Germany. 01'), 'DE');
    });

    test('matches complete multiword country names with word boundaries', () {
      expect(ServerNameUtils.extractCountryCode('United Kingdom'), 'GB');
      expect(ServerNameUtils.extractCountryCode('[Hong-Kong] 01'), 'HK');
      expect(ServerNameUtils.extractCountryCode('New Zealander'), isNull);
      expect(ServerNameUtils.extractCountryCode('NotHong Kong'), isNull);
    });
  });
}
