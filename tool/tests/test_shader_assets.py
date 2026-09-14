"""Shader declarations must invalidate apps and survive Flutter packaging."""
from pathlib import Path
import os
import sys
import struct
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import shader_assets


class ShaderAssetsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'shaders/liquid_bar.frag'
        self.source.parent.mkdir()
        self.source.write_text('void main() {}')
        self.pubspec = self.root / 'pubspec.yaml'
        self.pubspec.write_text('flutter:\n  shaders:\n    - shaders/liquid_bar.frag\n  fonts:\n    - family: KeepParsingBounded\n')
        self.assets = self.root / 'flutter_assets'
        self.compiled = self.assets / 'shaders/liquid_bar.frag'
        self.compiled.parent.mkdir(parents=True)
        # Minimal IPLR envelope; actual pinned-SDK shaders are checked separately.
        self.compiled.write_bytes(struct.pack('<I4sHHHHII', 16, b'IPLR', 6, 8, 4, 0, 8, 0))

    def test_declarations_are_bounded_to_shader_section(self):
        self.assertEqual(shader_assets.declared_shaders(self.root), ['shaders/liquid_bar.frag'])
        self.pubspec.write_text('flutter:\n  assets:\n    - assets/icon.png\n')
        self.assertEqual(shader_assets.verify_directory(self.root, self.assets), {})

    def test_compiled_directory_and_apk_record_same_shader_hash(self):
        expected = shader_assets.verify_directory(self.root, self.assets)
        apk = self.root / 'app.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.write(self.compiled, 'assets/flutter_assets/shaders/liquid_bar.frag')
        self.assertEqual(shader_assets.verify_apk(self.root, apk), expected)
        self.assertEqual(set(expected), {'shaders/liquid_bar.frag'})

    def test_raw_shader_source_and_corrupt_containers_are_rejected_in_both_payloads(self):
        valid = self.compiled.read_bytes()
        corrupt = [self.source.read_bytes(), b'compiled shader', valid[:7],
                   valid[:4] + b'GLSL' + valid[8:],
                   struct.pack('<I', len(valid) + 4) + valid[4:],
                   struct.pack('<I', 9) + valid[4:], valid[:-1],
                   valid[:16] + struct.pack('<i', 0x7fffffff) + valid[20:],
                   valid[:8] + struct.pack('<H', 0xfffe) + valid[10:],
                   valid[:10] + struct.pack('<H', 0xffff) + valid[12:]]
        apk = self.root / 'app.apk'
        for index, data in enumerate(corrupt):
            with self.subTest(case=index):
                self.compiled.write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'Invalid compiled Flutter 3.44.4 shader'):
                    shader_assets.verify_directory(self.root, self.assets)
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.writestr('assets/flutter_assets/shaders/liquid_bar.frag', data)
                with self.assertRaisesRegex(ValueError, 'Invalid compiled Flutter 3.44.4 shader'):
                    shader_assets.verify_apk(self.root, apk)

    def test_missing_empty_and_symbolic_compiled_shader_are_rejected(self):
        self.compiled.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing compiled'):
            shader_assets.verify_directory(self.root, self.assets)
        self.compiled.touch()
        with self.assertRaisesRegex(ValueError, 'Missing compiled'):
            shader_assets.verify_directory(self.root, self.assets)
        if os.name != 'nt':
            self.compiled.unlink()
            self.compiled.symlink_to(self.source)
            with self.assertRaisesRegex(ValueError, 'Missing compiled'):
                shader_assets.verify_directory(self.root, self.assets)

    def test_apk_missing_or_empty_shader_is_rejected(self):
        apk = self.root / 'app.apk'
        for empty in (False, True):
            with self.subTest(empty=empty):
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.writestr('unrelated', b'fixture')
                    if empty:
                        archive.writestr('assets/flutter_assets/shaders/liquid_bar.frag', b'')
                with self.assertRaisesRegex(ValueError, 'Missing or duplicate'):
                    shader_assets.verify_apk(self.root, apk)

    def test_missing_source_and_unsafe_or_duplicate_declaration_are_rejected(self):
        for entry in ('shaders/../secret.frag', 'shaders/missing.frag', '/tmp/shader.frag',
                      'shaders/liquid_bar.frag\n    - shaders/liquid_bar.frag'):
            with self.subTest(entry=entry):
                self.pubspec.write_text('flutter:\n  shaders:\n    - ' + entry + '\n')
                with self.assertRaises(ValueError):
                    shader_assets.declared_shaders(self.root)


if __name__ == '__main__':
    unittest.main()
