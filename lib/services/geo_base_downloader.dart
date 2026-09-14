import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../core/app_logger.dart';
import '../utils/geo_asset_index.dart';
import 'geo_asset_service.dart';
import 'update_service.dart';

class GeoBaseDownloader {
  GeoBaseDownloader._();

  static const _owner = UpdateService.releaseOwner;
  static const _repo = UpdateService.releaseRepository;

  static const assetName = 'geoip.dat';

  static bool isFullBase(GeoAssetIndex index) => index.hasFullGeoip;

  static bool get isSupported => Platform.isAndroid;

  static Future<void> install({
    void Function(double progress)? onProgress,
    Dio? client,
  }) async {
    if (Platform.isMacOS) {
      throw const GeoBaseDownloadException(
        'macOS geo databases are managed by the installer. Install an updated PKG to update them.',
      );
    }
    final dir = await GeoAssetService.geoDir();
    if (dir == null) {
      throw const GeoBaseDownloadException('geo directory is unknown');
    }

    final dio = client ?? Dio();
    final (url, shaUrl) = await _resolveUrls(dio);

    // во временный файл рядом: под работающим ядром базу не подменить, а rename в каталоге атомарный
    final target = File(p.join(dir, assetName));
    final temp = File('${target.path}.part');
    if (temp.existsSync()) await temp.delete();

    try {
      await dio.download(
        url,
        temp.path,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
      );

      final expected = await _expectedSha256(dio, shaUrl);
      final actual = (await sha256.bind(temp.openRead()).first).toString();
      if (expected.toLowerCase() != actual.toLowerCase()) {
        throw GeoBaseDownloadException(
          'checksum mismatch: expected $expected, got $actual',
        );
      }

      final size = await temp.length();
      await temp.rename(target.path);
      // индекс кэшируется на процесс, без сброса правила чистятся по старому списку
      GeoAssetService.invalidate();
      AppLogger.instance.info(
        'Full geoip base installed ($size bytes) from $url',
      );
    } catch (e) {
      if (temp.existsSync()) {
        try {
          await temp.delete();
        } catch (_) {}
      }
      if (e is GeoBaseDownloadException) rethrow;
      throw GeoBaseDownloadException('$e');
    }
  }

  static Future<(String, String)> _resolveUrls(Dio dio) async {
    final Response<dynamic> res;
    try {
      res = await dio.get<dynamic>(
        'https://api.github.com/repos/$_owner/$_repo/releases/latest',
        options: Options(headers: {'Accept': 'application/vnd.github+json'}),
      );
    } catch (e) {
      throw GeoBaseDownloadException('release lookup failed: $e');
    }

    final assets = (res.data is Map ? res.data['assets'] : null);
    if (assets is! List) {
      throw const GeoBaseDownloadException('release has no assets');
    }

    final urls = urlsFromAssets(assets);
    if (urls == null) {
      throw const GeoBaseDownloadException(
        'the latest release does not carry geoip.dat with its checksum',
      );
    }
    return urls;
  }

  @visibleForTesting
  static (String, String)? urlsFromAssets(List<dynamic> assets) {
    String? urlOf(Object? asset) {
      if (asset is! Map) return null;
      final url = asset['browser_download_url'];
      return url is String && url.isNotEmpty ? url : null;
    }

    String? baseUrl;
    for (final a in assets) {
      if (a is Map && a['name'] == assetName) baseUrl = urlOf(a);
    }
    final checksumUrl = urlOf(UpdateService.checksumAssetFor(
      [
        for (final a in assets)
          if (a is Map) Map<String, dynamic>.from(a),
      ],
      assetName,
    ));
    if (baseUrl == null || checksumUrl == null) return null;
    return (baseUrl, checksumUrl);
  }

  static Future<String> _expectedSha256(Dio dio, String url) async {
    final res = await dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final hash = UpdateService.extractSha256(res.data ?? '', assetName);
    if (hash == null) {
      throw const GeoBaseDownloadException('checksum file is unreadable');
    }
    return hash;
  }
}

class GeoBaseDownloadException implements Exception {
  const GeoBaseDownloadException(this.message);
  final String message;

  @override
  String toString() => message;
}
