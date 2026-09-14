"""Merged Android identities are checked from aapt output, not source text."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci"))
import verify_android

BADGING = "package: name='io.github.caocaocc.keqdroid' versionCode='48' versionName='0.20.0' platformBuildVersionName='14'\n"
MANIFEST = '''N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=1)
    E: application (line=1)
      E: activity (line=1)
        A: android:name(0x01010003)="com.keqdroid.keqdroid.MainActivity"
        E: meta-data (line=1)
          A: android:name(0x01010003)="android.app.shortcuts"
          A: android:resource(0x01010025)=@0x7f020000
      E: provider (line=1)
        A: android:name(0x01010003)="com.keqdroid.keqdroid.VpnStatusProvider"
        A: android:exported(0x01010010)=(type 0x12)0x0
        A: android:authorities(0x01010018)="io.github.caocaocc.keqdroid.vpnstatus"
'''
RESOURCES = '''      config (default):
        resource 0x7f020000 io.github.caocaocc.keqdroid:xml/shortcuts: t=0x03 d=0x00000000
          (string8) "res/xml/shortcuts.xml"
        resource 0x7f030000 io.github.caocaocc.keqdroid:string/application_id: t=0x03 d=0x00000001
          (string8) "io.github.caocaocc.keqdroid"
'''
SHORTCUTS = '''N: android=http://schemas.android.com/apk/res/android
  E: shortcuts (line=1)
'''
for name in ("connect", "disconnect"):
    SHORTCUTS += f'''    E: shortcut (line=1)
      A: android:shortcutId(0x01010528)="{name}"
      E: intent (line=1)
        A: android:targetPackage(0x01010021)=@0x7f030000
        A: android:action(0x0101002d)="android.intent.action.MAIN"
        A: android:targetClass(0x0101002f)="com.keqdroid.keqdroid.MainActivity"
'''


class AndroidIdentityTests(unittest.TestCase):
    def inspect(self, badging=BADGING, manifest=MANIFEST, resources=RESOURCES, shortcuts=SHORTCUTS):
        return verify_android.inspect_identity(badging, manifest, resources,
            {"res/xml/shortcuts.xml": shortcuts}, "0.20.0", "48")

    def test_merged_identity_and_resource_reference_are_verified(self):
        report = self.inspect()
        self.assertEqual(report["providerAuthority"], "io.github.caocaocc.keqdroid.vpnstatus")
        self.assertEqual(report["shortcutIds"], ["connect", "disconnect"])

    def test_old_shortcut_application_resource_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "different application"):
            self.inspect(resources=RESOURCES.replace('"io.github.caocaocc.keqdroid"', '"com.keqdroid.keqdroid"'))

    def test_conflicting_localized_package_resource_is_rejected(self):
        resources = RESOURCES + '''      config fr:
        resource 0x7f030000 io.github.caocaocc.keqdroid:string/application_id: t=0x03
          (string16) "com.keqdroid.keqdroid"
'''
        with self.assertRaisesRegex(ValueError, "inconsistent"):
            self.inspect(resources=resources)

    def test_wrong_provider_export_activity_and_version_are_rejected(self):
        for bad in [MANIFEST.replace("io.github.caocaocc.keqdroid.vpnstatus", "com.keqdroid.keqdroid.vpnstatus"),
                    MANIFEST.replace("(type 0x12)0x0", "(type 0x12)0xffffffff"),
                    MANIFEST.replace("com.keqdroid.keqdroid.MainActivity", "io.github.caocaocc.keqdroid.MainActivity")]:
            with self.subTest(manifest=bad), self.assertRaises(ValueError):
                self.inspect(manifest=bad)
        with self.assertRaisesRegex(ValueError, "version"):
            self.inspect(badging=BADGING.replace("versionCode='48'", "versionCode='47'"))

    def test_missing_disconnect_or_foreign_shortcut_class_rejected(self):
        for bad in [SHORTCUTS.replace('"disconnect"', '"connect"'),
                    SHORTCUTS.replace("com.keqdroid.keqdroid.MainActivity", "another.MainActivity")]:
            with self.subTest(shortcuts=bad), self.assertRaises(ValueError):
                self.inspect(shortcuts=bad)

    def test_relocated_resource_path_is_taken_from_manifest(self):
        result = verify_android.inspect_identity(BADGING, MANIFEST,
            RESOURCES.replace("res/xml/shortcuts.xml", "res/a.xml"),
            {"res/a.xml": SHORTCUTS}, "0.20.0", "48")
        self.assertEqual(result["shortcutResource"], "res/a.xml")


class AndroidNativeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.apk = self.root / "app.apk"
        self.elf = bytearray(64)
        self.elf[:6] = b"\x7fELF\x02\x01"
        self.elf[18:20] = (183).to_bytes(2, "little")
        for name in ("libxray.so", "libmihomo.so"):
            source = self.root / "android/app/src/main/jniLibs/arm64-v8a" / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(self.elf + b"upstream debug symbols")

    def payload(self, extra=None):
        with zipfile.ZipFile(self.apk, "w") as archive:
            for name in ("libxray.so", "libmihomo.so"):
                archive.writestr("lib/arm64-v8a/" + name, self.elf)
            if extra:
                archive.writestr(*extra)

    def test_stripping_keeps_arm64_identity_and_records_both_hashes(self):
        self.payload()
        report = verify_android.inspect_native(self.apk, self.root)
        core = report["lib/arm64-v8a/libxray.so"]
        self.assertEqual(core["packagedSHA256"], hashlib.sha256(self.elf).hexdigest())
        self.assertNotEqual(core["packagedSHA256"], core["sourceSHA256"])

    def test_foreign_abi_and_wrong_elf_architecture_rejected(self):
        self.payload(("lib/x86_64/libapp.so", self.elf))
        with self.assertRaisesRegex(ValueError, "architecture"):
            verify_android.inspect_native(self.apk, self.root)
        self.elf[18:20] = (62).to_bytes(2, "little")
        self.payload()
        with self.assertRaisesRegex(ValueError, "AArch64"):
            verify_android.inspect_native(self.apk, self.root)

    def test_missing_core_is_rejected(self):
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("lib/arm64-v8a/libapp.so", self.elf)
        with self.assertRaisesRegex(ValueError, "missing native"):
            verify_android.inspect_native(self.apk, self.root)


class AndroidSigningTests(unittest.TestCase):
    digest = "a" * 64

    def test_actual_build_tools_37_ci_evidence(self):
        fixture = Path(__file__).resolve().parents[2] / "test/fixtures/android/apksigner-37-v2.json"
        evidence = json.loads(fixture.read_text())
        self.assertEqual(evidence["exitCode"], 0)
        self.assertIn("Verified using v2 scheme (APK Signature Scheme v2): true", evidence["evidence"])
        result = verify_android.verify_signing_output("\n".join(evidence["evidence"]), evidence["expectedCertificateSHA256"])
        self.assertEqual(result["signerCertificateRecords"], 1)
        self.assertEqual(result["signingCertificateSHA256"], evidence["expectedCertificateSHA256"])

    def test_numbered_and_sdk_targeted_signer_formats_match_exact_digest(self):
        for label in ["Signer #1", "V2 Signer:", "Signer (minSdkVersion=33, maxSdkVersion=2147483647)",
                      "Signer (minSdkVersion=33 (dev release=true), maxSdkVersion=2147483647)"]:
            with self.subTest(label=label):
                result = verify_android.verify_signing_output(f"{label} certificate SHA-256 digest: {self.digest.upper()}\n", self.digest)
                self.assertEqual(result["signingCertificateSHA256"], self.digest)

    def test_wrong_signer_is_not_masked_by_a_matching_source_stamp(self):
        output = f"Signer #1 certificate SHA-256 digest: {'b' * 64}\nSource Stamp Signer certificate SHA-256 digest: {self.digest}\n"
        with self.assertRaisesRegex(ValueError, "mismatch"):
            verify_android.verify_signing_output(output, self.digest)

    def test_every_sdk_targeted_signer_must_match(self):
        output = f"Signer (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: {self.digest}\nSigner (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: {'b' * 64}\n"
        with self.assertRaisesRegex(ValueError, "mismatch"):
            verify_android.verify_signing_output(output, self.digest)

    def test_public_key_hash_missing_signer_and_malformed_digest_are_rejected(self):
        for output in ["", f"Signer #1 public key SHA-256 digest: {self.digest}",
                       f"Source Stamp Signer certificate SHA-256 digest: {self.digest}"]:
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "no recognized"):
                verify_android.verify_signing_output(output, self.digest)


    def test_valid_record_cannot_hide_malformed_or_unknown_extra_signer(self):
        valid = f"Signer #1 certificate SHA-256 digest: {self.digest}\n"
        for invalid in ["Signer #2 certificate SHA-256 digest: abcd",
                        "V2 Signer: certificate SHA-256 digest: abcd",
                        f"V99 Signer: certificate SHA-256 digest: {self.digest}",
                        f"V2 Signer: certificate SHA-256 digest: {'b' * 64}",
                        f"Signer (unknown SDK format) certificate SHA-256 digest: {self.digest}"]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                verify_android.verify_signing_output(valid + invalid, self.digest)


if __name__ == "__main__":
    unittest.main()
