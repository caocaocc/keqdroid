import json
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
from macos import build_cores as builder


def fake_macho(path, arch="arm64", extra=b""):
    cpu = 0x0100000C if arch == "arm64" else 0x01000007
    path.write_bytes(struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
                     + struct.pack("<6I", 0x32, 24, 1, 12 << 16, 12 << 16, 0) + extra)
    path.chmod(0o755)


class CoreCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.manifest = self.directory / "manifest.json"
        self.manifest.write_bytes(builder.MANIFEST.read_bytes())
        self.patches = self.directory / "patches"
        shutil.copytree(builder.PATCHES, self.patches)
        self.output = self.directory / "components"
        self.patchers = [patch.object(builder, "MANIFEST", self.manifest),
                         patch.object(builder, "PATCHES", self.patches),
                         patch.object(builder, "OUTPUT", self.output)]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    def fingerprints(self):
        return {core: builder.json_digest(builder.core_inputs(core, "arm64")) for core in builder.CORES}

    def assert_changed(self, before, changed):
        after = self.fingerprints()
        self.assertEqual({core for core in builder.CORES if before[core] != after[core]}, set(changed))

    def change_patch(self, name):
        path = self.patches / name
        path.write_text(path.read_text() + "\n// fingerprint fixture\n")

    def build_fake(self, core, arch="arm64"):
        def run(command, source, env, label):
            fake_macho(Path(command[command.index("-o") + 1]), arch)
        with patch.object(builder, "run", run):
            builder.build_component(core, arch, self.output, self.directory, Path("go"), {})

    def invoke(self, *args):
        with patch.object(sys, "argv", ["build_cores.py", "--arch", "arm64", "--output-dir", str(self.output), *args]):
            builder.main()

    def test_mihomo_patch_does_not_invalidate_other_cores(self):
        before = self.fingerprints()
        self.change_patch("macos/mihomo-bootstrap-dns.patch")
        self.assert_changed(before, ("mihomo",))

    def test_dependency_patch_invalidates_only_its_consumers(self):
        before = self.fingerprints()
        self.change_patch("macos/xray-bootstrap-dns.patch")
        self.assert_changed(before, ("keqrnel",))
        before = self.fingerprints()
        self.change_patch("macos/privilegedapi/policy.go")
        self.assert_changed(before, ("keqrnel", "mihomo"))

    def test_shared_bootstrap_overlay_invalidates_all_cores(self):
        before = self.fingerprints()
        self.change_patch("macos/bootstrapdns/resolver.go")
        self.assert_changed(before, builder.CORES)

    def test_doh_lifecycle_patch_and_regression_invalidate_only_keqrnel(self):
        for patch_name in ("macos/singbox-doh-connection-lifetime.patch",
                           "macos/keqrnel-doh-lifetime-tests.patch"):
            with self.subTest(patch=patch_name):
                before = self.fingerprints()
                self.change_patch(patch_name)
                self.assert_changed(before, ("keqrnel",))

    def test_xray_physical_socket_regressions_run_with_bootstrap_checks(self):
        sources = {name: self.directory / name for name in builder.DEPENDENCIES["keqrnel"]}
        with patch.object(builder, "run") as commands:
            builder.test_sources(("keqrnel",), Path("go"), {}, sources)
        xray_calls = [call.args[0] for call in commands.call_args_list if call.args[1] == sources["xray"]]
        self.assertEqual(len(xray_calls), 1)
        self.assertIn("./transport/internet", xray_calls[0])
        self.assertIn("./features/dns/localdns", xray_calls[0])
        self.assertIn("^TestKeqdis", xray_calls[0])

    def test_darwin_route_dependency_invalidates_only_keqrnel(self):
        before = self.fingerprints()
        self.change_patch("macos/singtun-route-ownership.patch")
        self.assert_changed(before, ("keqrnel",))
        before = self.fingerprints()
        self.change_patch("macos/singtun/route_ownership_darwin.go")
        self.assert_changed(before, ("keqrnel",))
        before = self.fingerprints()
        manifest = json.loads(self.manifest.read_text())
        manifest["sources"]["singtun"]["sha256"] = "different-source"
        self.manifest.write_text(json.dumps(manifest))
        self.assert_changed(before, ("keqrnel",))

    def test_keqrnel_preparation_uses_pinned_route_dependency_for_build_and_tests(self):
        manifest = json.loads(self.manifest.read_text())
        with patch.object(builder, "download", return_value=Path("archive")), \
                patch.object(builder, "extract", side_effect=lambda archive, prefix, source: source.mkdir(parents=True)), \
                patch.object(builder, "run") as commands:
            sources = builder.prepare_sources(manifest, Path("go"), {}, ("keqrnel",))
        self.assertEqual(set(sources), {"keqrnel", "xray", "singbox", "singtun"})
        replacements = [call.args for call in commands.call_args_list
                        if "github.com/sagernet/sing-tun=../singtun" in call.args[0]]
        self.assertEqual({args[1].name for args in replacements}, {"keqrnel", "singbox"})
        self.assertTrue((sources["singtun"] / "route_ownership_darwin.go").exists())
        with patch.object(builder, "run") as tests:
            builder.test_sources(("keqrnel",), Path("go"), {}, sources)
        self.assertIn("test-singtun-route-ownership", [call.args[-1] for call in tests.call_args_list])

    def test_unrelated_manifest_source_and_documentation_are_excluded(self):
        before = self.fingerprints()
        self.change_patch("macos/README.md")
        self.assert_changed(before, ())
        manifest = json.loads(self.manifest.read_text())
        manifest["sources"]["wireproxy"]["version"] = "fixture-version"
        self.manifest.write_text(json.dumps(manifest))
        self.assert_changed(before, ("wireproxy",))

    def test_toolchain_architecture_and_flags_invalidate_inputs(self):
        for core in builder.CORES:
            self.assertNotEqual(builder.core_inputs(core, "arm64"), builder.core_inputs(core, "x64"))
        before = self.fingerprints()
        manifest = json.loads(self.manifest.read_text())
        manifest["go"]["version"] = "different-version"
        self.manifest.write_text(json.dumps(manifest))
        self.assert_changed(before, builder.CORES)
        before = self.fingerprints()
        manifest["sources"]["mihomo"]["tags"].append("fixture")
        self.manifest.write_text(json.dumps(manifest))
        self.assert_changed(before, ("mihomo",))

    def test_single_core_preparation_does_not_download_other_sources(self):
        manifest = json.loads(self.manifest.read_text())
        downloads = []

        def download(spec, name):
            downloads.append(name)
            return Path(name)

        def extract(archive, prefix, source):
            (source / "cmd/wireproxy").mkdir(parents=True)

        with patch.object(builder, "download", download), patch.object(builder, "extract", extract), \
                patch.object(builder, "run") as commands:
            sources = builder.prepare_sources(manifest, Path("go"), {}, ("wireproxy",))
        self.assertEqual(set(sources), {"wireproxy"})
        self.assertEqual(downloads, ["wireproxy.zip"])
        commands.assert_not_called()
        self.assertTrue((sources["wireproxy"] / "internal/keqdisdns/resolver.go").exists())
        self.assertTrue((sources["wireproxy"] / "cmd/wireproxy/bootstrap_init_darwin.go").exists())

    def test_targeted_tests_do_not_require_other_source_directories(self):
        with patch.object(builder, "run") as run:
            builder.test_sources(("wireproxy",), Path("go"), {}, {"wireproxy": self.directory})
        self.assertEqual([call.args[-1] for call in run.call_args_list], ["test-bootstrapdns"])

    def test_successful_checkpoint_survives_next_core_preparation_failure_and_resume(self):
        prepared = []
        compiled = []

        def prepare(manifest, go, env, cores):
            core = cores[0]
            prepared.append(core)
            if core == "mihomo":
                raise RuntimeError("simulated source download failure")
            return {core: self.directory}

        def compile(command, source, env, label):
            core = label.split("-")[1]
            compiled.append(core)
            fake_macho(Path(command[command.index("-o") + 1]))

        with patch.object(builder.platform, "system", return_value="Darwin"), \
                patch.object(builder, "toolchain", return_value=(Path("go"), {})), \
                patch.object(builder, "test_sources"), patch.object(builder, "run", compile), \
                patch.object(builder, "prepare_sources", prepare):
            with self.assertRaisesRegex(RuntimeError, "simulated"):
                self.invoke()
        self.assertEqual(compiled, ["keqrnel"])
        builder.validate_component(self.output, "keqrnel", "arm64")
        self.assertFalse((self.output / "provenance.json").exists())
        prepared.clear()

        def prepare_remaining(manifest, go, env, cores):
            prepared.extend(cores)
            return {core: self.directory for core in cores}

        with patch.object(builder.platform, "system", return_value="Darwin"), \
                patch.object(builder, "toolchain", return_value=(Path("go"), {})), \
                patch.object(builder, "test_sources"), patch.object(builder, "run", compile), \
                patch.object(builder, "prepare_sources", prepare_remaining):
            self.invoke()
        self.assertEqual(prepared, ["mihomo", "wireproxy"])
        self.assertEqual(compiled, ["keqrnel", "mihomo", "wireproxy"])
        self.assertEqual(set(json.loads((self.output / "provenance.json").read_text())["binaries"]), set(builder.CORES))

    def test_assemble_only_never_downloads_builds_or_requires_macos(self):
        for core in builder.CORES:
            self.build_fake(core)
        with patch.object(builder.platform, "system", return_value="Linux"), \
                patch.object(builder, "toolchain", side_effect=AssertionError("must not download Go")), \
                patch.object(builder, "prepare_sources", side_effect=AssertionError("must not prepare sources")), \
                patch.object(builder, "run", side_effect=AssertionError("must not compile")):
            self.invoke("--assemble-only")
            self.invoke()
        aggregate = json.loads((self.output / "provenance.json").read_text())
        self.assertEqual(aggregate, builder.validate_core_set(self.output, "arm64"))

    def test_corruption_wrong_architecture_and_stale_inputs_are_rejected(self):
        for core in builder.CORES:
            self.build_fake(core)
        with self.assertRaises(ValueError):
            builder.validate_core_set(self.output, "x64")
        path = self.output / "mihomo"
        contents = path.read_bytes()
        path.write_bytes(contents + b"modified")
        with self.assertRaisesRegex(ValueError, "hash"):
            builder.validate_core_set(self.output, "arm64")
        path.write_bytes(contents)
        self.change_patch("macos/mihomo-bootstrap-dns.patch")
        with self.assertRaisesRegex(ValueError, "inputs"):
            builder.validate_core_set(self.output, "arm64")

    def test_modified_record_cannot_authorize_a_modified_binary(self):
        self.build_fake("wireproxy")
        path = self.output / "wireproxy-provenance.json"
        record = json.loads(path.read_text())
        record["inputs"]["sources"]["wireproxy"]["version"] = "untrusted"
        record["inputsSHA256"] = builder.json_digest(record["inputs"])
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, "inputs"):
            builder.validate_component(self.output, "wireproxy", "arm64")

    def test_failed_binary_validation_does_not_replace_a_successful_checkpoint(self):
        self.build_fake("wireproxy")
        original = (self.output / "wireproxy").read_bytes()
        original_record = (self.output / "wireproxy-provenance.json").read_bytes()

        def compile(command, source, env, label):
            Path(command[command.index("-o") + 1]).write_bytes(b"truncated")

        with patch.object(builder, "run", compile), self.assertRaisesRegex(ValueError, "Truncated"):
            builder.build_component("wireproxy", "arm64", self.output, self.directory, Path("go"), {})
        self.assertEqual((self.output / "wireproxy").read_bytes(), original)
        self.assertEqual((self.output / "wireproxy-provenance.json").read_bytes(), original_record)

    def test_symlink_component_and_nonexecutable_binary_are_rejected(self):
        self.build_fake("wireproxy")
        binary = self.output / "wireproxy"
        binary.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "executable"):
            builder.validate_component(self.output, "wireproxy", "arm64")
        actual = self.directory / "outside"
        binary.replace(actual)
        actual.chmod(0o755)
        binary.symlink_to(actual)
        with self.assertRaisesRegex(ValueError, "Invalid component"):
            builder.validate_component(self.output, "wireproxy", "arm64")


if __name__ == "__main__":
    unittest.main()
