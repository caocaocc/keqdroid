#!/usr/bin/env python3
"""Verified checkpoints for non-macOS app builds and final release payloads.

The original macOS implementation stays byte-for-byte unchanged so existing
core and helper checkpoints retain their input fingerprints. Its bounded tar
reader is also used here; release publishing never uses extractall().
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool" / "macos"))
import ci_artifacts as archive_tools

PLATFORMS = ("android-arm64", "windows-x64", "linux-x64")
RELEASE_PLATFORMS = (*PLATFORMS, "macos-arm64", "macos-x64")
WORKFLOW = ".github/workflows/macos.yml"
REPOSITORY = "caocaocc/keqdroid"
TOOLCHAIN = {"flutter": "3.44.4", "java": "17", "androidCMake": "3.22.1"}


def fingerprint(platform, root=ROOT, certificate=None):
    if platform not in PLATFORMS:
        raise ValueError("Unsupported app platform")
    root = Path(root)
    family = platform.split("-")[0]
    files = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    prefixes = ("lib/", "packages/", "third_party/", family + "/")
    generated = {
        "linux/flutter/generated_plugin_registrant.cc", "linux/flutter/generated_plugin_registrant.h",
        "linux/flutter/generated_plugins.cmake", "windows/flutter/generated_plugin_registrant.cc",
        "windows/flutter/generated_plugin_registrant.h", "windows/flutter/generated_plugins.cmake",
        "windows/flutter/app_plugins.cmake", "windows/flutter/app_plugin_registrant.cc",
    }
    names = {"pubspec.yaml", "pubspec.lock", "l10n.yaml", "tool/ci/checkpoint.py",
             "tool/ci/build_platform.py", "tool/macos/ci_artifacts.py", ".github/workflows/platform-component.yml"}
    if family == "android":
        names.add("tool/ci/verify_android.py")
    if family == "windows":
        names.add("tool/sync_windows_plugins.ps1")
    inputs = {}
    for name in sorted(set(files)):
        if not name or name in generated or re.fullmatch(r"lib/l10n/app_localizations(?:_[a-z]+)?\.dart", name):
            # Flutter regenerates these from the locked plugins/ARB inputs. In
            # particular Windows checkout CRLF must not invalidate a checkpoint
            # after Flutter emits its generated plugin sources with LF.
            continue
        selected = name in names or name.startswith(prefixes)
        if name.startswith("assets/"):
            selected = (not name.startswith("assets/bin/") or
                        name.startswith(f"assets/bin/{family}/") or
                        name == "assets/bin/windows/geosite.dat")
        if not selected:
            continue
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing or symbolic source input: {name}")
        inputs[name] = archive_tools.sha256_file(path)
    if not inputs or "pubspec.lock" not in inputs:
        raise ValueError("No locked application inputs")
    # New scripts may not be staged while running local regression checks.
    for name in names:
        path = root / name
        if path.is_file():
            inputs[name] = archive_tools.sha256_file(path)
    tools = {"flutter": TOOLCHAIN["flutter"],
             "runner": "windows-2022" if family == "windows" else "ubuntu-24.04",
             "runnerImageVersion": os.environ.get("ImageVersion", "local")}
    if family == "android":
        certificate = certificate or os.environ.get("ANDROID_SIGNING_CERT_SHA256", "")
        if not re.fullmatch(r"[0-9a-f]{64}", certificate):
            raise ValueError("Android build requires its signing certificate SHA-256")
        tools.update(TOOLCHAIN, signingCertificateSHA256=certificate)
    inputs = {"schema": 1, "platform": platform, "files": inputs, "toolchain": tools,
              "arguments": ["--release", "--no-pub", "--target-platform", "android-arm64"]
              if family == "android" else ["--release", "--no-pub"]}
    return hashlib.sha256(archive_tools.canonical_json(inputs)).hexdigest()


def pack(source, archive, component, platform, value, commit=None):
    source, archive = Path(source).resolve(), Path(archive).resolve()
    if archive.is_relative_to(source):
        raise ValueError("Archive cannot be inside its payload")
    commit = commit or archive_tools.source_commit(ROOT)
    manifest = {"schemaVersion": 1, "component": component, "arch": platform,
                "fingerprint": value, "sourceCommit": commit,
                "entries": archive_tools.source_entries(source)}
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = archive.with_suffix(".part")
    try:
        with tarfile.open(temporary, "w", format=tarfile.PAX_FORMAT) as output:
            data = archive_tools.canonical_json(manifest)
            info = tarfile.TarInfo("manifest.json")
            info.size, info.mode = len(data), 0o644
            output.addfile(info, io.BytesIO(data))
            info = tarfile.TarInfo("payload")
            info.type, info.mode = tarfile.DIRTYPE, 0o755
            output.addfile(info)
            for name, entry in manifest["entries"].items():
                info = tarfile.TarInfo("payload/" + name)
                info.mode = entry["mode"]
                if entry["type"] == "directory":
                    info.type = tarfile.DIRTYPE
                    output.addfile(info)
                elif entry["type"] == "symlink":
                    info.type, info.linkname = tarfile.SYMTYPE, entry["target"]
                    output.addfile(info)
                else:
                    info.size = entry["size"]
                    with (source / name).open("rb") as stream:
                        output.addfile(info, stream)
        archive_tools.validate_archive(temporary, component, platform, value)
        temporary.replace(archive)
        digest = archive_tools.sha256_file(archive)
        archive.with_name(archive.name + ".sha256").write_text(f"{digest}  {archive.name}\n")
        return manifest
    finally:
        temporary.unlink(missing_ok=True)


def restore(archive, destination, component, platform, value, commit=None):
    archive, destination = Path(archive), Path(destination)
    sidecar = archive.with_name(archive.name + ".sha256")
    expected = f"{archive_tools.sha256_file(archive)}  {archive.name}"
    if not sidecar.is_file() or sidecar.read_text().strip() != expected:
        raise ValueError("Checkpoint archive checksum mismatch")
    # Validate before making the restored component visible.
    manifest = archive_tools.validate_archive(archive, component, platform, value)
    if commit is not None and manifest["sourceCommit"] != commit:
        raise ValueError("Release archive source commit mismatch")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise ValueError("Checkpoint destination cannot be a symlink")
    with tempfile.TemporaryDirectory(prefix=".checkpoint-", dir=destination.parent) as work:
        payload = Path(work) / "payload"
        payload.mkdir()
        archive_tools.validate_archive(archive, component, platform, value, payload)
        if destination.exists():
            shutil.rmtree(destination)
        payload.replace(destination)
    return manifest


def unzip_checkpoint(transport, target):
    """Extract exactly a tar and its mandatory hash, without trusting ZIP paths."""
    target = Path(target)
    with zipfile.ZipFile(transport) as source:
        members = source.infolist()
        names = [entry.filename for entry in members]
        if len(names) != 2 or len(set(names)) != 2:
            raise ValueError("Artifact must contain only a tar and SHA-256 sidecar")
        for entry in members:
            archive_tools.safe_path(entry.filename)
            if "/" in entry.filename or entry.is_dir() or entry.file_size > archive_tools.MAX_ARCHIVE_BYTES:
                raise ValueError("Unsafe artifact member")
        tars = [name for name in names if name.endswith(".tar")]
        if len(tars) != 1 or tars[0] + ".sha256" not in names:
            raise ValueError("Artifact checksum sidecar missing")
        target.mkdir(parents=True, exist_ok=True)
        for name in names:
            with source.open(name) as input_stream, (target / name).open("wb") as output:
                shutil.copyfileobj(input_stream, output)
        return target / tars[0]


def fetch(platform, archive, destination, client=None):
    value = fingerprint(platform)
    pattern = re.compile(rf"platform-app-{re.escape(platform)}-{value}-attempt[1-9][0-9]*$")
    client = client or archive_tools.GitHubAPI(REPOSITORY, os.environ.get("GITHUB_TOKEN"))
    for run in client.pages(f"/repos/{REPOSITORY}/actions/workflows/macos.yml/runs?branch=dev", "workflow_runs"):
        if not archive_tools.trusted_run(run, REPOSITORY):
            continue
        candidates = client.pages(f"/repos/{REPOSITORY}/actions/runs/{run['id']}/artifacts", "artifacts")
        matches = sorted((a for a in candidates if not a.get("expired", True) and pattern.fullmatch(a.get("name", ""))),
                         key=lambda a: a["id"], reverse=True)
        for artifact in matches:
            try:
                with tempfile.TemporaryDirectory() as work:
                    transport = Path(work) / "download.zip"
                    client.download(artifact, transport)
                    source = unzip_checkpoint(transport, Path(work) / "archive")
                    manifest = restore(source, destination, "app", platform, value)
                    archive = Path(archive)
                    archive.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, archive)
                    archive.with_name(archive.name + ".sha256").write_text(
                        f"{archive_tools.sha256_file(archive)}  {archive.name}\n")
                    return {"hit": "true", "source-run-id": run["id"], "source-commit": manifest["sourceCommit"]}
            except urllib.error.HTTPError as error:
                if error.code not in (404, 410):
                    raise
                print(f"Expired artifact {artifact['id']}; checking another checkpoint", file=sys.stderr)
            except (ValueError, zipfile.BadZipFile) as error:
                print(f"Rejected artifact {artifact['id']}: {error}", file=sys.stderr)
    return {"hit": "false"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("fingerprint", "pack", "restore", "fetch", "seal-release"))
    parser.add_argument("--platform", required=True, choices=RELEASE_PLATFORMS)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    if args.operation == "seal-release":
        commit = archive_tools.source_commit(ROOT)
        value = hashlib.sha256(commit.encode()).hexdigest()
        pack(args.source, args.archive, "release", args.platform, value, commit)
        result = {"archive": str(args.archive)}
    elif args.operation == "fingerprint":
        value = fingerprint(args.platform)
        result = {"fingerprint": value, "artifact-prefix": f"platform-app-{args.platform}-{value}"}
    elif args.operation == "fetch":
        result = fetch(args.platform, args.archive, args.destination)
    elif args.operation == "restore":
        manifest = restore(args.archive, args.destination, "app", args.platform, fingerprint(args.platform))
        result = {"source-commit": manifest["sourceCommit"]}
    else:
        manifest = pack(args.source, args.archive, "app", args.platform, fingerprint(args.platform))
        result = {"source-commit": manifest["sourceCommit"]}
    archive_tools.write_outputs(result, args.github_output)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
