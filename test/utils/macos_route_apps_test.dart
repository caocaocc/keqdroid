import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/macos_app_routing.dart';
import 'package:keqdroid/services/macos_app_routing_store.dart';
import 'package:keqdroid/tunnel/app_routing_mode.dart';
import 'package:keqdroid/utils/macos_route_apps.dart';

void main() {
  const main = '/Applications/Browser.app/Contents/MacOS/Browser';
  const helper =
      '/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper';
  const catalog = [
    {
      'packageName': main,
      'installPath': main,
      'bundleId': 'test.browser',
      'executablePaths': [main, helper],
    },
  ];

  const selected = MacOSAppEntry(
    displayName: 'Browser',
    executablePath: main,
    executablePaths: [main],
    bundlePath: '/Applications/Browser.app',
  );

  test(
    'split scope refreshes helpers by bundle identity like session start',
    () {
      const saved = MacOSAppRoutingSettings(
        mode: AppRoutingMode.onlySelected,
        apps: [selected],
      );
      final scope = MacOSAppRoutingSettings(
        mode: saved.mode,
        apps: MacOSAppRoutingStore.currentEntries(saved, [
          {...catalog.single, 'bundlePath': selected.bundlePath},
          {
            'packageName': '/Other/Browser.app/Contents/MacOS/Browser',
            'bundlePath': '/Other/Browser.app',
            'bundleId': 'test.browser',
            'executablePaths': ['/Other/Browser.app/Contents/MacOS/Browser'],
          },
        ]),
      );
      expect(macOSAppsOutsideSplit([main, helper, '/usr/bin/curl'], scope), [
        '/usr/bin/curl',
      ]);
      expect(
        macOSAppsOutsideSplit(
          [main, helper, '/usr/bin/curl'],
          MacOSAppRoutingSettings(
            mode: AppRoutingMode.allExceptSelected,
            apps: scope.apps,
          ),
        ),
        [main, helper],
      );
      expect(
        macOSAppsOutsideSplit([
          main,
          helper,
        ], MacOSAppRoutingSettings(apps: scope.apps)),
        isEmpty,
      );
    },
  );

  test('missing app stays exact and empty only-selected excludes all apps', () {
    const saved = MacOSAppRoutingSettings(
      mode: AppRoutingMode.onlySelected,
      apps: [selected],
    );
    expect(MacOSAppRoutingStore.currentEntries(saved, []), [selected]);
    expect(macOSAppsOutsideSplit([helper], saved), [helper]);
    expect(
      macOSAppsOutsideSplit([
        main,
      ], const MacOSAppRoutingSettings(mode: AppRoutingMode.onlySelected)),
      [main],
    );
  });

  test('expands exactly selected app to fresh nested executable paths', () {
    expect(expandMacOSRouteApps([main], catalog), [main, helper]);
    expect(expandMacOSRouteApps([main, helper, main], catalog), [main, helper]);
  });

  test(
    'keeps explicit process names and absent paths without guessing a bundle',
    () {
      expect(
        expandMacOSRouteApps([
          'Browser',
          'test.browser',
          '/Other/Browser',
        ], catalog),
        ['Browser', 'test.browser', '/Other/Browser'],
      );
    },
  );

  test(
    'does not fold case or accept catalog non-paths as helper executables',
    () {
      expect(expandMacOSRouteApps([main.toLowerCase()], catalog), [
        main.toLowerCase(),
      ]);
      expect(
        expandMacOSRouteApps(
          [main],
          [
            {
              'packageName': main,
              'executablePaths': [main, 'Browser.exe', 42],
            },
          ],
        ),
        [main],
      );
    },
  );
}
