"""Checkpoint safety and cross-commit reuse without a GitHub token or network."""

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import urllib.error
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "macos"))
import ci_artifacts as ci


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.root, self.source = self.base / "repo", self.base / "source"
        self.root.mkdir()
        self.source.mkdir()
        for name in (
            "tool/macos/ci_artifacts.py", "tool/macos/build_helper.sh",
            "macos/NetworkService/Package.swift", "macos/NetworkService/Sources/main.swift",
            "macos/NetworkService/Tests/main.swift",
        ):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n")
        executable = self.source / "keqdis-network-service"
        executable.write_bytes(b"a tested Mach-O fixture\n")
        executable.chmod(0o755)
        self.archive = self.base / "helper-arm64.tar"
        self.destination = self.base / "restored"
        self.commit = "a" * 40
        self.value = ci.fingerprint("helper", "arm64", self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def pack(self):
        return ci.pack("helper", "arm64", self.source, self.archive, self.root, self.commit)

    def restore(self, archive=None):
        return ci.restore("helper", "arm64", archive or self.archive, self.destination, self.root)

    def rewrite(self, mutate_manifest=None, mutate_member=None, extra=None):
        output = self.base / "changed.tar"
        with tarfile.open(self.archive) as source, tarfile.open(output, "w") as target:
            for member in source:
                data = source.extractfile(member).read() if member.isfile() else None
                if member.name == "manifest.json" and mutate_manifest:
                    manifest = json.loads(data)
                    mutate_manifest(manifest)
                    data = ci.canonical_json(manifest)
                    member.size = len(data)
                if mutate_member:
                    member, data = mutate_member(member, data)
                if member:
                    target.addfile(member, io.BytesIO(data) if data is not None else None)
            if extra:
                member, data = extra
                target.addfile(member, io.BytesIO(data) if data is not None else None)
        return output


class FingerprintTests(Fixture):
    def test_retired_wireproxy_cannot_restore_a_new_checkpoint(self):
        with self.assertRaises(ValueError):
            ci.fingerprint('wireproxy', 'arm64', self.root)

    def test_commit_is_provenance_not_part_of_input_key(self):
        first = self.pack()
        self.commit = "b" * 40
        second = self.pack()
        self.assertEqual(first["fingerprint"], second["fingerprint"])
        self.assertNotEqual(first["source-commit"], second["source-commit"])
        result = self.restore()
        self.assertEqual(result["source-commit"], self.commit)

    def test_helper_source_toolchain_arch_and_build_recipe_are_inputs(self):
        for relative in ("macos/NetworkService/Sources/main.swift", "tool/macos/build_helper.sh"):
            path = self.root / relative
            original = path.read_text()
            path.write_text(original + "changed")
            self.assertNotEqual(ci.fingerprint("helper", "arm64", self.root), self.value)
            path.write_text(original)
        self.assertNotEqual(ci.fingerprint("helper", "x64", self.root), self.value)
        with mock.patch.dict(ci.TOOLCHAIN, xcodeBuild="new-build"):
            self.assertNotEqual(ci.fingerprint("helper", "arm64", self.root), self.value)

    def test_installer_packager_and_generated_build_files_do_not_invalidate_helper(self):
        for relative in ("tool/package_macos.py", "tool/macos/installer/postinstall",
                         "macos/NetworkService/.build/debug/main.swift",
                         "macos/NetworkService/Sources/__pycache__/irrelevant.pyc"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("unrelated")
        self.assertEqual(ci.fingerprint("helper", "arm64", self.root), self.value)

    def test_input_source_symlink_cannot_reach_outside_checkout(self):
        outside = self.base / "outside"
        outside.write_text("not a pinned input")
        (self.root / "macos/NetworkService/Sources/link").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            ci.fingerprint("helper", "arm64", self.root)

    def test_core_uses_builders_exact_component_inputs(self):
        fake = mock.Mock()
        fake.core_inputs.return_value = {"source": "pinned", "patch": "only this core"}
        with mock.patch.dict(sys.modules, build_cores=fake):
            result = ci.fingerprint("mihomo", "arm64", self.root)
        fake.core_inputs.assert_called_once_with("mihomo", "arm64")
        self.assertRegex(result, r"^[a-f0-9]{64}$")

    def test_app_inputs_cover_native_client_and_locks_but_exclude_installer_and_daemon(self):
        for relative in (
            "pubspec.yaml", "pubspec.lock", "lib/main.dart", "packages/local/lib.dart",
            "third_party/tray_manager/lib.dart", "macos/Runner/AppDelegate.swift",
            "macos/Runner.xcodeproj/project.pbxproj", "macos/Runner.xcworkspace/contents.xcworkspacedata",
            "macos/Flutter/Flutter-Debug.xcconfig", "macos/Flutter/Flutter-Release.xcconfig",
            "macos/Podfile", "macos/Podfile.lock", "macos/DesktopSupport/Package.swift",
            "macos/NetworkService/Sources/CNetworkXPC/bridge.m",
            "macos/NetworkService/Sources/KEQNetworkClient/client.swift",
            "tool/macos/build_app.sh", "tool/macos/check_flutter_framework.py",
            "assets/icon.png", "assets/bin/windows/geosite.dat",
        ):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        value = ci.fingerprint("app", "arm64", self.root)
        for relative in ("pubspec.lock", "macos/Podfile.lock", "lib/main.dart",
                         "macos/NetworkService/Sources/CNetworkXPC/bridge.m",
                         "macos/NetworkService/Sources/KEQNetworkClient/client.swift",
                         "assets/bin/windows/geosite.dat", "tool/macos/build_app.sh"):
            path = self.root / relative
            original = path.read_text()
            path.write_text(original + "changed")
            with self.subTest(relative=relative):
                self.assertNotEqual(ci.fingerprint("app", "arm64", self.root), value)
            path.write_text(original)
        for relative in ("tool/package_macos.py", "tool/macos/installer/postinstall",
                         "macos/NetworkService/Sources/NetworkServiceDaemon/main.swift",
                         "assets/bin/windows/mihomo.exe", "macos/DesktopSupport/.build/generated.swift"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("unrelated")
        self.assertEqual(ci.fingerprint("app", "arm64", self.root), value)


class ArchiveTests(Fixture):
    def test_executable_modes_framework_symlinks_and_sha_sidecar_round_trip(self):
        framework = self.source / "KEQDIS.app/Contents/Frameworks/FlutterMacOS.framework"
        version = framework / "Versions/A"
        version.mkdir(parents=True)
        (version / "FlutterMacOS").write_bytes(b"signed framework")
        (version / "FlutterMacOS").chmod(0o755)
        (framework / "Versions/Current").symlink_to("A")
        (framework / "FlutterMacOS").symlink_to("Versions/Current/FlutterMacOS")
        (self.source / "private").mkdir(mode=0o700)
        (self.source / "private/config").write_text("private fixture")
        (self.source / "private/config").chmod(0o600)
        result = self.pack()
        self.assertEqual(result["archive-sha256"], hashlib.sha256(self.archive.read_bytes()).hexdigest())
        self.assertTrue(self.archive.with_suffix(".tar.sha256").read_text().startswith(result["archive-sha256"]))
        self.restore()
        self.assertEqual(ci.source_entries(self.source), ci.source_entries(self.destination))
        restored = self.destination / framework.relative_to(self.source)
        self.assertEqual((restored / "FlutterMacOS").read_bytes(), b"signed framework")

    def test_corrupt_file_hash_rejected_without_replacing_existing_destination(self):
        self.pack()
        self.destination.mkdir()
        (self.destination / "old-working-component").write_text("preserve")

        def corrupt(member, data):
            if member.name == "payload/keqdis-network-service":
                data = bytes([data[0] ^ 1]) + data[1:]
            return member, data

        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.restore(self.rewrite(mutate_member=corrupt))
        self.assertEqual((self.destination / "old-working-component").read_text(), "preserve")
        self.assertFalse(any(self.base.glob(".restored.restore-*")))

    def test_stale_input_different_architecture_and_wrong_component_rejected(self):
        self.pack()
        for component, arch in (("helper", "x64"), ("app", "arm64")):
            with self.assertRaisesRegex(ValueError, "component or architecture mismatch"):
                ci.validate_archive(self.archive, component, arch, self.value)
        (self.root / "tool/macos/build_helper.sh").write_text("new recipe")
        with self.assertRaisesRegex(ValueError, "fingerprint mismatch"):
            self.restore()

    def test_permission_tampering_rejected(self):
        self.pack()

        def change_mode(member, data):
            if member.name == "payload/keqdis-network-service":
                member.mode = 0o644
            return member, data

        with self.assertRaisesRegex(ValueError, "permission"):
            self.restore(self.rewrite(mutate_member=change_mode))

    def test_symlink_tampering_rejected(self):
        (self.source / "current").symlink_to("keqdis-network-service")
        self.pack()

        def change_link(member, data):
            if member.name == "payload/current":
                member.linkname = "/etc/passwd"
            return member, data

        with self.assertRaisesRegex(ValueError, "symlink mismatch"):
            self.restore(self.rewrite(mutate_member=change_link))

    def test_tar_traversal_hardlink_and_duplicate_member_rejected(self):
        self.pack()
        for name, kind in (("payload/../escaped", tarfile.REGTYPE),
                           ("payload/extra", tarfile.LNKTYPE),
                           ("payload/keqdis-network-service", tarfile.REGTYPE)):
            member = tarfile.TarInfo(name)
            member.type, member.linkname = kind, "keqdis-network-service"
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.restore(self.rewrite(extra=(member, b"" if kind == tarfile.REGTYPE else None)))
        self.assertFalse((self.base / "escaped").exists())

    def test_unlisted_missing_and_special_payloads_rejected(self):
        self.pack()

        def missing(member, data):
            return (None, None) if member.name == "payload/keqdis-network-service" else (member, data)

        with self.assertRaisesRegex(ValueError, "missing"):
            self.restore(self.rewrite(mutate_member=missing))
        with self.assertRaisesRegex(ValueError, "permissions"):
            self.restore(self.rewrite(mutate_manifest=lambda value: value["entries"]["keqdis-network-service"].update(mode=0o4755)))

    def test_escaping_or_cyclic_symlink_and_descendant_of_link_rejected(self):
        for target in ("../outside", "/etc/passwd", "link"):
            link = self.source / "link"
            link.symlink_to(target)
            with self.subTest(target=target), self.assertRaises(ValueError):
                self.pack()
            link.unlink()
        entries = {"link": {"type": "symlink", "target": "folder"},
                   "link/child": {"type": "file"}}
        with self.assertRaisesRegex(ValueError, "parent is not a directory"):
            ci.validate_links(entries)

    def test_symlink_chain_cannot_hide_escape_behind_lexical_normalization(self):
        (self.source / "inside").mkdir()
        (self.source / "inside/back").symlink_to("..")
        (self.source / "link").symlink_to("inside/back/../outside")
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.pack()

    def test_valid_restore_replaces_old_directory_after_validation(self):
        self.pack()
        self.destination.mkdir()
        (self.destination / "old").write_text("old")
        self.restore()
        self.assertFalse((self.destination / "old").exists())
        self.assertTrue((self.destination / "keqdis-network-service").is_file())

    def test_failed_rename_restores_previous_destination(self):
        self.pack()
        self.destination.mkdir()
        (self.destination / "old").write_text("old")
        replace = Path.replace

        def fail_install(path, target):
            if ".restore-" in path.name:
                raise OSError("simulated rename failure")
            return replace(path, target)

        with mock.patch.object(Path, "replace", fail_install), self.assertRaises(OSError):
            self.restore()
        self.assertEqual((self.destination / "old").read_text(), "old")

    def test_destination_symlink_is_rejected(self):
        self.pack()
        self.destination.symlink_to(self.source)
        with self.assertRaisesRegex(ValueError, "destination.*symlink"):
            self.restore()

    def test_truncated_tar_and_archive_inside_source_rejected(self):
        self.archive.write_bytes(b"not a tar")
        with self.assertRaisesRegex(ValueError, "Invalid or truncated"):
            self.restore()
        with self.assertRaisesRegex(ValueError, "outside its source"):
            ci.pack("helper", "arm64", self.source, self.source / "self.tar", self.root, self.commit)


class FakeAPI:
    def __init__(self, runs, artifacts, archive):
        self.runs, self.artifacts, self.archive = runs, artifacts, archive
        self.downloaded = []

    def pages(self, path, key):
        if key == "workflow_runs":
            return iter(self.runs)
        run_id = int(path.split("/")[-2])
        return iter(self.artifacts.get(run_id, []))

    def download(self, artifact, destination):
        self.downloaded.append(artifact["id"])
        with zipfile.ZipFile(destination, "w") as archive:
            archive.write(self.archive, "helper-arm64.tar")


class FetchTests(Fixture):
    def run_fixture(self, run_id=1, **changes):
        result = {"id": run_id, "event": "push", "head_branch": "dev", "path": ci.WORKFLOW,
                  "head_sha": "c" * 40, "repository": {"full_name": "caocaocc/keqdroid"},
                  "head_repository": {"full_name": "caocaocc/keqdroid"}, "conclusion": "failure"}
        result.update(changes)
        return result

    def artifact_fixture(self, artifact_id=101, **changes):
        result = {"id": artifact_id, "name": ci.artifact_prefix("helper", "arm64", self.value) + "-attempt1", "expired": False}
        result.update(changes)
        return result

    def fetch(self, client):
        return ci.fetch("helper", "arm64", self.destination, "caocaocc/keqdroid", root=self.root, client=client)

    def test_successful_component_from_failed_run_reused_across_commits(self):
        self.pack()
        client = FakeAPI([self.run_fixture()], {1: [self.artifact_fixture()]}, self.archive)
        result = self.fetch(client)
        self.assertEqual(result["hit"], "true")
        self.assertEqual(result["source-run-id"], "1")
        self.assertEqual(result["source-commit"], self.commit)
        self.assertTrue((self.destination / "keqdis-network-service").exists())

    def test_republished_archive_keeps_original_bytes_and_actual_build_commit(self):
        self.pack()
        retained = self.base / "republished/helper-arm64.tar"
        client = FakeAPI([self.run_fixture()], {1: [self.artifact_fixture()]}, self.archive)
        result = ci.fetch("helper", "arm64", self.destination, "caocaocc/keqdroid",
                          root=self.root, client=client, archive_output=retained)
        self.assertEqual(result["hit"], "true")
        self.assertEqual(retained.read_bytes(), self.archive.read_bytes())
        manifest = ci.validate_archive(retained, "helper", "arm64", self.value)
        self.assertEqual(manifest["sourceCommit"], self.commit)
        self.assertNotEqual(manifest["sourceCommit"], client.runs[0]["head_sha"])
        self.assertEqual(result["archive-sha256"], ci.sha256_file(retained))
        self.assertTrue(retained.with_suffix(".tar.sha256").is_file())

    def test_forks_pull_requests_other_branch_other_workflow_are_not_trusted(self):
        self.pack()
        runs = [self.run_fixture(index, **changes) for index, changes in enumerate([
            {"event": "pull_request"}, {"head_branch": "master"}, {"path": ".github/workflows/other.yml"},
            {"head_repository": {"full_name": "attacker/keqdroid"}},
            {"repository": {"full_name": "attacker/keqdroid"}},
            {"head_repository": None},
        ], 1)]
        client = FakeAPI(runs, {index: [self.artifact_fixture()] for index in range(1, 7)}, self.archive)
        self.assertEqual(self.fetch(client)["hit"], "false")
        self.assertEqual(client.downloaded, [])

    def test_expired_wrong_fingerprint_and_wrong_architecture_are_skipped(self):
        self.pack()
        artifacts = [self.artifact_fixture(expired=True),
                     self.artifact_fixture(name="component-helper-arm64-" + "0" * 64 + "-attempt1"),
                     self.artifact_fixture(name="component-helper-x64-" + self.value + "-attempt1")]
        client = FakeAPI([self.run_fixture()], {1: artifacts}, self.archive)
        self.assertEqual(self.fetch(client)["hit"], "false")
        self.assertEqual(client.downloaded, [])

    def test_only_corrupt_historical_archives_are_reported_and_treated_as_a_miss(self):
        self.pack()
        changed = self.rewrite(mutate_manifest=lambda value: value["entries"]["keqdis-network-service"].update(sha256="0" * 64))
        client = FakeAPI([self.run_fixture()], {1: [self.artifact_fixture()]}, changed)
        with mock.patch.object(sys, "stderr", new_callable=io.StringIO) as warnings:
            result = self.fetch(client)
        self.assertEqual(result["hit"], "false")
        self.assertEqual(result["rejected-artifacts"], "1")
        self.assertIn("Rejected checkpoint artifact 101", warnings.getvalue())
        self.assertIn("SHA-256 mismatch", warnings.getvalue())
        self.assertFalse(self.destination.exists())

    def test_corrupt_latest_candidate_falls_back_to_valid_older_checkpoint(self):
        self.pack()
        changed = self.rewrite(mutate_manifest=lambda value: value["entries"]["keqdis-network-service"].update(sha256="0" * 64))
        artifacts = [self.artifact_fixture(101), self.artifact_fixture(102)]
        client = FakeAPI([self.run_fixture()], {1: artifacts}, self.archive)

        def download(artifact, destination):
            client.downloaded.append(artifact["id"])
            with zipfile.ZipFile(destination, "w") as archive:
                archive.write(changed if artifact["id"] == 102 else self.archive, "helper-arm64.tar")

        client.download = download
        with mock.patch.object(sys, "stderr", new_callable=io.StringIO) as warnings:
            result = self.fetch(client)
        self.assertEqual(result["hit"], "true")
        self.assertEqual(result["rejected-artifacts"], "1")
        self.assertEqual(client.downloaded, [102, 101])
        self.assertIn("Rejected checkpoint artifact 102", warnings.getvalue())
        self.assertEqual((self.destination / "keqdis-network-service").read_bytes(),
                         (self.source / "keqdis-network-service").read_bytes())

    def test_latest_attempt_is_selected(self):
        self.pack()
        artifacts = [self.artifact_fixture(101), self.artifact_fixture(102, name=ci.artifact_prefix("helper", "arm64", self.value) + "-attempt2")]
        client = FakeAPI([self.run_fixture()], {1: artifacts}, self.archive)
        self.assertEqual(self.fetch(client)["hit"], "true")
        self.assertEqual(client.downloaded, [102])

    def test_expired_between_listing_and_download_is_a_miss(self):
        self.pack()
        client = FakeAPI([self.run_fixture()], {1: [self.artifact_fixture()]}, self.archive)
        client.download = mock.Mock(side_effect=urllib.error.HTTPError("https://api.github.com", 410, "Gone", {}, None))
        self.assertEqual(self.fetch(client)["hit"], "false")


class TransportTests(unittest.TestCase):
    def test_pagination_reads_more_than_one_page(self):
        client = ci.GitHubAPI("caocaocc/keqdroid")
        client.json = mock.Mock(side_effect=[{"artifacts": [{"id": number} for number in range(100)]}, {"artifacts": [{"id": 100}]}])
        result = list(client.pages("/repos/caocaocc/keqdroid/actions/artifacts", "artifacts"))
        self.assertEqual(len(result), 101)
        self.assertTrue(client.json.call_args_list[1].args[0].endswith("page=2"))

    def test_redirect_does_not_forward_github_token_to_object_storage(self):
        client = ci.GitHubAPI("caocaocc/keqdroid", token="test-token-do-not-send")
        client.request = mock.Mock(side_effect=urllib.error.HTTPError(
            "https://api.github.com/download", 302, "Found", {"Location": "https://objects.example.invalid/file?signed=fixture"}, None))
        payload = b"zip transport fixture"
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(ci.urllib.request, "urlopen", return_value=io.BytesIO(payload)) as open_url:
            client.download({"id": 1, "digest": "sha256:" + hashlib.sha256(payload).hexdigest()}, Path(temporary) / "artifact.zip")
            request = open_url.call_args.args[0]
            self.assertIsNone(request.get_header("Authorization"))
            self.assertEqual(request.host, "objects.example.invalid")

    def test_unsafe_download_redirect_and_wrong_zip_digest_rejected(self):
        client = ci.GitHubAPI("caocaocc/keqdroid", token="fixture")
        client.request = mock.Mock(side_effect=urllib.error.HTTPError(
            "https://api.github.com/download", 302, "Found", {"Location": "http://objects.invalid/file"}, None))
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                client.download({"id": 1}, Path(temporary) / "artifact.zip")
            client.request = mock.Mock(return_value=io.BytesIO(b"corrupt"))
            with self.assertRaisesRegex(ValueError, "ZIP digest mismatch"):
                client.download({"id": 1, "digest": "sha256:" + "0" * 64}, Path(temporary) / "artifact.zip")

    def test_zip_traversal_symlinks_duplicate_tars_and_extra_files_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "artifact.zip"
            for names in (["../component.tar"], ["nested/component.tar"], ["a.tar", "b.tar"], ["a.tar", "arbitrary.py"]):
                with zipfile.ZipFile(path, "w") as archive:
                    for name in names:
                        archive.writestr(name, b"payload")
                with self.subTest(names=names), self.assertRaises(ValueError):
                    ci.artifact_tar(path, Path(temporary) / "out.tar")
            with zipfile.ZipFile(path, "w") as archive:
                entry = zipfile.ZipInfo("component.tar")
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, "/etc/passwd")
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                ci.artifact_tar(path, Path(temporary) / "out.tar")

    def test_outputs_cannot_inject_github_workflow_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "output"
            ci.write_outputs({"hit": "true", "fingerprint": "a" * 64}, path)
            self.assertIn("hit=true\n", path.read_text())
            with self.assertRaisesRegex(ValueError, "output value"):
                ci.write_outputs({"hit": "true\ninjected=value"}, path)


if __name__ == "__main__":
    unittest.main()
