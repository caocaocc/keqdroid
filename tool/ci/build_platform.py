#!/usr/bin/env python3
"""Compile one non-macOS application; packaging is a separate checkpoint consumer."""
import argparse
import json
import re
import os
from pathlib import Path
import shutil
import subprocess

import checkpoint

ROOT = checkpoint.ROOT


def run(*args, **kwargs):
    command = list(args)
    # Flutter is a batch entrypoint on Windows. cmd handles .bat without
    # flattening arbitrary repository or credential values into shell code.
    if os.name == "nt" and command[0] == "flutter":
        command[0] = shutil.which("flutter.bat") or "flutter.bat"
    return subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def verify_binary(path, family):
    with Path(path).open("rb") as stream:
        header = stream.read(64)
        if family == "linux":
            if len(header) < 20 or header[:6] != b"\x7fELF\x02\x01" or int.from_bytes(header[18:20], "little") != 62:
                raise ValueError(f"Expected Linux x86_64 ELF: {path.name}")
        else:
            if len(header) < 64 or header[:2] != b"MZ":
                raise ValueError(f"Expected Windows PE: {path.name}")
            offset = int.from_bytes(header[60:64], "little")
            if not 64 <= offset <= 16 * 1024 * 1024:
                raise ValueError(f"Invalid PE header offset: {path.name}")
            stream.seek(offset)
            pe = stream.read(6)
            if pe[:4] != b"PE\0\0" or int.from_bytes(pe[4:6], "little") != 0x8664:
                raise ValueError(f"Expected Windows x64 PE: {path.name}")


def verify_payload(platform, destination):
    if platform == "android-arm64":
        apk = destination / "app-release.apk"
        sdk = Path(os.environ["ANDROID_HOME"])
        apksigners = sorted(sdk.glob("build-tools/*/apksigner"))
        aapts = sorted(sdk.glob("build-tools/*/aapt"))
        if not apksigners or not aapts:
            raise ValueError("Android signing verification tools unavailable")
        from verify_android import verify, verify_signing_output
        signature = subprocess.run([str(apksigners[-1]), "verify", "--verbose", "--print-certs", str(apk)],
                                   capture_output=True, text=True, timeout=60)
        expected = os.environ["ANDROID_SIGNING_CERT_SHA256"]
        # Preserve public signature evidence even when verification fails. No
        # private key, password or certificate subject is included in this log.
        signature_log = {"tool": str(apksigners[-1]), "exitCode": signature.returncode,
                         "expectedCertificateSHA256": expected,
                         "evidence": [line for line in signature.stdout.splitlines()
                                      if "certificate SHA-256 digest:" in line or line.startswith(("Verified using", "Number of signers:"))],
                         "errors": signature.stderr[-4000:]}
        logs = ROOT / "build/platform-logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "android-signature.json").write_text(json.dumps(signature_log, indent=2) + "\n")
        print(json.dumps(signature_log), flush=True)
        signature.check_returncode()
        signing = verify_signing_output(signature.stdout, expected)
        release = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$", (ROOT / "pubspec.yaml").read_text(), re.M)
        if not release:
            raise ValueError("Release version and Android build number are required")
        evidence = verify(apk, aapts[-1], release[1], release[2], ROOT)
        return {**evidence, **signing}
    family = platform.split("-")[0]
    names = ["keqdroid.exe", "keqrnel.exe", "mihomo.exe", "wintun.dll"] if family == "windows" else ["keqdroid", "keqrnel", "mihomo"]
    for name in names + ["geoip.dat", "geosite.dat"]:
        path = destination / name
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Missing desktop payload: {name}")
        if name in names:
            verify_binary(path, family)
        if family == "linux" and name in names and not path.stat().st_mode & 0o111:
            raise ValueError(f"Desktop executable lost its permissions: {name}")
        source = ROOT / "assets" / "bin" / family / name
        if source.is_file() and checkpoint.archive_tools.sha256_file(path) != checkpoint.archive_tools.sha256_file(source):
            raise ValueError(f"Desktop payload differs from tracked core/data: {name}")
    runtime = ["flutter_windows.dll", "data/app.so"] if family == "windows" else ["lib/libflutter_linux_gtk.so", "lib/libapp.so"]
    if not (destination / "data/flutter_assets").is_dir() or any(not (destination / path).is_file() for path in runtime):
        raise ValueError("Flutter engine, AOT image or assets missing from desktop bundle")
    return {"trackedCores": {name: checkpoint.archive_tools.sha256_file(destination / name) for name in names[1:]}}


def build(platform, destination):
    initial_fingerprint = checkpoint.fingerprint(platform)
    expected = os.environ.get("EXPECTED_APP_FINGERPRINT", initial_fingerprint)
    if initial_fingerprint != expected:
        raise ValueError("App input fingerprint changed before compilation")
    version = json.loads(run("flutter", "--version", "--machine", capture_output=True, text=True).stdout)
    if version["frameworkVersion"] != "3.44.4":
        raise ValueError("Flutter 3.44.4 required")
    run("flutter", "pub", "get", "--enforce-lockfile")
    if platform == "android-arm64":
        run("flutter", "build", "apk", "--release", "--no-pub", "--target-platform", "android-arm64")
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "build/app/outputs/flutter-apk/app-release.apk", destination / "app-release.apk")
    else:
        family = platform.split("-")[0]
        if family == "windows":
            # Follow the upstream release path: Firebase registration remains
            # Android-only even when pub get generates a Windows plugin entry.
            run("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tool/sync_windows_plugins.ps1"))
        if family == "linux":
            for name in ("keqrnel", "mihomo"):
                (ROOT / "assets/bin/linux" / name).chmod(0o755)
        run("flutter", "build", family, "--release", "--no-pub")
        bundle = ROOT / ("build/windows/x64/runner/Release" if family == "windows" else "build/linux/x64/release/bundle")
        shutil.copytree(bundle, destination, symlinks=True, dirs_exist_ok=True)
    verification = verify_payload(platform, destination)
    if checkpoint.fingerprint(platform) != initial_fingerprint:
        raise ValueError("Application compilation changed a source or dependency fingerprint")
    report = {"schemaVersion": 1, "platform": platform, "sourceCommit": checkpoint.archive_tools.source_commit(ROOT),
              "fingerprint": checkpoint.fingerprint(platform), "flutter": version,
              "runner": {key: os.environ.get(key) for key in ("RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion")},
              "verification": verification}
    (destination / "component-build.json").write_text(json.dumps(report, indent=2) + "\n")
    # Generation is allowed; dependency resolution must not silently change locks.
    run("git", "diff", "--exit-code", "--", "pubspec.lock")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=checkpoint.PLATFORMS)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    build(args.platform, args.destination.resolve())
