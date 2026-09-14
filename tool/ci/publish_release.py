#!/usr/bin/env python3
"""Collect exact-commit development packages and publish a verified stable release.

A published release is immutable here: a retry succeeds only when its complete
asset set and hashes already match. Draft uploads can be resumed without
recompiling any application or core.
"""
import argparse
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


def required_files(ver, platform):
    if platform == "android-arm64":
        return {f"keqdroid-{ver}-android.apk", f"keqdroid-{ver}-android-arm64-build.json"}
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
    if args.publish:
        publish(args.tag, args.commit, args.output, args.notes)


if __name__ == "__main__":
    main()
