import '../models/macos_app_routing.dart';
import '../tunnel/app_routing_mode.dart';
import 'app_routes.dart';

/// A route stores the exact selected process. Browsers also open sockets in
/// executables inside the same installed app, refreshed before each connection.
List<String> expandMacOSRouteApps(
  Iterable<String> selected,
  Iterable<Map<String, dynamic>> installed,
) {
  final pathsByExecutable = <String, List<String>>{};
  for (final app in installed) {
    final paths =
        (app['executablePaths'] as List?)
            ?.whereType<String>()
            .where((path) => path.startsWith('/'))
            .toList() ??
        const <String>[];
    for (final key in [app['packageName'], app['installPath']]) {
      if (key is String && key.startsWith('/') && paths.isNotEmpty) {
        pathsByExecutable[key] = paths;
      }
    }
  }
  return {
    for (final entry in selected) ...[entry, ...?pathsByExecutable[entry]],
  }.toList();
}

List<String> macOSAppsOutsideSplit(
  List<String> apps,
  MacOSAppRoutingSettings scope,
) {
  if (scope.mode == AppRoutingMode.onlySelected && scope.apps.isEmpty) {
    return apps;
  }
  return appsOutsideSplit(
    apps,
    include: scope.mode == AppRoutingMode.onlySelected
        ? scope.processPaths.toSet()
        : const {},
    exclude: scope.mode == AppRoutingMode.allExceptSelected
        ? scope.processPaths.toSet()
        : const {},
    windows: false,
  );
}
