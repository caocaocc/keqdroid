import '../tunnel/app_routing_mode.dart';

/// macOS хранит пути отдельно от Android package name и Windows exe.
class MacOSAppEntry {
  final String displayName;
  final String executablePath;
  final List<String> executablePaths;
  final String? bundlePath;
  final String? bundleId;

  const MacOSAppEntry({
    required this.displayName,
    required this.executablePath,
    required this.executablePaths,
    this.bundlePath,
    this.bundleId,
  });

  String get id => bundlePath ?? executablePath;

  factory MacOSAppEntry.fromNative(Map<String, dynamic> map) {
    final executable =
        (map['executablePath'] ?? map['installPath'] ?? map['packageName'])
            ?.toString() ??
        '';
    final paths = <String>{
      executable,
      if (map['executablePaths'] is List)
        ...(map['executablePaths'] as List).whereType<String>(),
    };
    if (paths.any((path) => !isMacOSExecutablePath(path))) {
      throw const FormatException(
        'An application must have absolute executable paths.',
      );
    }
    final bundle = map['bundlePath'] as String?;
    if (bundle != null &&
        (!isMacOSExecutablePath(bundle) ||
            !bundle.endsWith('.app') ||
            paths.any((path) => !path.startsWith('$bundle/Contents/')))) {
      throw const FormatException(
        'Application executables must belong to the selected bundle.',
      );
    }
    return MacOSAppEntry(
      displayName: (map['displayName'] ?? map['appName'] ?? executable)
          .toString(),
      executablePath: executable,
      executablePaths: List.unmodifiable(paths),
      bundlePath: bundle,
      bundleId: map['bundleId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    'executablePath': executablePath,
    'executablePaths': executablePaths,
    if (bundlePath != null) 'bundlePath': bundlePath,
    if (bundleId != null) 'bundleId': bundleId,
  };
}

bool isMacOSExecutablePath(String path) =>
    path.startsWith('/') &&
    path.length > 1 &&
    !path.split('/').contains('..') &&
    !path.contains(RegExp(r'[\x00\r\n,]'));

class MacOSAppRoutingSettings {
  final AppRoutingMode mode;
  final List<MacOSAppEntry> apps;

  const MacOSAppRoutingSettings({
    this.mode = AppRoutingMode.allProxy,
    this.apps = const [],
  });

  factory MacOSAppRoutingSettings.fromJson(Map<String, dynamic> map) =>
      MacOSAppRoutingSettings(
        mode: AppRoutingMode.values.firstWhere(
          (mode) => mode.name == map['mode'],
          orElse: () => throw const FormatException(
            'Unknown macOS application routing mode.',
          ),
        ),
        apps: (map['apps'] as List? ?? const [])
            .map(
              (app) => MacOSAppEntry.fromNative(
                Map<String, dynamic>.from(app as Map),
              ),
            )
            .toList(),
      );

  List<String> get processPaths =>
      {for (final app in apps) ...app.executablePaths}.toList();

  Map<String, dynamic> toJson() => {
    'version': 1,
    'mode': mode.name,
    'apps': apps.map((app) => app.toJson()).toList(),
  };
}
