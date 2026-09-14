#!/usr/bin/env python3
"""Collect exact-commit development packages and publish a verified stable release.

A published release is immutable here: a retry succeeds only when its complete
asset set and hashes already match. Draft uploads can be resumed without
recompiling any application or core.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.error

import checkpoint
from package_platform import version

ROOT = checkpoint.ROOT
REPOSITORY = checkpoint.REPOSITORY
PLATFORMS = checkpoint.RELEASE_PLATFORMS


def signing_openssl():
    selected = os.environ.get("KEQDROID_SIGNING_OPENSSL") or shutil.which("openssl")
    if not selected or not Path(selected).is_absolute() or not os.access(selected, os.X_OK):
        raise ValueError("Release signing requires an executable OpenSSL path")
    return str(Path(selected).resolve())


def release_public_keys():
    source = (ROOT / "lib/services/release_signature.dart").read_text(encoding="utf-8")
    declaration = re.search(r"publicKeys\s*=\s*const\s*\[(.*?)\]", source, re.S)
    if declaration is None:
        raise ValueError("Application release public keys are missing")
    keys = [base64.b64decode(value, validate=True)
            for value in re.findall(r"'([^']+)'", declaration[1])]
    if len(keys) != 2 or len(set(keys)) != 2 or any(len(key) != 32 for key in keys):
        raise ValueError("Application release public keys must be two distinct Ed25519 keys")
    return keys


def verify_release_manifest(directory, *, signed=True, openssl=None):
    """Check the complete aggregate before granting any release write access."""
    directory = Path(directory)
    entries = list(directory.iterdir())
    if any(not path.is_file() or path.is_symlink() for path in entries):
        raise ValueError("Release assets must be regular files")
    manifest = directory / "SHA256SUMS"
    expected = {}
    for line in manifest.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        if not match or match[2] in expected or match[2] in {"SHA256SUMS", "SHA256SUMS.sig"}:
            raise ValueError("Malformed, duplicate or self-referencing release checksum")
        expected[match[2]] = match[1]
    controls = {"SHA256SUMS", "SHA256SUMS.sig"} if signed else {"SHA256SUMS"}
    if not expected or {path.name for path in entries} != set(expected) | controls:
        raise ValueError("Signed checksum manifest does not cover every release asset")
    for name, digest in expected.items():
        if checkpoint.archive_tools.sha256_file(directory / name) != digest:
            raise ValueError(f"Release SHA-256 mismatch: {name}")
    if not signed:
        return
    openssl = openssl or signing_openssl()
    try:
        signature = base64.b64decode((directory / "SHA256SUMS.sig").read_text().strip(), validate=True)
    except ValueError as error:
        raise ValueError("Invalid release signature encoding") from error
    if len(signature) != 64:
        raise ValueError("Invalid Ed25519 release signature length")
    with tempfile.TemporaryDirectory(prefix="keqdroid-verify-signature-") as temporary:
        work = Path(temporary)
        (work / "signature").write_bytes(signature)
        for key in release_public_keys():
            # RFC 8410 SubjectPublicKeyInfo for a raw Ed25519 public key.
            public = work / "public.der"
            public.write_bytes(bytes.fromhex("302a300506032b6570032100") + key)
            result = subprocess.run([openssl, "pkeyutl", "-verify", "-pubin", "-keyform", "DER",
                                     "-inkey", str(public), "-rawin", "-in", str(manifest),
                                     "-sigfile", str(work / "signature")], capture_output=True, timeout=30)
            if result.returncode == 0:
                return
    raise ValueError("Release manifest is not signed by an application release key")


def sign_release_manifest(directory):
    directory = Path(directory).resolve()
    verify_release_manifest(directory, signed=False)
    openssl = signing_openssl()
    result = subprocess.run(["bash", str(ROOT / "tool/sign_sums.sh"), str(directory / "SHA256SUMS"), "-"],
                            cwd=ROOT, capture_output=True, timeout=30,
                            env={**os.environ, "KEQDROID_SIGNING_OPENSSL": openssl})
    if result.returncode != 0:
        # Do not attach subprocess output: the release secret is inherited.
        stages = re.findall(rb"^keqdroid-signing-stage=([a-z_]+)$", result.stderr, re.M)
        allowed = {b"resolve_openssl", b"read_key", b"sign", b"signature_size", b"encode_signature",
                   b"export_public_key", b"match_public_key", b"verify_signature", b"publish_signature"}
        stage = stages[-1].decode() if stages and stages[-1] in allowed else "unknown"
        raise ValueError(f"Release signing failed at {stage}; check UPDATE_SIGNING_KEY and OpenSSL")
    verify_release_manifest(directory, openssl=openssl)


def required_files(ver, platform):
    if platform in checkpoint.ANDROID_TARGETS:
        marker = "-armeabi-v7a" if platform == "android-arm32" else ""
        return {f"keqdroid-{ver}{marker}-android.apk", f"keqdroid-{ver}-{platform}-build.json"}
    if platform == "windows-x64":
        return {f"keqdroid-windows-x64-{ver}.zip", f"keqdroid-{ver}-windows-x64-build.json"}
    if platform == "linux-x64":
        return {f"keqdroid-{ver}-x86_64.AppImage", f"keqdroid_{ver}_amd64.deb",
                f"keqdroid-{ver}-1.x86_64.rpm", f"keqdroid-{ver}-linux-x64.tar.gz",
                "PKGBUILD", f"keqdroid-{ver}-linux-x64-build.json"}
    return {f"keqdroid-{ver}-{platform}.pkg", f"keqdroid-{ver}-{platform}-uninstall.pkg",
            f"keqdroid-{ver}-{platform}-verification.json", f"keqdroid-{ver}-{platform}-README.txt"}


def verify_payload(directory, ver, platform, commit):
    directory = Path(directory)
    files = {p.name for p in directory.iterdir() if p.is_file() and not p.is_symlink()}
    required = required_files(ver, platform)
    if files != required | {"SHA256SUMS"}:
        raise ValueError(f"Unexpected or missing {platform} release files: {files.symmetric_difference(required | {'SHA256SUMS'})}")
    sums = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        if not match or match[2] in sums:
            raise ValueError("Malformed or duplicate SHA256SUMS entry")
        sums[match[2]] = match[1]
    if set(sums) != required:
        raise ValueError("SHA256SUMS does not cover the complete package payload")
    for name, expected in sums.items():
        if checkpoint.archive_tools.sha256_file(directory / name) != expected:
            raise ValueError(f"Release SHA-256 mismatch: {name}")
    suffix = "verification" if platform.startswith("macos-") else "build"
    report = json.loads((directory / f"keqdroid-{ver}-{platform}-{suffix}.json").read_text())
    if report.get("sourceCommit") != commit or report.get("version") != ver:
        raise ValueError("Package report commit or version mismatch")
    if platform.startswith("macos-"):
        if (report.get("architecture") != platform.removeprefix("macos-") or report.get("signature") != "ad-hoc"
                or report.get("installerSignature") != "unsigned" or report.get("notarized") is not False):
            raise ValueError("macOS signature policy or architecture mismatch")
    elif report.get("platform") != platform:
        raise ValueError("Application package platform mismatch")
    return sums


def select_run(client, commit):
    path = f"/repos/{REPOSITORY}/actions/workflows/macos.yml/runs?branch=dev&head_sha={commit}&status=success"
    for run in client.pages(path, "workflow_runs"):
        if (checkpoint.archive_tools.trusted_run(run, REPOSITORY) and run.get("head_sha") == commit
                and run.get("status") == "completed" and run.get("conclusion") == "success"):
            return run
    raise ValueError("No successful trusted development workflow exists for this exact tag commit")


def collect(commit, ver, destination, client=None):
    if not checkpoint.archive_tools.COMMIT_PATTERN.fullmatch(commit):
        raise ValueError("Invalid target commit")
    client = client or checkpoint.archive_tools.GitHubAPI(REPOSITORY, os.environ.get("GITHUB_TOKEN"))
    run = select_run(client, commit)
    artifacts = list(client.pages(f"/repos/{REPOSITORY}/actions/runs/{run['id']}/artifacts", "artifacts"))
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise ValueError("Release collection directory must be empty")
    evidence = {}
    value = hashlib.sha256(commit.encode()).hexdigest()
    for platform in PLATFORMS:
        pattern = re.compile(rf"release-{re.escape(platform)}-{commit}-attempt[1-9][0-9]*$")
        matches = [a for a in artifacts if not a.get("expired", True) and pattern.fullmatch(a.get("name", ""))]
        if not matches:
            raise ValueError(f"Missing verified package artifact: {platform}")
        artifact = max(matches, key=lambda a: a["id"])
        with tempfile.TemporaryDirectory(prefix="keqdroid-release-") as work:
            transport = Path(work) / "download.zip"
            client.download(artifact, transport)
            archive = checkpoint.unzip_checkpoint(transport, Path(work) / "archive")
            payload = Path(work) / "payload"
            checkpoint.restore(archive, payload, "release", platform, value, commit)
            sums = verify_payload(payload, ver, platform, commit)
            for name in sums:
                target = destination / name
                if target.exists():
                    raise ValueError(f"Duplicate cross-platform release filename: {name}")
                shutil.copy2(payload / name, target)
            evidence[platform] = {"artifactId": artifact["id"], "artifactName": artifact["name"],
                                  "archiveSHA256": checkpoint.archive_tools.sha256_file(archive), "files": sums}
    geo = ROOT / "assets/bin/windows/geoip.dat"
    if not geo.is_file() or geo.stat().st_size < 1_000_000:
        raise ValueError("Full GeoIP database is missing or truncated")
    shutil.copy2(geo, destination / "geoip.dat")
    (destination / "geoip.dat.sha256").write_text(checkpoint.archive_tools.sha256_file(geo) + "\n")
    build = {"schemaVersion": 1, "repository": REPOSITORY, "sourceCommit": commit, "version": ver,
             "workflowRunId": run["id"], "workflowRunURL": run.get("html_url"), "platforms": evidence,
             "deviceCoverage": "See release notes; CI success does not establish untested device support."}
    (destination / f"keqdroid-{ver}-build-report.json").write_text(json.dumps(build, indent=2) + "\n")
    (destination / "SHA256SUMS").write_text("".join(f"{checkpoint.archive_tools.sha256_file(p)}  {p.name}\n"
        for p in sorted(destination.iterdir()) if p.is_file() and p.name != "SHA256SUMS"))
    return build


def gh(*args, **kwargs):
    return subprocess.run(["gh", *args], cwd=ROOT, check=True, **kwargs)


def remote_asset_hash(tag, asset):
    digest = asset.get("digest")
    if isinstance(digest, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        return digest.removeprefix("sha256:")
    # Older assets lack the API digest. gh handles authenticated redirects.
    with tempfile.TemporaryDirectory() as temporary:
        gh("release", "download", tag, "--repo", REPOSITORY, "--pattern", asset["name"], "--dir", temporary)
        return checkpoint.archive_tools.sha256_file(Path(temporary) / asset["name"])


def verify_existing_assets(tag, release, directory):
    expected = {p.name: checkpoint.archive_tools.sha256_file(p) for p in Path(directory).iterdir() if p.is_file()}
    actual = {asset["name"]: asset for asset in release.get("assets", [])}
    if set(expected) != set(actual) or len(actual) != len(release.get("assets", [])):
        raise ValueError("Existing public release has a different asset set; refusing to modify it")
    for name, digest in expected.items():
        if remote_asset_hash(tag, actual[name]) != digest:
            raise ValueError(f"Existing public release hash differs: {name}")


def require_draft(client, tag, directory):
    current = client.json(f"/repos/{REPOSITORY}/releases/tags/{tag}")
    if not current.get("draft"):
        verify_existing_assets(tag, current, directory)
        raise ValueError("Release became public during upload; no public assets were modified")
    return current


def publish(tag, commit, directory, notes):
    verify_release_manifest(directory)
    # The checked-out tag must resolve to the same immutable commit as the
    # development artifacts. No implicit default-branch release target.
    target = subprocess.check_output(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], cwd=ROOT, text=True).strip()
    if target != commit:
        raise ValueError("Release tag does not point at the verified development commit")
    client = checkpoint.archive_tools.GitHubAPI(REPOSITORY, os.environ.get("GITHUB_TOKEN"))
    try:
        release = client.json(f"/repos/{REPOSITORY}/releases/tags/{tag}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        error.close()
        release = None
    if release is not None and not release.get("draft"):
        verify_existing_assets(tag, release, directory)
        latest = client.json(f"/repos/{REPOSITORY}/releases/latest")
        if release.get("prerelease") or latest.get("tag_name") != tag:
            raise ValueError("Existing public release matches the files but is not the expected stable Latest release")
        print("Public release already has the complete verified asset set; nothing changed.")
        return
    if release is None:
        gh("release", "create", tag, "--repo", REPOSITORY, "--target", commit, "--verify-tag", "--draft",
           "--title", f"Keqdroid {tag}", "--notes-file", str(notes))
    else:
        require_draft(client, tag, directory)
        gh("release", "edit", tag, "--repo", REPOSITORY, "--title", f"Keqdroid {tag}", "--notes-file", str(notes))
    expected = {p.name for p in Path(directory).iterdir() if p.is_file()}
    # Only draft state can be repaired, and only within the authorized release.
    if release is not None:
        for asset in release.get("assets", []):
            if asset["name"] not in expected:
                require_draft(client, tag, directory)
                gh("api", "--method", "DELETE", f"repos/{REPOSITORY}/releases/assets/{asset['id']}")
    for path in sorted(Path(directory).iterdir()):
        if path.is_file():
            require_draft(client, tag, directory)
            gh("release", "upload", tag, str(path), "--repo", REPOSITORY, "--clobber")
    uploaded = require_draft(client, tag, directory)
    verify_existing_assets(tag, uploaded, directory)
    gh("release", "edit", tag, "--repo", REPOSITORY, "--draft=false", "--prerelease=false", "--latest")
    latest = client.json(f"/repos/{REPOSITORY}/releases/latest")
    if latest.get("tag_name") != tag or latest.get("draft") or latest.get("prerelease"):
        raise ValueError("Published release did not become stable Latest")
    verify_existing_assets(tag, latest, directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--notes", type=Path, default=ROOT / "docs/RELEASE_NOTES.md")
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    ver = version()
    if args.tag != "v" + ver:
        raise ValueError("Tag and pubspec release versions differ")
    if os.environ.get("GITHUB_REPOSITORY", REPOSITORY) != REPOSITORY:
        raise ValueError("Publishing is restricted to the configured distribution repository")
    head = checkpoint.archive_tools.source_commit(ROOT)
    if head != args.commit:
        raise ValueError("Checked out code differs from release target")
    if not args.notes.is_file():
        raise ValueError("Release notes with device coverage and migration instructions are required")
    collect(args.commit, ver, args.output)
    sign_release_manifest(args.output)
    if args.publish:
        publish(args.tag, args.commit, args.output, args.notes)


if __name__ == "__main__":
    main()
