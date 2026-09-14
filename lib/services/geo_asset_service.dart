import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import '../models/app_settings.dart';
import '../tunnel/desktop_core_paths.dart';
import '../utils/geo_asset_index.dart';
import '../utils/geo_dat_reader.dart';
import '../utils/geo_rule_sanitizer.dart';

/// Находит geoip.dat/geosite.dat там же, где их читает ядро, и чистит по ним
/// списки маршрутизации перед генерацией конфига.
class GeoAssetService {
  GeoAssetService._();

  static Future<GeoAssetIndex>? _cached;
  static Future<List<GeoDomain>>? _chinaDns;

  /// Индекс кодов geo-баз. Кэшируется на процесс: файлы едут в сборке и в
  /// рантайме не меняются, а разбор дёргается на каждое подключение.
  static Future<GeoAssetIndex> index() => _cached ??= _load();

  /// Сбросить кэш индекса. Нужен после подмены базы на диске — иначе
  /// санитайзер продолжит судить о правилах по старому списку кодов.
  static void invalidate() {
    _cached = null;
    _chinaDns = null;
  }

  /// Only the CN DNS rule is expanded; routing continues to use geosite.dat.
  /// Missing data must not silently send domestic queries to the other DNS.
  static Future<List<GeoDomain>> chinaDnsDomains() =>
      _chinaDns ??= _loadChinaDnsDomains();

  static Future<List<GeoDomain>> _loadChinaDnsDomains() async {
    final dir = await _geoDir();
    if (dir == null) {
      throw const FormatException('geosite:cn DNS database is unavailable');
    }
    final domains = await GeoDatReader.domains(File('$dir/geosite.dat'), 'cn');
    if (domains.isEmpty) {
      throw const FormatException('geosite:cn DNS data is missing or empty');
    }
    return List.unmodifiable(domains);
  }

  /// Только для тестов: сбросить кэш.
  static void resetCacheForTests() => invalidate();

  static Future<GeoAssetIndex> _load() async {
    try {
      final dir = await _geoDir();
      if (dir == null) return GeoAssetIndex.empty;
      final index = await GeoAssetIndex.fromDirectory(dir);
      AppLogger.instance.debug(
        'Geo assets in $dir: ${index.geoipCodes.length} geoip, '
        '${index.geositeCodes.length} geosite codes',
      );
      return index;
    } catch (e) {
      AppLogger.instance.warn('Geo asset index unavailable: $e');
      return GeoAssetIndex.empty;
    }
  }

  /// Каталог, из которого ядро читает geo-базы. Нужен ещё и панели
  /// «Внутренности» — она показывает размеры и даты этих же файлов.
  static Future<String?> geoDir() => _geoDir();

  static Future<String?> _geoDir() async {
    if (Platform.isAndroid) {
      // Нативная часть распаковывает базы в filesDir (XrayGeoAssets) и туда же
      // указывает ядру XRAY_LOCATION_ASSET; path_provider отдаёт этот каталог.
      return (await getApplicationSupportDirectory()).path;
    }
    if (DesktopCorePaths.supported) return DesktopCorePaths.geoAssetDir();
    return null;
  }

  /// Настройки для генераторов конфига без geo-правил, которых нет в базах.
  /// Выброшенное пишем в лог — правило исчезает из маршрутизации молча, и это
  /// единственный след, по которому можно понять, почему.
  static Future<AppSettings> sanitizeRules(AppSettings settings) async {
    final assets = await index();
    requireChinaRules(settings, assets);
    final result = stripUnknownGeoTokens(settings, assets);
    if (result.dropped.isNotEmpty) {
      // Отдельная подсказка про урезанную базу: «правило исчезло» и «страны в
      // базе нет, её надо догрузить» — разные диагнозы, а выглядят одинаково.
      final trimmedBase =
          !assets.hasFullGeoip &&
          result.dropped.any((t) => t.toLowerCase().startsWith('geoip:'));
      AppLogger.instance.warn(
        'Routing rules: dropped ${result.dropped.length} geo entries missing '
        'from the bundled geoip/geosite databases (they would abort the core '
        'at config load): ${result.dropped.join(', ')}'
        '${trimmedBase ? ' — the bundled country database is the trimmed one; '
                  'download the full base in Settings -> About -> Internals' : ''}',
      );
    }
    return result.settings;
  }

  /// The China preset must never degrade silently on any core or platform.
  /// Other unknown geo rules retain the existing sanitizer behavior.
  static void requireChinaRules(AppSettings settings, GeoAssetIndex assets) {
    final missing = <String>{};
    for (final raw in [settings.directRules, settings.proxyRules, settings.blockedRules]) {
      for (final token in raw.split(RegExp(r'[\r\n,]+'))) {
        final match = RegExp(r'^(geoip|geosite):!?cn(?:@.*)?$')
            .firstMatch(token.trim().toLowerCase());
        if (match == null) continue;
        final kind = match.group(1)!;
        final codes = kind == 'geoip' ? assets.geoipCodes : assets.geositeCodes;
        if (!codes.contains('cn')) missing.add('$kind:cn');
      }
    }
    if (missing.isNotEmpty) {
      throw FormatException(
        'Required China routing database is missing or unreadable: '
        '${missing.join(', ')}. Restore the bundled geo databases.',
      );
    }
  }

  /// Полная ли база стран сейчас на диске — по ней экран «Внутренности»
  /// решает, предлагать ли догрузку.
  static Future<bool> hasFullGeoip() async => (await index()).hasFullGeoip;
}
