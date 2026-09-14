"""Two signed Android ABI components and updater-compatible release names."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool/ci'))
import build_platform
import checkpoint
import package_platform
import publish_release


class AndroidPlatformTests(unittest.TestCase):
    def test_native_input_changes_are_isolated_to_the_selected_abi(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = ['pubspec.yaml', 'pubspec.lock', 'lib/main.dart']
            files += ['android/app/src/main/jniLibs/' + abi + '/libxray.so'
                      for abi in ('arm64-v8a', 'armeabi-v7a')]
            for name in files:
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('fixture')
            listing = ('\0'.join(files) + '\0').encode()
            def fingerprints():
                return {platform: checkpoint.fingerprint(platform, root, 'a' * 64) for platform in checkpoint.PLATFORMS}
            with patch.object(checkpoint.subprocess, 'check_output', return_value=listing):
                before = fingerprints()
                (root / files[-1]).write_text('new ARM32 core')
                after = fingerprints()
                self.assertEqual({p for p in before if before[p] != after[p]}, {'android-arm32'})
                (root / files[-2]).write_text('new ARM64 core')
                final = fingerprints()
                self.assertEqual({p for p in after if after[p] != final[p]}, {'android-arm64'})
                self.assertNotEqual(final['android-arm32'], final['android-arm64'])

    def test_each_android_component_builds_only_its_flutter_target(self):
        for platform, target in (('android-arm64', 'android-arm64'), ('android-arm32', 'android-arm')):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                commands = []
                def command(*args, **kwargs):
                    commands.append(args)
                    if args[:3] == ('flutter', 'build', 'apk'):
                        output = root / 'build/app/outputs/flutter-apk/app-release.apk'
                        output.parent.mkdir(parents=True)
                        output.write_bytes(b'verified fixture APK')
                    return subprocess.CompletedProcess(args, 0)
                with patch.object(build_platform, 'ROOT', root), \
                     patch.object(checkpoint, 'fingerprint', return_value='fixed'), \
                     patch.dict(build_platform.os.environ, {'EXPECTED_APP_FINGERPRINT': 'fixed'}), \
                     patch.object(checkpoint.archive_tools, 'source_commit', return_value='a' * 40), \
                     patch.object(build_platform, 'flutter_version', return_value={'frameworkVersion': '3.44.4'}), \
                     patch.object(build_platform, 'verify_payload', return_value={'nativeABI': checkpoint.ANDROID_TARGETS[platform]['abi']}), \
                     patch.object(build_platform, 'run', side_effect=command):
                    build_platform.build(platform, root / 'component')
                self.assertIn(('flutter', 'build', 'apk', '--release', '--no-pub', '--target-platform', target), commands)
                self.assertEqual(sum(c[:3] == ('flutter', 'build', 'apk') for c in commands), 1)

    def test_both_apks_are_packaged_independently_with_upstream_names_and_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'pubspec.yaml').write_text('version: 0.31.1+67\n')
            names = []
            for platform in checkpoint.ANDROID_TARGETS:
                source = root / platform; source.mkdir()
                (source / 'app-release.apk').write_bytes(platform.encode())
                (source / 'component-build.json').write_text(json.dumps({'platform': platform}))
                output = root / (platform + '-release')
                with patch.object(package_platform, 'ROOT', root), \
                     patch.object(checkpoint.archive_tools, 'source_commit', return_value='a' * 40), \
                     patch.object(package_platform.subprocess, 'run', side_effect=AssertionError('packaging must not compile')):
                    package_platform.package(platform, source, output)
                publish_release.verify_payload(output, '0.31.1', platform, 'a' * 40)
                apk = next(output.glob('*.apk'))
                self.assertEqual(apk.read_bytes(), platform.encode())
                names.append(apk.name)
            self.assertEqual(names, ['keqdroid-0.31.1-android.apk', 'keqdroid-0.31.1-armeabi-v7a-android.apk'])
            self.assertEqual(sorted(names, key=str.casefold), names)

    def test_workflows_keep_android_jobs_independent_and_gate_both_signing_paths(self):
        workflow = (ROOT / '.github/workflows/macos.yml').read_text()
        for name in ('app-android-arm32', 'package-android-arm32'):
            section = re.search(r'^  ' + name + r':\n(.*?)(?=^  \S|\Z)', workflow, re.S | re.M)[1]
            self.assertIn('android-arm32', section)
            self.assertNotIn('app-android]', section)
        component = (ROOT / '.github/workflows/platform-component.yml').read_text()
        self.assertNotIn("inputs.platform == 'android-arm64'", component)
        self.assertIn("always() && startsWith(inputs.platform, 'android-')", component)
        self.assertIn("!startsWith(inputs.platform, 'android-') || (github.repository == 'caocaocc/keqdroid'", component)
        self.assertIn('android-arm32', publish_release.PLATFORMS)


if __name__ == '__main__':
    unittest.main()
