"""Partial Flutter cache recovery without Flutter, CMake, network or compilers."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool/ci"))
import native_assets_cache


class NativeAssetsCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / "bundle"

    def write(self, path, data=b"cached output"):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def cache(self, family="linux", names=()):
        directory = self.root / ".dart_tool/flutter_build" / (family + "-hash")
        output = self.root / "build/native_assets" / family
        output.mkdir(parents=True)
        manifest = directory / "native_assets.json"
        target = family + "_x64"
        value = {"format-version": [1, 0, 0], "native-assets": {
            target: {f"package:test/{name}": ["absolute", name] for name in names}
        } if names else {}}
        self.write(manifest, json.dumps(value).encode())
        generated = [self.write(output / name) for name in names]
        stamp = self.write(directory / "install_code_assets.stamp", json.dumps({
            "inputs": [str(directory / "dart_build_result.json")],
            "outputs": [str(manifest), *(str(path) for path in generated)],
        }).encode())
        # DartBuild results and expensive compilation caches must all survive.
        retained = [self.write(directory / name) for name in (
            "dart_build.stamp", "dart_build_result.json", "dart_build.d",
            "install_code_assets.d", "kernel_snapshot_program.stamp", "app.so",
            f"unpack_{family}.stamp", f"release_bundle_{family}-x64_assets.stamp")]
        retained += [self.write(f"build/{family}/x64/plugin/runner.o"),
                     self.write(".dart_tool/hooks_runner/shared-library.so")]
        return stamp, manifest, output, retained

    def install_fixture(self, manifest, output, family="linux"):
        self.write(self.bundle / "data/flutter_assets/NativeAssetsManifest.json", manifest.read_bytes())
        for source in output.iterdir():
            target = self.bundle / "lib" / source.name if family == "linux" else self.bundle / source.name
            self.write(target, source.read_bytes())

    def test_missing_empty_directory_invalidates_installation_only(self):
        stamp, manifest, output, retained = self.cache()
        contents = {path: path.read_bytes() for path in [manifest, *retained]}
        output.rmdir()
        repaired = native_assets_cache.repair_native_assets_cache("linux-x64", self.root)
        self.assertEqual(len(repaired), 1)
        # Flutter's Node.withNoStamp is dirty: next assemble reruns installation.
        self.assertFalse(stamp.exists())
        self.assertFalse(output.exists(), "Recovery must let Flutter generate its own output")
        self.assertIn("Missing output directory", repaired[0]["reasons"][0])
        self.assertEqual({path: path.read_bytes() for path in contents}, contents)
        self.assertEqual(native_assets_cache.repair_native_assets_cache("linux-x64", self.root), [])

    def test_complete_cache_reuses_empty_or_real_native_assets(self):
        for names in ((), ("libexample.so",)):
            with self.subTest(names=names):
                root = self.root / ("empty" if not names else "populated")
                root.mkdir()
                original_root, self.root = self.root, root
                stamp, manifest, output, retained = self.cache(names=names)
                paths = [stamp, manifest, *retained, *output.iterdir()]
                state = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in paths}
                self.assertEqual(native_assets_cache.repair_native_assets_cache("linux-x64", self.root), [])
                self.assertEqual({path: (path.read_bytes(), path.stat().st_mtime_ns) for path in paths}, state)
                self.root = original_root

    def test_missing_library_with_existing_directory_invalidates_installation(self):
        stamp, _, output, retained = self.cache(names=("libexample.so",))
        (output / "libexample.so").unlink()
        result = native_assets_cache.repair_native_assets_cache("linux-x64", self.root)
        self.assertTrue(output.is_dir())
        self.assertFalse(stamp.exists())
        self.assertIn("libexample.so", " ".join(result[0]["reasons"]))
        self.assertTrue(all(path.is_file() for path in retained))

    def test_missing_manifest_or_corrupt_stamp_invalidates_installation(self):
        stamp, manifest, _, _ = self.cache()
        manifest.unlink()
        native_assets_cache.repair_native_assets_cache("linux-x64", self.root)
        self.assertFalse(stamp.exists())
        stamp.write_text("not JSON", encoding="utf-8")
        result = native_assets_cache.repair_native_assets_cache("linux-x64", self.root)
        self.assertFalse(stamp.exists())
        self.assertIn("Unreadable", result[0]["reasons"][0])

    def test_windows_uses_same_target_without_invalidating_linux_graph(self):
        linux_stamp, _, linux_output, _ = self.cache()
        windows_stamp, _, windows_output, _ = self.cache("windows")
        linux_output.rmdir()
        windows_output.rmdir()
        result = native_assets_cache.repair_native_assets_cache("windows-x64", self.root)
        self.assertEqual(len(result), 1)
        self.assertTrue(linux_stamp.is_file())
        self.assertFalse(windows_stamp.exists())

    def test_android_macos_and_fresh_workspace_are_untouched(self):
        self.assertEqual(native_assets_cache.repair_native_assets_cache("linux-x64", self.root), [])
        self.assertFalse((self.root / "build").exists())
        stamp, _, output, _ = self.cache()
        output.rmdir()
        for platform in ("android-arm64", "macos-arm64", "macos-x64"):
            self.assertEqual(native_assets_cache.repair_native_assets_cache(platform, self.root), [])
            self.assertEqual(native_assets_cache.verify_native_assets(platform, self.bundle, self.root), {})
            self.assertTrue(stamp.exists())

    def test_real_native_asset_must_reach_linux_bundle_with_matching_bytes(self):
        _, manifest, output, _ = self.cache(names=("libexample.so",))
        self.install_fixture(manifest, output)
        expected = hashlib.sha256(b"cached output").hexdigest()
        self.assertEqual(native_assets_cache.verify_native_assets("linux-x64", self.bundle, self.root),
                         {"lib/libexample.so": expected})
        bundled = self.bundle / "lib/libexample.so"
        bundled.unlink()
        with self.assertRaisesRegex(ValueError, "Missing bundled"):
            native_assets_cache.verify_native_assets("linux-x64", self.bundle, self.root)
        bundled.write_bytes(b"stale cached library")
        with self.assertRaisesRegex(ValueError, "differs from generated"):
            native_assets_cache.verify_native_assets("linux-x64", self.bundle, self.root)

    def test_restored_manifest_cannot_silently_lose_a_real_asset(self):
        _, manifest, output, _ = self.cache(names=("libexample.so",))
        self.install_fixture(manifest, output)
        (output / "libexample.so").unlink()
        with self.assertRaisesRegex(ValueError, "missing=.*libexample"):
            native_assets_cache.verify_native_assets("linux-x64", self.bundle, self.root)
        shutil.rmtree(output)
        with self.assertRaisesRegex(ValueError, "did not produce"):
            native_assets_cache.verify_native_assets("linux-x64", self.bundle, self.root)

    def test_windows_bundle_installs_native_libraries_at_root(self):
        _, manifest, output, _ = self.cache("windows", ("example.dll",))
        self.install_fixture(manifest, output, "windows")
        self.assertEqual(list(native_assets_cache.verify_native_assets("windows-x64", self.bundle, self.root)),
                         ["example.dll"])

    def test_empty_assets_require_flutter_directory_and_manifest(self):
        _, manifest, output, _ = self.cache()
        self.install_fixture(manifest, output)
        self.assertEqual(native_assets_cache.verify_native_assets("linux-x64", self.bundle, self.root), {})
        (self.bundle / "data/flutter_assets/NativeAssetsManifest.json").unlink()
        with self.assertRaisesRegex(ValueError, "manifest missing"):
            native_assets_cache.verify_native_assets("linux-x64", self.bundle, self.root)

    def test_generated_file_cannot_be_silently_omitted_from_manifest(self):
        _, manifest, output, _ = self.cache()
        self.install_fixture(manifest, output)
        self.write(output / "unlisted.so")
        with self.assertRaisesRegex(ValueError, "unlisted=.*unlisted"):
            native_assets_cache.verify_native_assets("linux-x64", self.bundle, self.root)

    def test_non_bundled_lookups_do_not_require_libraries(self):
        _, manifest, output, _ = self.cache()
        manifest.write_text(json.dumps({"format-version": [1, 0, 0], "native-assets": {"linux_x64": {
            "package:test/process": ["process"], "package:test/executable": ["executable"],
            "package:test/system": ["system", "libc.so.6"],
        }}}), encoding="utf-8")
        self.install_fixture(manifest, output)
        self.assertEqual(native_assets_cache.verify_native_assets("linux-x64", self.bundle, self.root), {})

    def test_wrong_platform_or_unsafe_manifest_asset_is_rejected(self):
        for targets in ({"windows_x64": {}}, {"linux_x64": {"package:test/escape": ["absolute", "../bad.so"]}}):
            with self.subTest(targets=targets), self.assertRaises(ValueError):
                native_assets_cache._bundled_names({"format-version": [1, 0, 0], "native-assets": targets}, "linux-x64")

    def test_workflow_saves_and_restores_native_outputs_with_flutter_stamps(self):
        workflow = (ROOT / ".github/workflows/platform-component.yml").read_text(encoding="utf-8")
        paths = re.findall(r"(?m)^ {10}path: \|\n((?: {12}.+\n)+)", workflow)
        intermediate_groups = [group.split() for group in paths if ".dart_tool/flutter_build" in group]
        self.assertEqual(len(intermediate_groups), 2)
        self.assertEqual(intermediate_groups[0], intermediate_groups[1])
        self.assertIn("build/native_assets", intermediate_groups[0])
        self.assertIn("build/linux", intermediate_groups[0])
        self.assertIn("build/windows", intermediate_groups[0])


if __name__ == "__main__":
    unittest.main()
