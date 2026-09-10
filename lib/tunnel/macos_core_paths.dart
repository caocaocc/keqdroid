import 'dart:io';

import 'package:path/path.dart' as p;

/// Executable живут в проверенном bundle; не распаковываем их в общий /tmp
/// и не подхватываем одноимённые программы из PATH.
class MacOSCorePaths {
  MacOSCorePaths._();

  static const binariesHint =
      'Install the complete macOS package. Its application bundle must contain keqrnel, mihomo and wireproxy.';
  static const installedRuntime =
      '/Library/Application Support/io.github.caocaocc.keqdroid';

  /// Both installed session cores and ordinary-user measurement cores bypass
  /// the TUN. Full paths avoid exempting an unrelated process with the same name.
  static List<String> get bypassExecutablePaths => [
    Platform.resolvedExecutable,
    for (final name in ['keqrnel', 'mihomo', 'wireproxy']) ...[
      p.join(installedRuntime, 'bin', name),
      p.join(coresDirectory(), name),
    ],
  ];

  static String bundleContents({String? executablePath}) =>
      p.dirname(p.dirname(executablePath ?? Platform.resolvedExecutable));

  static String coresDirectory({String? executablePath}) => p.join(
    bundleContents(executablePath: executablePath),
    'Resources',
    'cores',
  );

  static Future<String?> executable(
    String name, {
    String? executablePath,
  }) async {
    if (!const {'keqrnel', 'mihomo', 'wireproxy'}.contains(name)) {
      throw ArgumentError.value(name, 'name', 'Unknown bundled core');
    }
    final path = p.join(coresDirectory(executablePath: executablePath), name);
    return await File(path).exists() ? path : null;
  }

  static Future<String?> keqrnelExecutable() => executable('keqrnel');
  static Future<String?> mihomoExecutable() => executable('mihomo');
  static Future<String?> wireproxyExecutable() => executable('wireproxy');

  static Future<Directory> sessionDir() async {
    final dir = await Directory.systemTemp.createTemp('keqdroid_macos_');
    final result = await Process.run('/bin/chmod', ['0700', dir.path]);
    if (result.exitCode != 0) {
      await dir.delete();
      throw const FileSystemException(
        'Could not protect the core session directory.',
      );
    }
    return dir;
  }

  static Future<String?> geoAssetDir() async {
    final resources = p.join(bundleContents(), 'Resources');
    for (final directory in [
      p.join(resources, 'geo'),
      p.join(resources, 'cores'),
    ]) {
      if (await File(p.join(directory, 'geoip.dat')).exists() ||
          await File(p.join(directory, 'geosite.dat')).exists()) {
        return directory;
      }
    }
    return null;
  }
}
