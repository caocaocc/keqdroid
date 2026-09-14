"""Release/checkpoint regression tests without network, signing keys or compilers."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool" / "ci"))
import checkpoint
import publish_release
import build_platform
import package_platform

COMMIT = "a" * 40
OTHER = "b" * 40
FINGERPRINT = hashlib.sha256(COMMIT.encode()).hexdigest()


class CheckpointTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.binary = self.source / "core"
        self.binary.write_bytes(b"executable payload")
        self.binary.chmod(0o755)
        self.archive = self.root / "component.tar"

    def pack(self):
        return checkpoint.pack(self.source, self.archive, "app", "linux-x64", FINGERPRINT, COMMIT)

    def test_archive_retains_executable_mode_and_relative_link(self):
        if os.name != "nt":
            (self.source / "current").symlink_to("core")
        self.pack()
        output = self.root / "restored"
        result = checkpoint.restore(self.archive, output, "app", "linux-x64", FINGERPRINT)
        self.assertEqual(result["sourceCommit"], COMMIT)
        self.assertEqual((output / "core").read_bytes(), b"executable payload")
        if os.name != "nt":
            self.assertEqual((output / "core").stat().st_mode & 0o777, 0o755)
            self.assertTrue((output / "current").is_symlink())

    def test_wrong_hash_is_rejected_before_restore(self):
        self.pack()
        self.archive.with_name("component.tar.sha256").write_text("0" * 64 + "  component.tar\n")
        with self.assertRaisesRegex(ValueError, "checksum"):
            checkpoint.restore(self.archive, self.root / "output", "app", "linux-x64", FINGERPRINT)
        self.assertFalse((self.root / "output").exists())

    def test_rehashed_modified_payload_still_fails_manifest_validation(self):
        self.pack()
        raw = self.archive.read_bytes().replace(b"executable payload", b"corrupted! payload", 1)
        self.archive.write_bytes(raw)
        digest = hashlib.sha256(raw).hexdigest()
        self.archive.with_name("component.tar.sha256").write_text(f"{digest}  component.tar\n")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            checkpoint.restore(self.archive, self.root / "output", "app", "linux-x64", FINGERPRINT)

    def test_release_commit_and_platform_must_match(self):
        self.pack()
        with self.assertRaisesRegex(ValueError, "source commit"):
            checkpoint.restore(self.archive, self.root / "output", "app", "linux-x64", FINGERPRINT, OTHER)
        with self.assertRaisesRegex(ValueError, "architecture"):
            checkpoint.restore(self.archive, self.root / "output", "app", "windows-x64", FINGERPRINT)

    def test_missing_transport_sidecar_and_path_escape_rejected(self):
        transport = self.root / "download.zip"
        with zipfile.ZipFile(transport, "w") as archive:
            archive.writestr("component.tar", b"bad")
        with self.assertRaises(ValueError):
            checkpoint.unzip_checkpoint(transport, self.root / "out")
        with zipfile.ZipFile(transport, "w") as archive:
            archive.writestr("../component.tar", b"bad")
            archive.writestr("../component.tar.sha256", b"bad")
        with self.assertRaises(ValueError):
            checkpoint.unzip_checkpoint(transport, self.root / "out")

    def test_symbolic_payload_escape_rejected(self):
        if os.name == "nt":
            self.skipTest("Windows job may lack symbolic link privileges")
        (self.source / "escape").symlink_to("../../outside")
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.pack()

    def test_packaging_only_change_and_commit_rewrite_reuse_app(self):
        repo = self.root / "repo"
        (repo / "lib").mkdir(parents=True)
        (repo / "tool/ci").mkdir(parents=True)
        (repo / "pubspec.yaml").write_text("version: 0.20.0+48\n")
        (repo / "pubspec.lock").write_text("locked\n")
        (repo / "lib/main.dart").write_text("void main() {}\n")
        (repo / "tool/ci/package_platform.py").write_text("package 1\n")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        first = checkpoint.fingerprint("linux-x64", repo)
        (repo / "tool/ci/package_platform.py").write_text("package 2\n")
        self.assertEqual(checkpoint.fingerprint("linux-x64", repo), first)
        subprocess.run(["git", "-c", "user.email=ci@example.invalid", "-c", "user.name=CI", "commit", "-qm", "one"], cwd=repo, check=True)
        self.assertEqual(checkpoint.fingerprint("linux-x64", repo), first)
        (repo / "lib/main.dart").write_text("void main() { print('change'); }\n")
        self.assertNotEqual(checkpoint.fingerprint("linux-x64", repo), first)
        android_first = checkpoint.fingerprint("android-arm64", repo, "c" * 64)
        self.assertNotEqual(android_first, checkpoint.fingerprint("android-arm64", repo, "d" * 64))


    def test_generated_plugin_line_endings_do_not_change_input_fingerprint(self):
        repo = self.root / "repo"
        (repo / "windows/flutter").mkdir(parents=True)
        (repo / "pubspec.yaml").write_text("version: 0.20.0+48\n")
        (repo / "pubspec.lock").write_text("locked plugins\n")
        generated = repo / "windows/flutter/generated_plugins.cmake"
        generated.write_bytes(b"generated from locked plugins\r\n")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        first = checkpoint.fingerprint("windows-x64", repo)
        generated.write_bytes(b"generated from locked plugins\n")
        self.assertEqual(checkpoint.fingerprint("windows-x64", repo), first)
        (repo / "pubspec.lock").write_text("changed plugins\n")
        self.assertNotEqual(checkpoint.fingerprint("windows-x64", repo), first)

    def test_native_asset_repair_and_shared_workflow_remain_real_inputs(self):
        repo = self.root / "repo"
        (repo / "tool/ci").mkdir(parents=True)
        (repo / ".github/workflows").mkdir(parents=True)
        (repo / "pubspec.yaml").write_text("version: 0.20.1+49\n")
        (repo / "pubspec.lock").write_text("locked\n")
        repair = repo / "tool/ci/native_assets_cache.py"
        workflow = repo / ".github/workflows/platform-component.yml"
        repair.write_text("repair version 1\n")
        workflow.write_text("shared workflow version 1\n")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "add", "."], cwd=repo, check=True)

        def fingerprints():
            return {platform: checkpoint.fingerprint(platform, repo, "c" * 64)
                    for platform in checkpoint.PLATFORMS}

        before = fingerprints()
        repair.write_text("repair version 2\n")
        after = fingerprints()
        self.assertEqual({platform for platform in before if before[platform] != after[platform]},
                         {"linux-x64", "windows-x64"})
        workflow.write_text("shared workflow version 2\n")
        final = fingerprints()
        self.assertTrue(all(after[platform] != final[platform] for platform in after))

    def test_small_valid_linux_runner_is_accepted_and_wrong_arch_is_rejected(self):
        binary = self.root / "keqdroid"
        header = bytearray(64)
        header[:6] = b"\x7fELF\x02\x01"
        header[18:20] = (62).to_bytes(2, "little")
        binary.write_bytes(header + b"small dynamically linked runner")
        build_platform.verify_binary(binary, "linux")
        header[18:20] = (183).to_bytes(2, "little")
        binary.write_bytes(header)
        with self.assertRaisesRegex(ValueError, "x86_64"):
            build_platform.verify_binary(binary, "linux")

    def test_failed_run_component_is_reused_and_corrupt_newer_candidate_skipped(self):
        self.pack()
        transport = self.root / "valid.zip"
        with zipfile.ZipFile(transport, "w") as archive:
            archive.write(self.archive, "component.tar")
            archive.write(self.archive.with_name("component.tar.sha256"), "component.tar.sha256")
        run = {"event": "push", "head_branch": "dev", "path": checkpoint.WORKFLOW,
               "repository": {"full_name": checkpoint.REPOSITORY}, "head_repository": {"full_name": checkpoint.REPOSITORY},
               "head_sha": OTHER, "status": "completed", "conclusion": "failure", "id": 8}
        name = f"platform-app-linux-x64-{FINGERPRINT}-attempt1"
        class Client:
            def pages(self, path, _):
                if "workflows/" in path:
                    return iter([run])
                return iter([{"id": 2, "name": name, "expired": False}, {"id": 1, "name": name, "expired": False}])
            def download(self, artifact, target):
                if artifact["id"] == 2:
                    Path(target).write_bytes(b"corrupted ZIP")
                else:
                    shutil.copyfile(transport, target)
        with patch.object(checkpoint, "fingerprint", return_value=FINGERPRINT):
            result = checkpoint.fetch("linux-x64", self.root / "retained.tar", self.root / "restored", Client())
        self.assertEqual(result["hit"], "true")
        self.assertEqual(result["source-commit"], COMMIT)
        self.assertEqual(result["source-run-id"], 8)
        self.assertEqual((self.root / "restored/core").read_bytes(), b"executable payload")


class WindowsPackagingEncodingTests(unittest.TestCase):
    def test_utf8_release_metadata_with_a_windows_legacy_default_encoding(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "pubspec.yaml").write_text("\ufeff# Русские 注释\nversion: 0.20.0+48\n", encoding="utf-8")
            source = root / "app"
            source.mkdir()
            (source / "keqdroid.exe").write_bytes(b"already verified component")
            (source / "component-build.json").write_text(
                json.dumps({"platform": "windows-x64", "note": "中文"}, ensure_ascii=False), encoding="utf-8")
            original_open = Path.open
            def windows_open(path, mode="r", buffering=-1, encoding=None, errors=None, newline=None):
                if "b" not in mode and encoding is None:
                    encoding = "cp1252"
                return original_open(path, mode, buffering, encoding, errors, newline)
            destination = root / "output"
            with patch.object(package_platform, "ROOT", root), patch.object(Path, "open", windows_open), \
                    patch.object(checkpoint.archive_tools, "source_commit", return_value=COMMIT):
                package_platform.package("windows-x64", source, destination)
            with zipfile.ZipFile(destination / "keqdroid-windows-x64-0.20.0.zip") as archive:
                self.assertEqual(archive.namelist(), ["keqdroid.exe"])
            report = json.loads((destination / "keqdroid-0.20.0-windows-x64-build.json").read_text(encoding="utf-8"))
            self.assertEqual(report["component"]["note"], "中文")


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def payload(self, platform):
        folder = self.root / platform
        folder.mkdir()
        for name in publish_release.required_files("0.20.0", platform):
            (folder / name).write_bytes(b"test payload")
        suffix = "verification" if platform.startswith("macos-") else "build"
        report = {"version": "0.20.0", "sourceCommit": COMMIT, "platform": platform,
                  "architecture": platform.removeprefix("macos-"), "signature": "ad-hoc",
                  "installerSignature": "unsigned", "notarized": False}
        (folder / f"keqdroid-0.20.0-{platform}-{suffix}.json").write_text(json.dumps(report))
        self.sums(folder)
        return folder

    def sums(self, folder):
        (folder / "SHA256SUMS").write_text("".join(
            f"{checkpoint.archive_tools.sha256_file(p)}  {p.name}\n"
            for p in sorted(folder.iterdir()) if p.name != "SHA256SUMS"))

    def test_all_platform_release_file_contracts(self):
        for platform in publish_release.PLATFORMS:
            with self.subTest(platform=platform):
                folder = self.payload(platform)
                result = publish_release.verify_payload(folder, "0.20.0", platform, COMMIT)
                self.assertEqual(set(result), publish_release.required_files("0.20.0", platform))

    def test_wrong_hash_missing_file_and_duplicate_manifest_refused(self):
        folder = self.payload("macos-arm64")
        target = folder / "keqdroid-0.20.0-macos-arm64.pkg"
        target.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            publish_release.verify_payload(folder, "0.20.0", "macos-arm64", COMMIT)
        self.sums(folder)
        sums = folder / "SHA256SUMS"
        sums.write_text(sums.read_text() + sums.read_text().splitlines()[0] + "\n")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            publish_release.verify_payload(folder, "0.20.0", "macos-arm64", COMMIT)
        self.sums(folder)
        target.unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            publish_release.verify_payload(folder, "0.20.0", "macos-arm64", COMMIT)

    def test_other_commit_and_dmg_rejected(self):
        folder = self.payload("macos-x64")
        with self.assertRaisesRegex(ValueError, "commit"):
            publish_release.verify_payload(folder, "0.20.0", "macos-x64", OTHER)
        (folder / "legacy.dmg").write_bytes(b"legacy")
        with self.assertRaisesRegex(ValueError, "Unexpected"):
            publish_release.verify_payload(folder, "0.20.0", "macos-x64", COMMIT)

    def test_only_successful_same_repo_dev_exact_commit_run(self):
        good = {"event": "push", "head_branch": "dev", "path": checkpoint.WORKFLOW,
                "repository": {"full_name": checkpoint.REPOSITORY}, "head_repository": {"full_name": checkpoint.REPOSITORY},
                "head_sha": COMMIT, "status": "completed", "conclusion": "success", "id": 8}
        bad = [dict(good, event="pull_request"), dict(good, head_branch="master"),
               dict(good, head_sha=OTHER), dict(good, conclusion="failure"),
               dict(good, head_repository={"full_name": "attacker/repo"})]
        class Client:
            def pages(self, *_):
                return iter(bad)
        with self.assertRaisesRegex(ValueError, "No successful"):
            publish_release.select_run(Client(), COMMIT)
        bad.append(good)
        self.assertEqual(publish_release.select_run(Client(), COMMIT)["id"], 8)

    def test_public_release_retry_requires_identical_files_and_hashes(self):
        folder = self.root / "release"
        folder.mkdir()
        (folder / "app.pkg").write_bytes(b"version one")
        digest = checkpoint.archive_tools.sha256_file(folder / "app.pkg")
        release = {"assets": [{"name": "app.pkg", "digest": "sha256:" + digest}]}
        publish_release.verify_existing_assets("v0.20.0", release, folder)
        release["assets"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "hash differs"):
            publish_release.verify_existing_assets("v0.20.0", release, folder)
        release["assets"].append({"name": "unexpected.apk"})
        with self.assertRaisesRegex(ValueError, "different asset set"):
            publish_release.verify_existing_assets("v0.20.0", release, folder)


    def test_collect_all_platforms_and_hash_every_published_asset(self):
        artifacts = []
        transports = {}
        for index, platform in enumerate(publish_release.PLATFORMS, start=1):
            source = self.payload(platform)
            archive = self.root / f"{platform}.tar"
            checkpoint.pack(source, archive, "release", platform, FINGERPRINT, COMMIT)
            transport = self.root / f"{platform}.zip"
            with zipfile.ZipFile(transport, "w") as zipped:
                zipped.write(archive, archive.name)
                sidecar = archive.with_name(archive.name + ".sha256")
                zipped.write(sidecar, sidecar.name)
            transports[index] = transport
            artifacts.append({"id": index, "name": f"release-{platform}-{COMMIT}-attempt1", "expired": False})
        run = {"event": "push", "head_branch": "dev", "path": checkpoint.WORKFLOW,
               "repository": {"full_name": checkpoint.REPOSITORY}, "head_repository": {"full_name": checkpoint.REPOSITORY},
               "head_sha": COMMIT, "status": "completed", "conclusion": "success", "id": 42}
        class Client:
            def pages(self, path, _):
                return iter([run] if "workflows/" in path else artifacts)
            def download(self, artifact, target):
                shutil.copyfile(transports[artifact["id"]], target)
        repo = self.root / "repo"
        geo = repo / "assets/bin/windows/geoip.dat"
        geo.parent.mkdir(parents=True)
        geo.write_bytes(b"0" * 1_000_001)
        destination = self.root / "assembled"
        with patch.object(publish_release, "ROOT", repo):
            result = publish_release.collect(COMMIT, "0.20.0", destination, Client())
        self.assertEqual(set(result["platforms"]), set(publish_release.PLATFORMS))
        sums = dict(line.split("  ", 1)[::-1] for line in (destination / "SHA256SUMS").read_text().splitlines())
        self.assertEqual(set(sums), {p.name for p in destination.iterdir()} - {"SHA256SUMS"})
        self.assertIn("geoip.dat.sha256", sums)
        for name, digest in sums.items():
            self.assertEqual(checkpoint.archive_tools.sha256_file(destination / name), digest)
        artifacts.pop()
        with patch.object(publish_release, "ROOT", repo), self.assertRaisesRegex(ValueError, "Missing verified"):
            publish_release.collect(COMMIT, "0.20.0", self.root / "incomplete", Client())

    def test_interrupted_draft_upload_resumes_without_rebuilding(self):
        folder = self.root / "publish"
        folder.mkdir()
        (folder / "a.pkg").write_bytes(b"first")
        (folder / "b.pkg").write_bytes(b"second")
        state = {"release": None, "failed": False, "commands": []}
        class Client:
            def json(self, path):
                if state["release"] is None:
                    raise urllib.error.HTTPError(path, 404, "missing", {}, None)
                return state["release"]
        def gh(*args, **_):
            state["commands"].append(args)
            if args[:2] == ("release", "create"):
                state["release"] = {"draft": True, "prerelease": False, "tag_name": "v0.20.0", "assets": []}
            if args[:2] == ("release", "upload"):
                path = Path(args[3])
                if path.name == "b.pkg" and not state["failed"]:
                    state["failed"] = True
                    raise subprocess.CalledProcessError(1, args)
                assets = state["release"]["assets"]
                assets[:] = [a for a in assets if a["name"] != path.name]
                assets.append({"name": path.name, "digest": "sha256:" + checkpoint.archive_tools.sha256_file(path)})
            if "--draft=false" in args:
                state["release"]["draft"] = False
        with patch.object(publish_release.subprocess, "check_output", return_value=COMMIT), \
                patch.object(checkpoint.archive_tools, "GitHubAPI", return_value=Client()), \
                patch.object(publish_release, "gh", side_effect=gh):
            with self.assertRaises(subprocess.CalledProcessError):
                publish_release.publish("v0.20.0", COMMIT, folder, self.root / "notes.md")
            self.assertTrue(state["release"]["draft"])
            publish_release.publish("v0.20.0", COMMIT, folder, self.root / "notes.md")
            self.assertFalse(state["release"]["draft"])
            before = len(state["commands"])
            publish_release.publish("v0.20.0", COMMIT, folder, self.root / "notes.md")
            self.assertEqual(len(state["commands"]), before)
        self.assertEqual(sum(command[:2] == ("release", "create") for command in state["commands"]), 1)
        self.assertTrue(all("build" not in command for command in state["commands"]))

    def test_workflows_keep_architectures_independent_and_releases_separate(self):
        development = (ROOT / ".github/workflows/macos.yml").read_text()
        self.assertNotIn("cancel-in-progress: true", development)
        for architecture in ("arm64", "x64"):
            package = development.split(f"  package-{architecture}:", 1)[1].split("    uses:", 1)[0]
            other = "x64" if architecture == "arm64" else "arm64"
            self.assertNotIn(f"app-{other}", package)
        publisher = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("tags: ['v*']", publisher)
        self.assertNotIn("flutter build", publisher)
        self.assertIn("contents: write", publisher)
        for name in ("macos.yml", "macos-component.yml", "macos-package.yml", "platform-component.yml", "platform-package.yml"):
            self.assertNotIn("contents: write", (ROOT / ".github/workflows" / name).read_text())


if __name__ == "__main__":
    unittest.main()
