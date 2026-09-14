#!/usr/bin/env python3
"""Compile one non-macOS application; packaging is a separate checkpoint consumer."""
import argparse
import json
import re
import os
from pathlib import Path
import shutil
import subprocess
import sys

import checkpoint

ROOT = checkpoint.ROOT


def run(*args, **kwargs):
    command = list(args)
    # Flutter is a batch entrypoint on Windows. cmd handles .bat without
    # flattening arbitrary repository or credential values into shell code.
    if os.name == "nt" and command[0] == "flutter":
        command[0] = shutil.which("flutter.bat") or "flutter.bat"
    return subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def parse_flutter_version(output, expected):
    """Read one machine object after optional Flutter startup/update notices.

    Flutter 3.44.4 prints the version object last (flutter_command_runner.dart).
    Startup notices are not machine JSON; never scan past a damaged object or
    select the desired version from multiple objects.
    """
    text = output.decode("utf-8-sig").strip()
    ansi = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
    start = text.find("{")
    if start < 0:
        raise ValueError("Flutter version output contains no machine JSON object")
    prefix = ansi.sub("", text[:start])
    if any(character in prefix for character in "[]}"):
        raise ValueError("Flutter version output contains another or damaged JSON value")
    for line in prefix.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('"'):
            raise ValueError("Flutter version output contains another or damaged JSON value")
        try:
            json.JSONDecoder().raw_decode(line)
        except ValueError:
            pass
        else:
            raise ValueError("Flutter version output contains more than one JSON value")

    def unique_fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Duplicate Flutter version field: {key}")
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValueError(f"Invalid JSON constant in Flutter version: {value}")

    decoder = json.JSONDecoder(object_pairs_hook=unique_fields,
                               parse_constant=invalid_constant)
    version, end = decoder.raw_decode(text, start)
    if ansi.sub("", text[end:]).strip():
        raise ValueError("Flutter version output contains extra data or multiple JSON values")
    if not isinstance(version, dict) or version.get("frameworkVersion") != expected:
        raise ValueError(f"Flutter {expected} required")
    if version.get("flutterVersion") != expected:
        raise ValueError("Flutter machine version fields disagree")
    for key in ("frameworkRevision", "engineRevision"):
        if not isinstance(version.get(key), str) or not re.fullmatch(r"[0-9a-f]{40}", version[key]):
            raise ValueError(f"Flutter machine JSON has no valid {key}")
    if not isinstance(version.get("dartSdkVersion"), str) or not version["dartSdkVersion"]:
        raise ValueError("Flutter machine JSON has no Dart SDK version")
    return version


def flutter_version():
    command = ("flutter", "--no-version-check", "--version", "--machine")
    logs = ROOT / "build/platform-logs"
    logs.mkdir(parents=True, exist_ok=True)
    failure = None
    try:
        result = run(*command, capture_output=True, timeout=120)
        output, errors, returncode = result.stdout, result.stderr, result.returncode
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
        failure = error
        output = getattr(error, "stdout", None) or b""
        errors = getattr(error, "stderr", None) or b""
        returncode = getattr(error, "returncode", None)
    # Keep exact bytes, including empty output, before parsing or raising. This
    # command contains no signing inputs; diagnostics must also survive errors.
    (logs / "flutter-version.stdout.log").write_bytes(output)
    (logs / "flutter-version.stderr.log").write_bytes(errors)
    evidence = {"command": command, "exitCode": returncode,
                "stdoutBytes": len(output), "stderrBytes": len(errors),
                "timedOut": isinstance(failure, subprocess.TimeoutExpired)}
    if failure:
        evidence["commandError"] = str(failure)
    (logs / "flutter-version.json").write_text(
        json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    if failure:
        raise failure
    try:
        return parse_flutter_version(output, checkpoint.TOOLCHAIN["flutter"])
    except (ValueError, UnicodeError) as error:
        raise ValueError(f"Invalid Flutter machine version: {error}; see {logs / 'flutter-version.stdout.log'}") from error


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


def retired_core_names(family):
    suffix = ".exe" if family == "windows" else ""
    return tuple(name + suffix for name in ("keqrnel", "sing-box", "singbox", "wireproxy", "wireproxy-awg"))


def clear_retired_cores(bundle, family):
    # Older compilation caches may retain executables removed from CMake's
    # install list. Remove only the known retired names from this build output.
    for name in retired_core_names(family):
        path = bundle / name
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.exists():
            raise ValueError(f"Unexpected directory at retired desktop core: {name}")


def verify_payload(platform, destination):
    if platform in checkpoint.ANDROID_TARGETS:
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
        evidence = verify(apk, aapts[-1], release[1], release[2], ROOT, native_abi=checkpoint.ANDROID_TARGETS[platform]["abi"])
        return {**evidence, **signing}
    family = platform.split("-")[0]
    names = ["keqdroid.exe", "xray.exe", "mihomo.exe", "wintun.dll"] if family == "windows" else ["keqdroid", "xray", "mihomo"]
    vc_runtime = ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"] if family == "windows" else []
    for name in retired_core_names(family):
        if (destination / name).exists() or (destination / name).is_symlink():
            raise ValueError(f"Retired desktop core in application bundle: {name}")
    for name in names + vc_runtime + ["geoip.dat", "geosite.dat"]:
        path = destination / name
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Missing desktop payload: {name}")
        if name in names + vc_runtime:
            verify_binary(path, family)
        if family == "linux" and name in names and not path.stat().st_mode & 0o111:
            raise ValueError(f"Desktop executable lost its permissions: {name}")
        source = ROOT / "assets" / "bin" / family / name
        if source.is_file() and checkpoint.archive_tools.sha256_file(path) != checkpoint.archive_tools.sha256_file(source):
            raise ValueError(f"Desktop payload differs from tracked core/data: {name}")
    runtime = ["flutter_windows.dll", "data/app.so"] if family == "windows" else ["lib/libflutter_linux_gtk.so", "lib/libapp.so"]
    if not (destination / "data/flutter_assets").is_dir() or any(not (destination / path).is_file() for path in runtime):
        raise ValueError("Flutter engine, AOT image or assets missing from desktop bundle")
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from shader_assets import verify_directory
    shaders = verify_directory(ROOT, destination / "data/flutter_assets")
    return {"trackedCores": {name: checkpoint.archive_tools.sha256_file(destination / name) for name in names[1:]},
            "vcRuntime": {name: checkpoint.archive_tools.sha256_file(destination / name) for name in vc_runtime},
            "shaders": shaders}


def build(platform, destination):
    initial_fingerprint = checkpoint.fingerprint(platform)
    expected = os.environ.get("EXPECTED_APP_FINGERPRINT", initial_fingerprint)
    if initial_fingerprint != expected:
        raise ValueError("App input fingerprint changed before compilation")
    version = flutter_version()
    run("flutter", "pub", "get", "--enforce-lockfile")
    if platform in checkpoint.ANDROID_TARGETS:
        run("flutter", "build", "apk", "--release", "--no-pub", "--target-platform", checkpoint.ANDROID_TARGETS[platform]["flutter"])
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "build/app/outputs/flutter-apk/app-release.apk", destination / "app-release.apk")
    else:
        family = platform.split("-")[0]
        if family == "windows":
            # Follow the upstream release path: Firebase registration remains
            # Android-only even when pub get generates a Windows plugin entry.
            run("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tool/sync_windows_plugins.ps1"))
        if family == "linux":
            for name in ("xray", "mihomo"):
                (ROOT / "assets/bin/linux" / name).chmod(0o755)
        from native_assets_cache import repair_native_assets_cache
        repair_native_assets_cache(platform, root=ROOT)
        run("flutter", "build", family, "--release", "--no-pub")
        bundle = ROOT / ("build/windows/x64/runner/Release" if family == "windows" else "build/linux/x64/release/bundle")
        clear_retired_cores(bundle, family)
        if destination.is_symlink():
            raise ValueError("Application component destination cannot be a symlink")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(bundle, destination, symlinks=True)
    verification = verify_payload(platform, destination)
    if platform not in checkpoint.ANDROID_TARGETS:
        from native_assets_cache import verify_native_assets
        verification["nativeAssets"] = verify_native_assets(platform, destination, root=ROOT)
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
