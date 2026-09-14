#!/usr/bin/env python3
"""Repair incomplete Flutter 3.44.4 desktop native-asset intermediates.

Flutter's InstallCodeAssets writes install_code_assets.stamp and declares
native_assets.json plus installed files in install_code_assets.d. Its required
build/native_assets/<os> directory is not an output when there are no libraries.
Restoring the stamp without this directory therefore skips its creation.

Only remove the installation target's stamp; Flutter then reruns that target
(build_system.dart: Node.withNoStamp), keeping Dart hooks, AOT and C++ caches.
Flutter itself regenerates missing hook outputs through DartBuild's depfile.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DESKTOP_PLATFORMS = {"linux-x64": "linux", "windows-x64": "windows"}


def _read_json(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def _other_desktop_platform(directory, family):
    # A local workspace can contain both desktop graphs. CI restores a cache
    # for just one platform; unfinished graphs may have no platform stamp yet.
    other = "windows" if family == "linux" else "linux"
    return ((directory / f"unpack_{other}.stamp").is_file() and
            not (directory / f"unpack_{family}.stamp").is_file())


def repair_native_assets_cache(platform, root=ROOT):
    """Invalidate only incomplete desktop installation targets, returning evidence.

    Call after restoring compilation intermediates and before flutter build.
    No directories, libraries, depfiles or compilation outputs are fabricated
    or removed. Other platforms retain their existing build behavior.
    """
    family = DESKTOP_PLATFORMS.get(platform)
    if family is None:
        return []
    root = Path(root).resolve()
    native_directory = root / "build/native_assets" / family
    repaired = []
    for stamp in sorted((root / ".dart_tool/flutter_build").glob("*/install_code_assets.stamp")):
        if stamp.is_symlink() or not stamp.resolve().is_relative_to(root):
            raise ValueError(f"Unsafe Flutter native asset stamp: {stamp}")
        if _other_desktop_platform(stamp.parent, family):
            continue
        reasons = []
        if not native_directory.is_dir():
            reasons.append(f"Missing output directory: build/native_assets/{family}")
        try:
            data = _read_json(stamp)
            outputs = data.get("outputs") if isinstance(data, dict) else None
            if not isinstance(outputs, list) or not outputs or any(not isinstance(p, str) for p in outputs):
                raise ValueError("Invalid install_code_assets outputs")
            for output in outputs:
                path = Path(output)
                if not path.is_absolute():
                    path = root / path
                if not path.is_file():
                    reasons.append(f"Missing output file: {output}")
        except (ValueError, UnicodeError):
            reasons.append("Unreadable install_code_assets stamp")
        if reasons:
            stamp.unlink()
            evidence = {"stamp": stamp.relative_to(root).as_posix(), "reasons": reasons}
            repaired.append(evidence)
            print("Repairing Flutter native asset cache: " + json.dumps(evidence), flush=True)
    return repaired


def _bundled_names(manifest, platform):
    if not isinstance(manifest, dict) or manifest.get("format-version") != [1, 0, 0]:
        raise ValueError("Invalid Flutter native asset manifest version")
    targets = manifest.get("native-assets")
    if not isinstance(targets, dict):
        raise ValueError("Invalid Flutter native asset manifest targets")
    target = platform.replace("-", "_")
    if targets and set(targets) != {target}:
        raise ValueError(f"Unexpected Flutter native asset target: expected {target}")
    assets = targets.get(target, {})
    if not isinstance(assets, dict):
        raise ValueError("Invalid Flutter native asset entries")
    names = set()
    for asset, location in assets.items():
        if not isinstance(location, list) or not location or any(not isinstance(p, str) for p in location):
            raise ValueError(f"Invalid Flutter native asset location: {asset}")
        mode = location[0]
        if mode in ("process", "executable") and len(location) == 1:
            continue
        if mode == "system" and len(location) == 2:
            continue
        if mode != "absolute" or len(location) != 2:
            raise ValueError(f"Unsupported Flutter native asset location: {asset}")
        # Flutter 3.44.4 uses each source's basename for both desktop platforms,
        # despite calling this engine manifest path kind "absolute".
        name = location[1]
        if not name or name in (".", "..") or any(c in name for c in ("/", "\\", ":", "\0")):
            raise ValueError(f"Unsafe Flutter native asset filename: {asset}")
        names.add(name)
    return names


def verify_native_assets(platform, bundle, root=ROOT):
    """Verify every declared/generated desktop code asset reached the bundle.

    Linux CMake installs these files to lib/, Windows to the bundle root.
    Non-bundled system/process/executable lookups do not require copied files.
    Returns bundle-relative SHA-256 evidence for the component report.
    """
    family = DESKTOP_PLATFORMS.get(platform)
    if family is None:
        return {}
    root, bundle = Path(root).resolve(), Path(bundle)
    native_directory = root / "build/native_assets" / family
    if not native_directory.is_dir():
        raise ValueError(f"Flutter did not produce build/native_assets/{family}")
    manifest_path = bundle / "data/flutter_assets/NativeAssetsManifest.json"
    if not manifest_path.is_file():
        raise ValueError("Flutter native asset manifest missing from desktop bundle")
    names = _bundled_names(_read_json(manifest_path), platform)
    generated = {path.name for path in native_directory.iterdir()}
    if names != generated:
        raise ValueError(f"Flutter native assets differ from manifest: missing={sorted(names - generated)}, "
                         f"unlisted={sorted(generated - names)}")
    evidence = {}
    for name in sorted(names):
        source = native_directory / name
        relative = f"lib/{name}" if family == "linux" else name
        destination = bundle / relative
        if not source.is_file() or not source.stat().st_size:
            raise ValueError(f"Missing generated Flutter native asset: {name}")
        if not destination.is_file() or not destination.stat().st_size:
            raise ValueError(f"Missing bundled Flutter native asset: {relative}")
        with source.open("rb") as stream:
            expected = hashlib.file_digest(stream, "sha256").hexdigest()
        with destination.open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if expected != actual:
            raise ValueError(f"Bundled Flutter native asset differs from generated output: {relative}")
        evidence[relative] = actual
    return evidence
