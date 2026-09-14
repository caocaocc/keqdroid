"""Check the embedded fixed-SDK patch without invoking Flutter or changing it."""
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'macos/build_app.sh'


def embedded(marker):
    code = SCRIPT.read_text().split(f"<<'{marker}'\n", 1)[1].split(f'\n{marker}\n', 1)[0]
    namespace = {'__name__': 'fixture'}
    exec(compile(code, str(SCRIPT), 'exec'), namespace)
    return namespace


class FlutterSDKPatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.api = embedded('PY_NATIVE_ASSETS')
        self.source = self.root / self.api['SOURCE']
        self.source.parent.mkdir(parents=True)
        self.original = b'const targetMacOSVersion = 13;\n'
        self.changed = b'const targetMacOSVersion = 12;\n'
        self.api['ORIGINAL'] = hashlib.sha256(self.original).hexdigest()
        self.api['PATCHED'] = hashlib.sha256(self.changed).hexdigest()
        self.source.write_bytes(self.original)
        self.lock = self.root / 'packages/flutter_tools/pubspec.lock'
        self.lock.write_text('locked SDK dependencies\n')
        self.cache = self.root / 'bin/cache'
        self.cache.mkdir(parents=True)
        self.snapshot = self.cache / 'flutter_tools.snapshot'
        self.snapshot.write_bytes(b'original snapshot')
        self.calls = []
        self.run_patch = patch.object(self.api['subprocess'], 'run', self.fake_run)
        self.run_patch.start()
        self.addCleanup(self.run_patch.stop)
        self.environment = patch.dict(self.api['os'].environ, {'FLUTTER_TOOL_ARGS': ''})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def fake_run(self, args, **kwargs):
        self.calls.append(args)
        if args[0] == 'git':
            return subprocess.CompletedProcess(args, 0, self.api['REVISION'] + '\n', '')
        snapshots = [arg for arg in args if arg.startswith('--snapshot=')]
        if snapshots:
            Path(snapshots[0].split('=', 1)[1]).write_bytes(b'macOS 12 snapshot')
        return subprocess.CompletedProcess(args, 0, '', '')

    def test_original_is_patched_and_snapshot_is_rebuilt_with_locked_dependencies(self):
        original_lock = self.lock.read_bytes()
        self.api['prepare'](self.root)
        self.assertEqual(self.source.read_bytes(), self.changed)
        self.assertEqual(self.snapshot.read_bytes(), b'macOS 12 snapshot')
        self.assertEqual(self.lock.read_bytes(), original_lock)
        self.assertIn('--enforce-lockfile', self.calls[1])
        self.assertNotIn('upgrade', [arg for args in self.calls for arg in args])
        self.assertIn('--snapshot-kind=app-jit', self.calls[2])

    def test_verified_cached_snapshot_is_reused_but_tampering_rebuilds_it(self):
        self.api['prepare'](self.root)
        self.calls.clear()
        self.api['prepare'](self.root)
        self.assertEqual(len(self.calls), 1)
        self.snapshot.write_bytes(b'stale snapshot')
        self.api['prepare'](self.root)
        self.assertEqual(self.snapshot.read_bytes(), b'macOS 12 snapshot')
        self.assertEqual(len(self.calls), 4)

    def test_patched_source_without_a_completed_marker_rebuilds_snapshot(self):
        self.source.write_bytes(self.changed)
        self.api['prepare'](self.root)
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(self.snapshot.read_bytes(), b'macOS 12 snapshot')

    def test_changed_source_is_rejected_without_modification(self):
        self.source.write_bytes(b'unknown SDK revision')
        with self.assertRaises(ValueError):
            self.api['prepare'](self.root)
        self.assertEqual(self.source.read_bytes(), b'unknown SDK revision')
        self.assertEqual(self.snapshot.read_bytes(), b'original snapshot')

    def test_lockfile_change_aborts_before_snapshot_can_be_trusted(self):
        original_run = self.fake_run
        def altering_run(args, **kwargs):
            if '--enforce-lockfile' in args:
                self.lock.write_text('unexpected dependency update')
            return original_run(args, **kwargs)
        with patch.object(self.api['subprocess'], 'run', altering_run), self.assertRaises(ValueError):
            self.api['prepare'](self.root)
        self.assertEqual(self.snapshot.read_bytes(), b'original snapshot')
        self.assertFalse((self.cache / 'keqdroid-macos12-native-assets.json').exists())

    def test_wrong_sdk_revision_is_rejected_before_patching(self):
        with patch.object(self.api['subprocess'], 'run', return_value=subprocess.CompletedProcess([], 0, 'wrong\n', '')):
            with self.assertRaises(ValueError):
                self.api['prepare'](self.root)
        self.assertEqual(self.source.read_bytes(), self.original)


class AppCheckpointDeploymentTests(unittest.TestCase):
    def test_each_universal_slice_is_inspected_and_newer_macos_is_rejected(self):
        api = embedded('PY_VERIFY_APP')
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'KEQDIS.app'
            app.mkdir()
            binary = app / 'fixture'
            binary.write_bytes(b'\xcf\xfa\xed\xfe')
            targets = []
            def lipo(args, **kwargs):
                if '-archs' in args:
                    return subprocess.CompletedProcess(args, 0, 'x86_64 arm64\n', '')
                target = args[args.index('-thin') + 1]
                targets.append(target)
                cpu, minimum = (0x0100000C, 12) if target == 'arm64' else (0x01000007, 13)
                Path(args[-1]).write_bytes(struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
                                          + struct.pack('<6I', 0x32, 24, 1, minimum << 16, minimum << 16, 0))
                return subprocess.CompletedProcess(args, 0, '', '')
            with patch.object(api['subprocess'], 'run', lipo), self.assertRaisesRegex(ValueError, r'fixture \[x64\]'):
                api['validate_app'](app)
            self.assertEqual(targets, ['arm64', 'x86_64'])


if __name__ == '__main__':
    unittest.main()
