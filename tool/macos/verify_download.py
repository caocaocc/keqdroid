#!/usr/bin/env python3
"""Inspect a downloaded development DMG without installing or running its code.

By default this verifies the download hash, target commit/architecture and disk
image integrity. --inspect-payload additionally mounts read-only, expands both
PKGs into a temporary directory, checks signatures and Mach-O metadata, and
compares installer scripts with the specified source commit. It never invokes
Installer, a bundled executable, launchctl or any networking configuration tool.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

try:
    from .build_cores import macho_info
    from .ci_artifacts import safe_path, source_entries
except ImportError:
    from build_cores import macho_info
    from ci_artifacts import safe_path, source_entries

ROOT = Path(__file__).resolve().parents[2]
STAGE = Path("Library/Application Support/io.github.caocaocc.keqdroid.incoming")
CORES = ("keqrnel", "mihomo", "wireproxy")
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
COMMIT = re.compile(r"^[a-f0-9]{40}$")
SHA256 = re.compile(r"^[a-f0-9]{64}$")
CLIENT_REQUIREMENT = re.compile(r'^cdhash H"[a-f0-9]{40}"$')


def file_hash(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def read_json(path):
    path = Path(path)
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError("Verification report exceeds the size limit")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON verification object")
    return value


def check_download(dmg, checksum, report_path, arch, commit):
    dmg, checksum = Path(dmg), Path(checksum)
    if arch not in ("arm64", "x64") or not COMMIT.fullmatch(commit):
        raise ValueError("Expected an explicit architecture and full 40-character target commit")
    if not dmg.is_file() or dmg.is_symlink() or dmg.suffix != ".dmg":
        raise ValueError("Expected a downloaded regular .dmg file")
    lines = checksum.read_text().strip().splitlines()
    if len(lines) != 1:
        raise ValueError("Expected exactly one DMG SHA-256 record")
    match = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", lines[0])
    if not match or match.group(2) != dmg.name:
        raise ValueError("SHA-256 record does not identify the downloaded DMG")
    actual = file_hash(dmg)
    if actual != match.group(1):
        raise ValueError("Downloaded DMG SHA-256 mismatch")
    report = read_json(report_path)
    if report.get("architecture") != arch or report.get("sourceCommit") != commit:
        raise ValueError("Verification report architecture or source commit does not match the requested build")
    version = report.get("version", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", version):
        raise ValueError("Invalid version in verification report")
    if dmg.name != f"keqdroid-{version}-macos-{arch}.dmg":
        raise ValueError("DMG filename does not match the verified version and architecture")
    if report.get("signature") != "ad-hoc" or report.get("installerSignature") != "unsigned" or report.get("notarized") is not False:
        raise ValueError("Unexpected distribution signing policy")
    if not CLIENT_REQUIREMENT.fullmatch(str(report.get("clientRequirement", ""))):
        raise ValueError("Missing exact signed client fingerprint")
    entries = report.get("files")
    if not isinstance(entries, dict) or not entries:
        raise ValueError("Verification report has no executable inventory")
    for name, details in entries.items():
        safe_path(name)
        if not isinstance(details, dict) or details.get("architecture") != arch:
            raise ValueError("Verification report contains another executable architecture")
        minimum = details.get("minimumMacOS", "")
        if not re.fullmatch(r"\d+\.\d+\.\d+", minimum) or tuple(map(int, minimum.split("."))) > (12, 0, 0):
            raise ValueError("Verification report contains an incompatible minimum macOS version")
        if not SHA256.fullmatch(str(details.get("sha256", ""))) or type(details.get("size")) is not int or details["size"] <= 0:
            raise ValueError("Verification report contains an invalid executable digest or size")
    required = {"KEQDIS.app/Contents/MacOS/KEQDIS", "runtime/bin/keqdis-network-service"}
    required.update(f"runtime/bin/{core}" for core in CORES)
    required.update(f"KEQDIS.app/Contents/Resources/cores/{core}" for core in CORES)
    if not required.issubset(entries):
        raise ValueError("Verification report omits required application or network components")
    return report, {"sourceCommit": commit, "architecture": arch, "version": version,
                    "dmgSHA256": actual, "downloadVerified": True,
                    "diskImageVerified": False, "payloadVerified": False}


def command(*arguments, check=True):
    # Every executable in this module is a fixed system inspection tool. Package
    # paths are arguments; neither package scripts nor payload code are executed.
    return subprocess.run(list(map(str, arguments)), check=check, capture_output=True,
                          env=dict(os.environ, LC_ALL="C"))


def check_distribution(path, arch, uninstall=False):
    document = ET.parse(path).getroot()
    options = document.find("options")
    minimum = document.find("./volume-check/allowed-os-versions/os-version")
    expected_arch = "arm64" if arch == "arm64" else "x86_64"
    if options is None or options.get("hostArchitectures") != expected_arch:
        raise ValueError("PKG does not enforce the selected architecture")
    if minimum is None or minimum.get("min") != "12.0":
        raise ValueError("PKG does not enforce the macOS 12 minimum")
    expected_id = "io.github.caocaocc.keqdroid." + ("uninstaller" if uninstall else "installer")
    references = [item for item in document.findall("pkg-ref") if item.text and item.text.strip()]
    expected_package = "uninstall-component.pkg" if uninstall else "install-component.pkg"
    # productbuild rewrites an embedded component reference to '#name.pkg'.
    # Accept only that exact local fragment or the source distribution spelling;
    # never resolve arbitrary URLs, paths or package names from the payload.
    expected_references = {expected_package, "#" + expected_package}
    if len(references) != 1 or references[0].get("id") != expected_id or references[0].text.strip() not in expected_references:
        raise ValueError("Unexpected component package in distribution")


def check_script(path, repository, commit, source_name):
    expected = command("/usr/bin/git", "-C", repository, "show", f"{commit}:tool/macos/installer/{source_name}").stdout
    if Path(path).is_symlink() or Path(path).read_bytes() != expected:
        raise ValueError(f"Installer script differs from target source commit: {source_name}")


def inspect_stage(stage, report, arch):
    # This also rejects out-of-tree links, special files and privileged modes.
    source_entries(stage)
    binaries = {}
    for path in sorted(stage.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in MAGIC:
                continue
        relative = path.relative_to(stage).as_posix()
        binaries[relative] = macho_info(path, arch)
        command("/usr/bin/codesign", "--verify", "--strict", path)
    if binaries != report["files"]:
        raise ValueError("Expanded package executable inventory differs from its CI verification report")
    app = stage / "KEQDIS.app"
    # codesign interprets a plain -R value as a filename; '=' selects a literal
    # requirement expression (the helper's stored requirement omits this prefix).
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=" + report["clientRequirement"], app)
    runtime = stage / "runtime"
    if (runtime / "client-requirement.txt").read_text().strip() != report["clientRequirement"]:
        raise ValueError("Helper's installed client fingerprint differs from the signed application")
    manifest = read_json(runtime / "core-manifest.json")
    expected = {core: {"sha256": file_hash(runtime / "bin" / core)} for core in CORES}
    if manifest != expected or report.get("coresAfterSigning") != expected:
        raise ValueError("Signed core manifest does not match the packaged binaries")
    for core in CORES:
        if file_hash(app / "Contents/Resources/cores" / core) != expected[core]["sha256"]:
            raise ValueError("GUI and helper packaged cores differ")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "io.github.caocaocc.keqdroid" or info.get("CFBundleExecutable") != "KEQDIS":
        raise ValueError("Unexpected application bundle identity")
    return {"executablesVerified": len(binaries), "clientRequirement": report["clientRequirement"]}


def inspect_payload(dmg, report, arch, commit, repository):
    with tempfile.TemporaryDirectory(prefix="keqdis-download-verification-") as temporary:
        work = Path(temporary)
        mount = work / "media"
        mount.mkdir()
        mounted = False
        try:
            command("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                    "-mountpoint", mount, "-plist", Path(dmg).resolve())
            mounted = True
            expanded = work / "install"
            command("/usr/sbin/pkgutil", "--expand-full", mount / "Install KEQDIS.pkg", expanded)
            check_distribution(expanded / "Distribution", arch)
            component = expanded / "install-component.pkg"
            check_script(component / "Scripts/preinstall", repository, commit, "preinstall")
            check_script(component / "Scripts/postinstall", repository, commit, "postinstall")
            stage = component / "Payload" / STAGE
            if not stage.is_dir() or stage.is_symlink():
                raise ValueError("Installer payload does not contain the fixed staging directory")
            result = inspect_stage(stage, report, arch)
            uninstall = work / "uninstall"
            command("/usr/sbin/pkgutil", "--expand-full", mount / "Uninstall KEQDIS.pkg", uninstall)
            check_distribution(uninstall / "Distribution", arch, uninstall=True)
            check_script(uninstall / "uninstall-component.pkg/Scripts/preinstall", repository, commit, "uninstall")
            return {**result, "payloadVerified": True, "installerScriptsVerified": True,
                    "installerExecuted": False, "payloadExecutablesRun": False}
        finally:
            if mounted:
                command("/usr/bin/hdiutil", "detach", mount)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--sha256", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--arch", choices=("arm64", "x64"), required=True)
    parser.add_argument("--commit", required=True, help="Full Git commit expected from CI")
    parser.add_argument("--inspect-payload", action="store_true")
    parser.add_argument("--repository", type=Path, default=ROOT, help="Local Git checkout containing the target commit")
    parser.add_argument("--output", type=Path, help="Optional local verification JSON")
    args = parser.parse_args()
    try:
        report, result = check_download(args.dmg, args.sha256, args.report, args.arch, args.commit)
        if sys.platform != "darwin":
            raise ValueError("Disk image inspection requires macOS")
        command("/usr/bin/hdiutil", "verify", args.dmg.resolve())
        result["diskImageVerified"] = True
        if args.inspect_payload:
            result.update(inspect_payload(args.dmg, report, args.arch, args.commit, args.repository.resolve()))
        data = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(data)
        print(data, end="")
    except (OSError, ValueError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"Downloaded build verification failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors="replace")[-3000:], file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
