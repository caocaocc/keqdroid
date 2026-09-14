import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/macos_app_routing.dart';
import 'package:keqdroid/services/macos_app_routing_store.dart';
import 'package:keqdroid/services/settings_backup_service.dart';
import 'package:keqdroid/services/storage_service.dart';
import 'package:keqdroid/tunnel/app_routing_mode.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage extends Mock implements StorageService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage storage;
  const app = MacOSAppEntry(
    displayName: 'Absent browser',
    bundleId: 'example.browser',
    bundlePath: '/Applications/Absent.app',
    executablePath: '/Applications/Absent.app/Contents/MacOS/Browser',
    executablePaths: [
      '/Applications/Absent.app/Contents/MacOS/Browser',
      '/Applications/Absent.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper',
    ],
  );
  const selected = MacOSAppRoutingSettings(
    mode: AppRoutingMode.onlySelected,
    apps: [app],
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = _Storage();
    when(() => storage.getExcludePackages()).thenReturn(['android.excluded']);
    when(() => storage.getIncludePackages()).thenReturn(['android.included']);
    when(() => storage.setExcludePackages(any())).thenAnswer((_) async {});
    when(() => storage.setIncludePackages(any())).thenAnswer((_) async {});
  });

  test(
    'backup roundtrip preserves missing Mac bundles, helpers and old platform lists',
    () async {
      await MacOSAppRoutingStore.save(selected);
      final backup = await SettingsBackupService.buildBackup(
        storage,
        sections: {BackupSection.splitTunneling},
      );
      final restored = KeqdisBackup.fromJson(
        jsonDecode(backup.toJsonString()) as Map<String, dynamic>,
      );
      await MacOSAppRoutingStore.save(const MacOSAppRoutingSettings());
      await SettingsBackupService.applyBackup(
        storage,
        backup: restored,
        sections: {BackupSection.splitTunneling},
      );
      expect((await MacOSAppRoutingStore.load()).toJson(), selected.toJson());
      verify(() => storage.setExcludePackages(['android.excluded'])).called(1);
      verify(() => storage.setIncludePackages(['android.included'])).called(1);
    },
  );

  test('old backups without macos reset optional routing to empty', () async {
    await MacOSAppRoutingStore.save(selected);
    await SettingsBackupService.applyBackup(
      storage,
      backup: KeqdisBackup(
        version: 1,
        exportedAt: DateTime(2026),
        data: {
          'splitTunneling': {
            'excludePackages': ['old.android'],
            'includePackages': <String>[],
          },
        },
      ),
      sections: {BackupSection.splitTunneling},
    );
    expect((await MacOSAppRoutingStore.load()).apps, isEmpty);
    expect((await MacOSAppRoutingStore.load()).mode, AppRoutingMode.allProxy);
  });

  test(
    'invalid Mac routing is rejected before writing other platform fields',
    () async {
      final backup = KeqdisBackup(
        version: 1,
        exportedAt: DateTime(2026),
        data: {
          'splitTunneling': {
            'macos': {
              'mode': 'onlySelected',
              'apps': [
                {
                  'executablePath': '/Applications/../tmp/escape',
                  'executablePaths': <String>[],
                },
              ],
            },
          },
        },
      );
      await expectLater(
        SettingsBackupService.applyBackup(
          storage,
          backup: backup,
          sections: {BackupSection.splitTunneling},
        ),
        throwsFormatException,
      );
      verifyNever(() => storage.setExcludePackages(any()));
    },
  );
}
