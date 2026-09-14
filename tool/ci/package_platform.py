#!/usr/bin/env python3
"""Package a previously verified app without invoking Flutter or a compiler."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

import checkpoint

ROOT = checkpoint.ROOT


def version():
    match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$", (ROOT / "pubspec.yaml").read_text(encoding="utf-8-sig"), re.M)
    if not match:
        raise ValueError("Invalid release version")
    return match.group(1)


def package(platform, source, destination):
    ver = version()
    destination.mkdir(parents=True, exist_ok=True)
    report = json.loads((source / "component-build.json").read_text(encoding="utf-8"))
    if report.get("platform") != platform:
        raise ValueError("Application platform mismatch")
    if platform == "android-arm64":
        shutil.copy2(source / "app-release.apk", destination / f"keqdroid-{ver}-android.apk")
    elif platform == "windows-x64":
        with zipfile.ZipFile(destination / f"keqdroid-windows-x64-{ver}.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(source.rglob("*")):
                name = path.relative_to(source).as_posix()
                if name == "component-build.json" or name.startswith(("data/flutter_assets/assets/bin/windows/", "data/flutter_assets/assets/geo/")):
                    continue
                if path.is_file():
                    archive.write(path, name)
    else:
        bundle = ROOT / "build/linux/x64/release/bundle"
        if bundle.exists():
            shutil.rmtree(bundle)
        shutil.copytree(source, bundle, symlinks=True)
        (bundle / "component-build.json").unlink()
        subprocess.run(["bash", "tool/package_linux.sh", "--no-build"], cwd=ROOT, check=True)
        for path in (ROOT / "release" / ver).iterdir():
            if path.is_file() and path.name != "SHA256SUMS":
                shutil.copy2(path, destination / path.name)
    report = {"schemaVersion": 1, "platform": platform, "version": ver,
              "sourceCommit": checkpoint.archive_tools.source_commit(ROOT), "component": report,
              "files": {p.name: checkpoint.archive_tools.sha256_file(p) for p in sorted(destination.iterdir()) if p.is_file()}}
    (destination / f"keqdroid-{ver}-{platform}-build.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
    (destination / "SHA256SUMS").write_text("".join(f"{checkpoint.archive_tools.sha256_file(p)}  {p.name}\n"
                                               for p in sorted(destination.iterdir()) if p.is_file() and p.name != "SHA256SUMS"),
                                            encoding="utf-8", newline="\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=checkpoint.PLATFORMS)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    package(args.platform, args.source.resolve(), args.destination.resolve())
