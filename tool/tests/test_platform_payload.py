"""Release payload checks follow upstream's native Xray desktop layout."""
from pathlib import Path
import os
import json
import re
import sys
import struct
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool/ci'))
import build_platform
import checkpoint
import package_platform


def binary(family, machine=None):
    data = bytearray(70)
    if family == 'windows':
        data[:2] = b'MZ'
        data[60:64] = (64).to_bytes(4, 'little')
        data[64:68] = b'PE\0\0'
        data[68:70] = (machine or 0x8664).to_bytes(2, 'little')
    else:
        data[:6] = b'\x7fELF\x02\x01'
        data[18:20] = (machine or 62).to_bytes(2, 'little')
    return data


class DesktopPayloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.addCleanup(patch.stopall)
        patch.object(build_platform, 'ROOT', self.root).start()
        (self.root / 'pubspec.yaml').write_text('version: 0.31.1+67\nflutter:\n  shaders:\n    - shaders/liquid_bar.frag\n')
        shader = self.root / 'shaders/liquid_bar.frag'
        shader.parent.mkdir()
        shader.write_text('void main() {}')

    def bundle(self, family):
        bundle = self.root / family
        suffix = '.exe' if family == 'windows' else ''
        cores = ['xray' + suffix, 'mihomo' + suffix]
        names = ['keqdroid' + suffix, *cores, 'geoip.dat', 'geosite.dat']
        if family == 'windows':
            names += ['wintun.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
                      'flutter_windows.dll', 'data/app.so']
        else:
            names += ['lib/libflutter_linux_gtk.so', 'lib/libapp.so']
        for name in names:
            path = bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(binary(family))
            path.chmod(0o755)
            if name in cores:
                source = self.root / 'assets/bin' / family / name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(path.read_bytes())
        shader = bundle / 'data/flutter_assets/shaders/liquid_bar.frag'
        shader.parent.mkdir(parents=True)
        shader.write_bytes(struct.pack('<I4sHHHHII', 16, b'IPLR', 6, 8, 4, 0, 8, 0))
        return bundle

    def test_native_xray_payload_is_verified_for_both_desktops(self):
        for family in ('linux', 'windows'):
            result = build_platform.verify_payload(family + '-x64', self.bundle(family))
            self.assertIn('shaders/liquid_bar.frag', result['shaders'])
            self.assertEqual(len(result['vcRuntime']), 3 if family == 'windows' else 0)

    def test_windows_zip_keeps_new_runtime_and_shaders_without_compilation(self):
        bundle = self.bundle('windows')
        (bundle / 'component-build.json').write_text(json.dumps({'platform': 'windows-x64'}))
        destination = self.root / 'release'
        with patch.object(package_platform, 'ROOT', self.root), \
             patch.object(package_platform.checkpoint.archive_tools, 'source_commit', return_value='a' * 40), \
             patch.object(package_platform.subprocess, 'run', side_effect=AssertionError('packaging compiled application')):
            package_platform.package('windows-x64', bundle, destination)
        with zipfile.ZipFile(destination / 'keqdroid-windows-x64-0.31.1.zip') as archive:
            names = set(archive.namelist())
            self.assertTrue({'xray.exe', 'mihomo.exe', 'msvcp140.dll', 'vcruntime140.dll',
                             'vcruntime140_1.dll', 'data/flutter_assets/shaders/liquid_bar.frag'}.issubset(names))
            self.assertNotIn('component-build.json', names)
            self.assertNotIn('keqrnel.exe', names)

    def test_missing_new_core_or_any_retired_core_is_rejected(self):
        for family in ('linux', 'windows'):
            bundle = self.bundle(family)
            core = bundle / ('xray.exe' if family == 'windows' else 'xray')
            core.unlink()
            with self.assertRaisesRegex(ValueError, 'Missing desktop payload: xray'):
                build_platform.verify_payload(family + '-x64', bundle)
            core.write_bytes(binary(family)); core.chmod(0o755)
            for name in build_platform.retired_core_names(family):
                retired = bundle / name
                retired.write_bytes(binary(family))
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'Retired desktop core'):
                    build_platform.verify_payload(family + '-x64', bundle)
                retired.unlink()

    def test_each_vc_runtime_is_required_and_must_be_x64(self):
        bundle = self.bundle('windows')
        for name in ('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'):
            path = bundle / name
            path.unlink()
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'Missing desktop payload'):
                build_platform.verify_payload('windows-x64', bundle)
            path.write_bytes(binary('windows', 0xAA64))
            with self.assertRaisesRegex(ValueError, 'Expected Windows x64 PE'):
                build_platform.verify_payload('windows-x64', bundle)
            path.write_bytes(binary('windows'))

    def test_core_hash_architecture_and_linux_permissions_are_enforced(self):
        bundle = self.bundle('linux')
        core = bundle / 'xray'
        core.write_bytes(binary('linux') + b'tampered')
        with self.assertRaisesRegex(ValueError, 'differs from tracked'):
            build_platform.verify_payload('linux-x64', bundle)
        core.write_bytes(binary('linux', 183))
        with self.assertRaisesRegex(ValueError, 'Expected Linux'):
            build_platform.verify_payload('linux-x64', bundle)
        core.write_bytes(binary('linux')); core.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'lost its permissions'):
            build_platform.verify_payload('linux-x64', bundle)

    def test_missing_compiled_shader_rejects_otherwise_complete_bundle(self):
        bundle = self.bundle('linux')
        (bundle / 'data/flutter_assets/shaders/liquid_bar.frag').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing compiled Flutter shader'):
            build_platform.verify_payload('linux-x64', bundle)

    def test_compilation_cache_cleanup_only_removes_known_retired_names(self):
        bundle = self.bundle('linux')
        (bundle / 'keqrnel').write_bytes(b'old cached core')
        if os.name != 'nt':
            (bundle / 'sing-box').symlink_to('xray')
        else:
            (bundle / 'sing-box').write_bytes(b'old cached core')
        build_platform.clear_retired_cores(bundle, 'linux')
        self.assertFalse((bundle / 'keqrnel').exists())
        self.assertFalse((bundle / 'sing-box').is_symlink())
        build_platform.verify_payload('linux-x64', bundle)
        (bundle / 'wireproxy').mkdir()
        with self.assertRaisesRegex(ValueError, 'Unexpected directory'):
            build_platform.clear_retired_cores(bundle, 'linux')


class RunnerAndShaderInputTests(unittest.TestCase):
    def test_shader_edit_invalidates_each_platform_and_runner_matches_workflow(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ('pubspec.yaml', 'pubspec.lock', 'shaders/liquid_bar.frag'):
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('fixture')
            files = b'pubspec.yaml\0pubspec.lock\0shaders/liquid_bar.frag\0'
            captured = []
            original = checkpoint.archive_tools.canonical_json
            def record(value):
                captured.append(value)
                return original(value)
            for platform, runner in (('linux-x64', 'ubuntu-22.04'), ('windows-x64', 'windows-2022'), ('android-arm64', 'ubuntu-24.04'), ('android-arm32', 'ubuntu-24.04')):
                with patch.object(checkpoint.subprocess, 'check_output', return_value=files), \
                     patch.object(checkpoint.archive_tools, 'canonical_json', side_effect=record):
                    before = checkpoint.fingerprint(platform, root, 'a' * 64)
                    (root / 'shaders/liquid_bar.frag').write_text('changed shader ' + platform)
                    after = checkpoint.fingerprint(platform, root, 'a' * 64)
                self.assertNotEqual(before, after)
                self.assertEqual(captured[-1]['toolchain']['runner'], runner)
            workflow = (ROOT / '.github/workflows/macos.yml').read_text()
            for job in ('app-linux', 'package-linux'):
                section = re.search(r'^  ' + job + r':\n(.*?)(?=^  \S|\Z)', workflow, re.S | re.M)[1]
                self.assertIn('ubuntu-22.04', section)
            component = (ROOT / '.github/workflows/platform-component.yml').read_text()
            self.assertIn('restore-keys: platform-intermediates-${{ inputs.platform }}-${{ inputs.runner }}-', component)
            self.assertNotIn('restore-keys: platform-intermediates-${{ inputs.platform }}-\n', component)
            packaging = (ROOT / '.github/workflows/platform-package.yml').read_text()
            self.assertIn('pkg-config libglib2.0-dev', packaging)
            linux = (ROOT / 'tool/package_linux.sh').read_text()
            self.assertIn('GLIB_FLOOR=2.72', linux)
            self.assertIn('"${1:-}" = --no-build', linux)


if __name__ == '__main__':
    unittest.main()
