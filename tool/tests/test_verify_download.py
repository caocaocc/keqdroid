"""Download verification rejects mismatched assets without running their code."""

import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "macos"))
import verify_download as verify


class DownloadChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.dmg = self.root / "keqdroid-0.18.0-macos-arm64.dmg"
        self.dmg.write_bytes(b"disk image fixture")
        self.sha = self.dmg.with_suffix(".dmg.sha256")
        self.sha.write_text(hashlib.sha256(self.dmg.read_bytes()).hexdigest() + "  " + self.dmg.name + "\n")
        self.report_path = self.root / "verification.json"
        self.commit = "a" * 40
        binary = {"sha256": "b" * 64, "size": 42, "architecture": "arm64", "minimumMacOS": "12.0.0"}
        paths = ["KEQDIS.app/Contents/MacOS/KEQDIS", "runtime/bin/keqdis-network-service"]
        paths += [f"runtime/bin/{core}" for core in verify.CORES]
        paths += [f"KEQDIS.app/Contents/Resources/cores/{core}" for core in verify.CORES]
        self.report = {"version": "0.18.0", "architecture": "arm64", "sourceCommit": self.commit,
                       "signature": "ad-hoc", "installerSignature": "unsigned", "notarized": False,
                       "clientRequirement": 'cdhash H"' + "c" * 40 + '"',
                       "files": {path: dict(binary) for path in paths}}
        self.save_report()

    def tearDown(self):
        self.temporary.cleanup()

    def save_report(self):
        self.report_path.write_text(json.dumps(self.report))

    def check(self):
        return verify.check_download(self.dmg, self.sha, self.report_path, "arm64", self.commit)

    def test_valid_download_does_not_claim_payload_or_disk_image_were_inspected(self):
        with mock.patch.object(verify, "command") as command:
            _, result = self.check()
        command.assert_not_called()
        self.assertTrue(result["downloadVerified"])
        self.assertFalse(result["payloadVerified"])
        self.assertFalse(result["diskImageVerified"])

    def test_shared_sha256sums_selects_only_the_exact_dmg(self):
        line = self.sha.read_text()
        self.sha = self.root / 'SHA256SUMS'
        self.sha.write_text('a' * 64 + '  keqdroid-0.18.0-macos-x64.dmg\n' + line)
        _, result = self.check()
        self.assertTrue(result['downloadVerified'])
        self.sha.write_text(line.upper().replace(self.dmg.name.upper(), self.dmg.name).replace('  ', ' *'))
        self.check()

    def test_shared_checksums_reject_missing_duplicate_or_ambiguous_targets(self):
        line = self.sha.read_text()
        self.sha = self.root / 'SHA256SUMS'
        cases = [
            line.replace('arm64', 'x64'),
            line.replace(self.dmg.name, self.dmg.name + '.backup'),
            line.replace(self.dmg.name, '../' + self.dmg.name),
            line + line,
            line + 'a' * 64 + '  ' + self.dmg.name + '\n',
            line + 'malformed checksum\n',
        ]
        for text in cases:
            with self.subTest(manifest=text):
                self.sha.write_text(text)
                with self.assertRaises(ValueError):
                    self.check()

    def test_retired_core_is_not_accepted_in_a_new_package_inventory(self):
        self.report['files']['runtime/bin/wireproxy'] = dict(
            self.report['files']['runtime/bin/keqrnel'])
        self.save_report()
        with self.assertRaisesRegex(ValueError, 'Unexpected packaged core'):
            self.check()

    def test_bad_hash_and_wrong_checksum_filename_rejected(self):
        self.dmg.write_bytes(b"altered image")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.check()
        self.sha.write_text("b" * 64 + "  another.dmg\n")
        with self.assertRaisesRegex(ValueError, "does not identify"):
            self.check()

    def test_wrong_commit_architecture_and_release_name_rejected(self):
        for key, value in (("sourceCommit", "d" * 40), ("architecture", "x64"), ("version", "0.19.0")):
            original = self.report[key]
            self.report[key] = value
            self.save_report()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check()
            self.report[key] = original

    def test_newer_macos_wrong_binary_arch_missing_component_and_path_escape_rejected(self):
        name = "runtime/bin/keqdis-network-service"
        original = dict(self.report["files"][name])
        for key, value in (("minimumMacOS", "12.0.1"), ("architecture", "x64")):
            self.report["files"][name][key] = value
            self.save_report()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check()
            self.report["files"][name] = dict(original)
        del self.report["files"][name]
        self.save_report()
        with self.assertRaisesRegex(ValueError, "omits required"):
            self.check()
        self.report["files"][name] = original
        self.report["files"]["../outside"] = original
        self.save_report()
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            self.check()

    def test_distribution_enforces_macos_and_architecture_before_installation(self):
        distribution = self.root / "Distribution"
        content = '''<installer-gui-script><options hostArchitectures="arm64"/>
        <volume-check><allowed-os-versions><os-version min="12.0"/></allowed-os-versions></volume-check>
        <pkg-ref id="io.github.caocaocc.keqdroid.installer">install-component.pkg</pkg-ref>
        </installer-gui-script>'''
        distribution.write_text(content)
        verify.check_distribution(distribution, "arm64")
        for updated in (content.replace('"arm64"', '"x86_64"'), content.replace('"12.0"', '"13.0"'),
                        content.replace("install-component.pkg", "other.pkg")):
            distribution.write_text(updated)
            with self.assertRaises(ValueError):
                verify.check_distribution(distribution, "arm64")

    def test_productbuild_embedded_references_and_bundle_metadata(self):
        distribution = self.root / "Distribution"
        for uninstall in (False, True):
            suffix = "uninstaller" if uninstall else "installer"
            name = "uninstall-component.pkg" if uninstall else "install-component.pkg"
            content = f'''<installer-gui-script><options hostArchitectures="arm64"/>
            <volume-check><allowed-os-versions><os-version min="12.0"/></allowed-os-versions></volume-check>
            <pkg-ref id="io.github.caocaocc.keqdroid.{suffix}">#{name}</pkg-ref>
            <pkg-ref id="io.github.caocaocc.keqdroid.{suffix}">
              <bundle-version><bundle id="io.github.caocaocc.keqdroid"/></bundle-version>
            </pkg-ref></installer-gui-script>'''
            distribution.write_text(content)
            verify.check_distribution(distribution, "arm64", uninstall=uninstall)
            for reference in ("#other.pkg", "../" + name, "##" + name,
                              "https://example.test/" + name, "#../" + name):
                with self.subTest(uninstall=uninstall, reference=reference):
                    distribution.write_text(content.replace("#" + name, reference))
                    with self.assertRaisesRegex(ValueError, "Unexpected component"):
                        verify.check_distribution(distribution, "arm64", uninstall=uninstall)

    def test_installer_script_comparison_reads_git_blob_without_executing_script(self):
        script = self.root / "preinstall"
        script.write_bytes(b"#!/bin/sh\nexit 0\n")
        with mock.patch.object(verify, "command", return_value=mock.Mock(stdout=script.read_bytes())) as command:
            verify.check_script(script, self.root, self.commit, "preinstall")
            command.assert_called_once_with("/usr/bin/git", "-C", self.root, "show",
                                            self.commit + ":tool/macos/installer/preinstall")
        with mock.patch.object(verify, "command", return_value=mock.Mock(stdout=b"different")):
            with self.assertRaisesRegex(ValueError, "differs"):
                verify.check_script(script, self.root, self.commit, "preinstall")

    def test_image_is_detached_when_package_validation_fails(self):
        calls = []

        def command(*arguments, **kwargs):
            calls.append(arguments)
            return mock.Mock(stdout=b"")

        with mock.patch.object(verify, "command", side_effect=command):
            with self.assertRaises(OSError):
                verify.inspect_payload(self.dmg, self.report, "arm64", self.commit, self.root)
        attach = next(call for call in calls if call[:2] == ("/usr/bin/hdiutil", "attach"))
        self.assertIn("-readonly", attach)
        self.assertEqual(calls[-1][:2], ("/usr/bin/hdiutil", "detach"))
        self.assertTrue(all(call[0] in ("/usr/bin/hdiutil", "/usr/sbin/pkgutil") for call in calls))

    def test_codesign_fingerprint_is_a_literal_requirement_instead_of_a_filename(self):
        stage = self.root / "stage"
        app, runtime = stage / "KEQDIS.app", stage / "runtime"
        (app / "Contents/Resources/cores").mkdir(parents=True)
        (runtime / "bin").mkdir(parents=True)
        hashes = {}
        for core in verify.CORES:
            data = core.encode()
            (runtime / "bin" / core).write_bytes(data)
            (app / "Contents/Resources/cores" / core).write_bytes(data)
            hashes[core] = {"sha256": hashlib.sha256(data).hexdigest()}
        (runtime / "client-requirement.txt").write_text(self.report["clientRequirement"])
        (runtime / "core-manifest.json").write_text(json.dumps(hashes))
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "io.github.caocaocc.keqdroid", "CFBundleExecutable": "KEQDIS"}))
        report = dict(self.report, files={}, coresAfterSigning=hashes)
        with mock.patch.object(verify, "command") as command:
            verify.inspect_stage(stage, report, "arm64")
        command.assert_called_once_with("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R",
                                        "=" + self.report["clientRequirement"], app)


if __name__ == "__main__":
    unittest.main()
