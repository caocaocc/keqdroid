"""Version probing accepts one pinned machine object and keeps failure evidence."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool/ci"))
import build_platform

VERSION = {"frameworkVersion": "3.44.4", "flutterVersion": "3.44.4",
           "frameworkRevision": "ad70ec4617166f1c38e5d2bfd388af71fda14f06",
           "engineRevision": "a10d8ac38de835021c8d2f920dbf50a920ccc030",
           "dartSdkVersion": "3.12.2", "flutterRoot": "C:\\SDK\\Flutter 中文"}
MACHINE = json.dumps(VERSION, ensure_ascii=False, indent=2).encode("utf-8")


class FlutterVersionTests(unittest.TestCase):
    def test_clean_machine_output_preserves_full_version_metadata(self):
        self.assertEqual(build_platform.parse_flutter_version(MACHINE, "3.44.4"), VERSION)

    def test_upgrade_banner_ansi_bom_and_windows_line_endings_are_not_json(self):
        # The message comes from pinned Flutter's version.dart. Whether it
        # actually caused the original CI failure is unknown: output was lost.
        prefix = ('\ufeff\x1b[33m┌──────────────────────────────────────┐\r\n'
                  '│ A new version of Flutter is available! │\r\n'
                  '│ To update to the latest version, run "flutter upgrade". │\r\n'
                  '└──────────────────────────────────────┘\x1b[0m\r\n')
        raw = prefix.encode("utf-8") + MACHINE.replace(b"\n", b"\r\n") + b"\r\n"
        self.assertEqual(build_platform.parse_flutter_version(raw, "3.44.4"), VERSION)
        self.assertEqual(build_platform.parse_flutter_version(b"\x1b[32m" + MACHINE + b"\x1b[0m", "3.44.4"), VERSION)

    def test_empty_corrupt_non_object_or_ambiguous_output_is_rejected(self):
        wrong = json.dumps({**VERSION, "frameworkVersion": "3.45.0"}).encode()
        cases = [b"", b"Flutter 3.44.4", b'{"frameworkVersion":',
                 b'{broken}\n' + MACHINE, b"[" + MACHINE + b"]",
                 b"null\n" + MACHINE, b"42\n" + MACHINE,
                 b"true false\n" + MACHINE, b"null startup notice\n" + MACHINE,
                 b'"another value"\n' + MACHINE, b"[]\n" + MACHINE,
                 MACHINE + MACHINE, wrong + MACHINE, MACHINE + wrong,
                 MACHINE + b" trailing output", b"\xff\n" + MACHINE,
                 MACHINE.replace(b"3.44.4", b"3.44.\x1b[31m4"),
                 MACHINE.replace(b'"frameworkVersion": "3.44.4",',
                                 b'"frameworkVersion": "wrong", "frameworkVersion": "3.44.4",')]
        for raw in cases:
            with self.subTest(output=raw[:70]), self.assertRaises((ValueError, UnicodeError)):
                build_platform.parse_flutter_version(raw, "3.44.4")

    def test_wrong_version_and_incomplete_machine_metadata_are_rejected(self):
        for changes in ({"frameworkVersion": "3.45.0"}, {"flutterVersion": "3.45.0"},
                        {"frameworkRevision": "unknown"}, {"engineRevision": None},
                        {"dartSdkVersion": ""}, {"flutterVersion": None}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                build_platform.parse_flutter_version(json.dumps({**VERSION, **changes}).encode(), "3.44.4")

    def test_probe_persists_exact_stdout_stderr_even_when_parsing_fails(self):
        for output in (b"", b'{"frameworkVersion":', MACHINE):
            with self.subTest(output=output[:40]), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                result = subprocess.CompletedProcess([], 0, output, b"diagnostic\r\n")
                with patch.object(build_platform, "ROOT", root), patch.object(build_platform, "run", return_value=result) as run:
                    if output == MACHINE:
                        self.assertEqual(build_platform.flutter_version(), VERSION)
                    else:
                        with self.assertRaisesRegex(ValueError, "flutter-version.stdout.log"):
                            build_platform.flutter_version()
                run.assert_called_once_with("flutter", "--no-version-check", "--version", "--machine",
                                            capture_output=True, timeout=120)
                logs = root / "build/platform-logs"
                self.assertEqual((logs / "flutter-version.stdout.log").read_bytes(), output)
                self.assertEqual((logs / "flutter-version.stderr.log").read_bytes(), b"diagnostic\r\n")
                self.assertEqual(json.loads((logs / "flutter-version.json").read_text(encoding="utf-8"))["stdoutBytes"], len(output))

    def test_nonzero_exit_or_timeout_preserves_partial_output_before_failing(self):
        failures = [subprocess.CalledProcessError(2, ["flutter"], b"partial", b"bad SDK"),
                    subprocess.TimeoutExpired(["flutter"], 120, b"partial", b"still waiting")]
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                with patch.object(build_platform, "ROOT", root), patch.object(build_platform, "run", side_effect=failure):
                    with self.assertRaises(type(failure)):
                        build_platform.flutter_version()
                logs = root / "build/platform-logs"
                self.assertEqual((logs / "flutter-version.stdout.log").read_bytes(), b"partial")
                self.assertEqual((logs / "flutter-version.stderr.log").read_bytes(), failure.stderr)
                evidence = json.loads((logs / "flutter-version.json").read_text(encoding="utf-8"))
                self.assertEqual(evidence["timedOut"], isinstance(failure, subprocess.TimeoutExpired))


class ApplicationBuildTests(unittest.TestCase):
    def test_partial_cache_is_repaired_before_build_and_bundle_evidence_is_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            graph = root / ".dart_tool/flutter_build/test-graph"
            graph.mkdir(parents=True)
            manifest = graph / "native_assets.json"
            manifest.write_text('{"format-version":[1,0,0],"native-assets":{}}', encoding="utf-8")
            stamp = graph / "install_code_assets.stamp"
            stamp.write_text(json.dumps({"outputs": [str(manifest)]}), encoding="utf-8")
            obj = root / "build/linux/x64/plugin.o"
            obj.parent.mkdir(parents=True)
            obj.write_bytes(b"expensive native compilation")
            for name in ("keqrnel", "mihomo"):
                source = root / "assets/bin/linux" / name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(b"tracked executable")

            def command(*args, **kwargs):
                if args[:3] == ("flutter", "pub", "get"):
                    self.assertTrue(stamp.exists())
                if args[:3] == ("flutter", "build", "linux"):
                    self.assertFalse(stamp.exists())
                    self.assertEqual(obj.read_bytes(), b"expensive native compilation")
                    self.assertFalse((root / "build/native_assets/linux").exists())
                    # Only Flutter, not the repair code, regenerates outputs.
                    (root / "build/native_assets/linux").mkdir(parents=True)
                    assets = root / "build/linux/x64/release/bundle/data/flutter_assets"
                    assets.mkdir(parents=True)
                    (assets / "NativeAssetsManifest.json").write_bytes(manifest.read_bytes())
                return subprocess.CompletedProcess(args, 0)

            destination = root / "component"
            with patch.object(build_platform, "ROOT", root), \
                    patch.object(build_platform.checkpoint, "fingerprint", return_value="pinned"), \
                    patch.dict(build_platform.os.environ, {"EXPECTED_APP_FINGERPRINT": "pinned"}), \
                    patch.object(build_platform.checkpoint.archive_tools, "source_commit", return_value="a" * 40), \
                    patch.object(build_platform, "flutter_version", return_value=VERSION), \
                    patch.object(build_platform, "verify_payload", return_value={}), \
                    patch.object(build_platform, "run", side_effect=command):
                build_platform.build("linux-x64", destination)
            report = json.loads((destination / "component-build.json").read_text())
            self.assertEqual(report["verification"]["nativeAssets"], {})
            self.assertEqual(obj.read_bytes(), b"expensive native compilation")


if __name__ == "__main__":
    unittest.main()
