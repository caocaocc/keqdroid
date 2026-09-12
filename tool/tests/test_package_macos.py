import importlib.util
import json
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
spec = importlib.util.spec_from_file_location('package_macos', TOOL / 'package_macos.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackagingTests(unittest.TestCase):
    def test_replaces_prebuilt_app_cores_without_retired_binaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            app = work / 'KEQDIS.app'
            destination = app / 'Contents/Resources/cores'
            destination.mkdir(parents=True)
            (destination / 'wireproxy').write_bytes(b'retired core')
            (destination / 'keqrnel').write_bytes(b'old core')
            (destination / 'leftover').mkdir()
            (destination / 'leftover/unused').write_bytes(b'old resource')
            source = work / 'verified'
            source.mkdir()
            for name in ('keqrnel', 'mihomo'):
                (source / name).write_bytes(name.encode())
            package.replace_bundle_cores(app, source)
            self.assertEqual({p.name for p in destination.iterdir()}, {'keqrnel', 'mihomo'})
            for name in ('keqrnel', 'mihomo'):
                self.assertEqual((destination / name).read_bytes(), name.encode())

    def test_bundle_core_replacement_rejects_symlink_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            app = work / 'KEQDIS.app'
            (app / 'Contents/Resources').mkdir(parents=True)
            outside = work / 'outside'
            outside.mkdir()
            keep = outside / 'keep'
            keep.write_bytes(b'unchanged')
            (app / 'Contents/Resources/cores').symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'regular directory'):
                package.replace_bundle_cores(app, work)
            self.assertEqual(keep.read_bytes(), b'unchanged')

    def test_checksums_cover_this_architecture_without_waiting_for_the_other(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            (work / 'keqdroid-0.18.0-macos-x64.dmg').write_bytes(b'unrelated stale output')
            dmg = work / 'keqdroid-0.18.0-macos-arm64.dmg'
            dmg.write_bytes(b'current image')
            package.write_checksums(dmg)
            expected = f'{package.sha(dmg)}  {dmg.name}\n'
            self.assertEqual((work / 'SHA256SUMS').read_text(), expected)
            self.assertEqual(dmg.with_suffix('.dmg.sha256').read_text(), expected)

    def test_complete_prebuilt_inputs_never_invoke_a_compiler(self):
        commands = []
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            cores = work / 'cores'
            cores.mkdir()
            for name in package.CORES:
                (cores / name).write_bytes(b'core fixture')
            (cores / 'provenance.json').write_text('{}')
            helper = work / 'keqdis-network-service'
            helper.write_bytes(struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
                               + struct.pack('<6I', 0x32, 24, 1, 12 << 16, 12 << 16, 0))
            argv = ['package_macos.py', '--arch', 'arm64', '--app', str(work / 'KEQDIS.app'),
                    '--helper', str(helper), '--cores', str(cores), '--output', str(work)]
            def capture(*args, **kwargs):
                commands.append(args)
                return subprocess.CompletedProcess(args, 0, '', '')
            with patch.object(sys, 'argv', argv), patch.object(sys, 'platform', 'darwin'), \
                    patch.object(package, 'run', capture), patch.object(package, 'validate_provenance'), \
                    patch.object(package.tempfile, 'TemporaryDirectory', side_effect=InterruptedError('before packaging')):
                with self.assertRaises(InterruptedError):
                    package.main()
        self.assertEqual(commands, [('/usr/bin/xcodebuild', '-version')])

    def test_prebuilt_helper_rejects_symlinks_and_wrong_architecture(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'helper'
            binary.write_bytes(struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
                               + struct.pack('<6I', 0x32, 24, 1, 12 << 16, 12 << 16, 0))
            alias = Path(temporary) / 'alias'
            alias.symlink_to(binary)
            with patch.object(package, 'run') as compiler:
                self.assertEqual(package.resolve_helper(binary, 'arm64'), binary)
                with self.assertRaises(ValueError):
                    package.resolve_helper(alias, 'arm64')
                with self.assertRaises(ValueError):
                    package.resolve_helper(binary, 'x64')
                compiler.assert_not_called()

    def test_aggregate_provenance_must_equal_validated_components(self):
        expected = {'componentInputs': {'keqrnel': 'correct'}}
        with patch.object(package, 'validate_core_set', return_value=expected) as validate:
            package.validate_provenance(Path('cores'), expected, 'arm64')
            validate.assert_called_once_with(Path('cores'), 'arm64')
            with self.assertRaises(ValueError):
                package.validate_provenance(Path('cores'), {'componentInputs': {'keqrnel': 'stale'}}, 'arm64')

    def test_flutter_344_uses_supported_release_command(self):
        commands = []

        def capture(*args, **kwargs):
            commands.append(args)
            if args[0] == 'flutter':
                raise InterruptedError('captured without building')
            return subprocess.CompletedProcess(args, 0, '', '')

        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(sys, 'argv', ['package_macos.py', '--arch', 'x64', '--output', temporary]), \
                    patch.object(sys, 'platform', 'darwin'), patch.object(package, 'run', capture):
                with self.assertRaises(InterruptedError):
                    package.main()
        self.assertEqual(commands[-1], ('flutter', 'build', 'macos', '--release'))

    def test_reject_non_macos_and_newer_minimum_load_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'binary'
            for platform, minimum in [(2, 12 << 16), (1, (12 << 16) | 1), (1, 13 << 16)]:
                binary.write_bytes(struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
                                   + struct.pack('<6I', 0x32, 24, platform, minimum, minimum, 0))
                # The old text parser accepted a non-macOS binary and dropped
                # the patch component of its minimum deployment version.
                output = f'cmd LC_BUILD_VERSION\n platform {platform}\n minos 12.0.1\n'
                def fake_run(*args, **kwargs):
                    return subprocess.CompletedProcess(args, 0, 'arm64' if 'lipo' in args[0] else output, '')
                with patch.object(package, 'run', fake_run), self.assertRaises(ValueError):
                    package.inspect_binary(binary, 'arm64')

    def test_actual_core_provenance_is_accepted_and_wrong_arch_rejected(self):
        arch = 'arm64' if platform.machine() == 'arm64' else 'x64'
        cores = TOOL.parent / 'build/macos-cores' / arch
        if not all((cores / f'{core}-provenance.json').exists() for core in package.CORES):
            self.skipTest('independent local core builds are optional for pure packaging tests')
        data = json.loads((cores / 'provenance.json').read_text())
        package.validate_provenance(cores, data, arch)
        with self.assertRaises(ValueError):
            package.validate_provenance(cores, data, 'x64' if arch == 'arm64' else 'arm64')
        changed = dict(data, go='1.24.0')
        with self.assertRaises(ValueError):
            package.validate_provenance(cores, changed, arch)

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS codesign, no execution or installation')
    def test_seals_real_nested_macho_bundle(self):
        arch = 'arm64' if platform.machine() == 'arm64' else 'x64'
        core = TOOL.parent / 'build/macos-cores' / arch / 'mihomo'
        if not core.exists():
            self.skipTest('build the pinned cores first')
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'SealFixture.app'
            child = app / 'Contents/Helpers/Child.app'
            for bundle in (app, child):
                (bundle / 'Contents/MacOS').mkdir(parents=True)
                shutil.copy2(core, bundle / 'Contents/MacOS/fixture')
                with (bundle / 'Contents/Info.plist').open('wb') as output:
                    plistlib.dump({'CFBundleExecutable': 'fixture', 'CFBundleIdentifier': 'test.keqdis.' + bundle.stem,
                                   'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}, output)
            package.normalize_modes(app)
            requirement = package.seal_app(app, arch)
            self.assertRegex(requirement, r'^cdhash H"[a-f0-9]{40}"$')
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app], check=True)

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS pkgbuild, does not install')
    def test_package_metadata_cannot_relocate_or_skip_staged_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            payload = work / 'payload'
            app = payload / package.SUPPORT / 'KEQDIS.app'
            for bundle in (app, app / 'Contents/Helpers/Child.app'):
                (bundle / 'Contents/MacOS').mkdir(parents=True)
                executable = bundle / 'Contents/MacOS/fixture'
                executable.write_text('#!/bin/sh\nexit 0\n')
                executable.chmod(0o755)
                with (bundle / 'Contents/Info.plist').open('wb') as output:
                    plistlib.dump({'CFBundleExecutable': 'fixture', 'CFBundleIdentifier': 'test.keqdis.' + bundle.stem,
                                   'CFBundlePackageType': 'APPL', 'CFBundleVersion': '999'}, output)
            props = work / 'components.plist'
            package.component_properties(payload, props)
            def assert_settings(items):
                for item in items:
                    self.assertFalse(item['BundleIsRelocatable'])
                    self.assertFalse(item['BundleIsVersionChecked'])
                    assert_settings(item.get('ChildBundles', []))
            assert_settings(plistlib.loads(props.read_bytes()))
            pkg = work / 'fixture.pkg'
            subprocess.run(['/usr/bin/pkgbuild', '--root', payload, '--component-plist', props,
                            '--identifier', 'io.github.caocaocc.keqdroid.installer', '--version', '1', pkg], check=True,
                           capture_output=True)
            expanded = work / 'expanded'
            subprocess.run(['/usr/sbin/pkgutil', '--expand-full', pkg, expanded], check=True, capture_output=True)
            info = ET.parse(expanded / 'PackageInfo').getroot()
            self.assertEqual(info.attrib['relocatable'], 'false')
            self.assertEqual(info.findall('./relocate/*'), [])
            self.assertEqual(info.findall('./bundle-version/*'), [])
            for bundle in info.findall('./bundle'):
                self.assertTrue(str(Path(bundle.attrib['path'])).startswith(str(package.SUPPORT) + '/'))
            distribution = work / 'distribution.xml'
            distribution.write_text(package.distribution_xml(pkg.name, 'arm64'))
            product = work / 'product.pkg'
            subprocess.run(['/usr/bin/productbuild', '--distribution', distribution, '--package-path', work, product],
                           check=True, capture_output=True)
            self.assertGreater(product.stat().st_size, 0)


if __name__ == '__main__':
    unittest.main()
