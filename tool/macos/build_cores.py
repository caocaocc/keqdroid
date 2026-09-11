#!/usr/bin/env python3
"""Build pinned Darwin cores without installing tools or changing system networking."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import struct
import subprocess
import tarfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path("/tmp/keqdroid-tools")
OUTPUT = ROOT / "build/macos-cores"
PATCHES = ROOT / "tool/patches"
MANIFEST = ROOT / "tool/macos/core-manifest.json"
CORES = ("keqrnel", "mihomo", "wireproxy")
DEPENDENCIES = {"keqrnel": ("keqrnel", "xray", "singbox", "singtun"),
                "mihomo": ("mihomo",), "wireproxy": ("wireproxy",)}
OVERLAYS = {
    "keqrnel": (("bootstrapdns", "internal/keqdisdns"),),
    "mihomo": (("bootstrapdns", "internal/keqdisdns"),
               ("privilegedapi", "internal/keqdisapi"), ("mihomo", "dns"),
               ("mihomo_api", "hub/route")),
    "wireproxy": (("bootstrapdns", "internal/keqdisdns"),),
    "xray": (("xray", "features/dns/localdns"),),
    "singbox": (("privilegedapi", "internal/keqdisapi"),
                ("singbox_api", "experimental/clashapi")),
    "singtun": (("singtun", "."),),
}


def json_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def core_inputs(core, arch):
    """Return exact component inputs, excluding unrelated core and app changes."""
    if core not in CORES or arch not in ("arm64", "x64"):
        raise ValueError(f"Unsupported core/architecture: {core}/{arch}")
    manifest = json.loads(MANIFEST.read_text())
    sources = {name: manifest["sources"][name] for name in DEPENDENCIES[core]}
    files = {PATCHES / patch for spec in sources.values() for patch in spec["patches"]}
    for name in sources:
        for overlay, _ in OVERLAYS[name]:
            files.update(path for path in (PATCHES / "macos" / overlay).iterdir()
                         if path.is_file() and (path.suffix == ".go" or path.name in ("go.mod", "go.sum")))
    return {"schemaVersion": 1, "core": core, "architecture": arch,
            "go": manifest["go"], "minimumMacOS": manifest["minimumMacOS"],
            "sources": sources,
            "patches": {str(path.relative_to(PATCHES)): digest(path) for path in sorted(files)},
            "builderSHA256": digest(Path(__file__)),
            "wrapperSHA256": digest(ROOT / "tool/build_macos_cores.sh"),
            "flags": {"GOOS": "darwin", "CGO_ENABLED": "0", "GOTOOLCHAIN": "local",
                      "GOARCH": "amd64" if arch == "x64" else "arm64",
                      "GOAMD64": "v1", "GOARM64": "v8.0", "GOEXPERIMENT": "",
                      "GOENV": "off", "GOWORK": "off", "GOFLAGS": "-mod=readonly",
                      "arguments": ["build", "-trimpath", "-buildvcs=false"]}}


def atomic_json(path, value):
    temporary = path.with_name(path.name + ".building")
    with temporary.open("w") as stream:
        stream.write(json.dumps(value, indent=2, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def validate_component(directory, core, arch):
    binary = directory / core
    record_path = directory / f"{core}-provenance.json"
    if binary.is_symlink() or record_path.is_symlink() or not binary.is_file():
        raise ValueError(f"Invalid component files for {core}/{arch}")
    record = json.loads(record_path.read_text())
    expected = core_inputs(core, arch)
    if (not isinstance(record, dict) or record.get("schemaVersion") != 1 or record.get("core") != core
            or record.get("architecture") != arch or record.get("inputs") != expected
            or record.get("inputsSHA256") != json_digest(expected)):
        raise ValueError(f"Stale or mismatched inputs for {core}/{arch}")
    if not binary.stat().st_mode & 0o111:
        raise ValueError(f"Component {core}/{arch} is not executable")
    if record.get("binary") != macho_info(binary, arch):
        raise ValueError(f"Core binary hash or Mach-O metadata mismatch for {core}/{arch}")
    return record


def validate_core_set(directory, arch):
    """Validate independently restored components and assemble packager provenance."""
    directory = Path(directory)
    records = {core: validate_component(directory, core, arch) for core in CORES}
    manifest = json.loads(MANIFEST.read_text())
    patches = {str(item.relative_to(PATCHES)): digest(item) for item in PATCHES.rglob("*")
               if item.is_file() and ("macos" in item.parts or item.name.startswith("mihomo-"))}
    return {"schemaVersion": 1, "go": manifest["go"]["version"], "architecture": arch,
            "sourceManifestSHA256": digest(MANIFEST), "sources": manifest["sources"],
            "patches": patches, "binaries": {core: item["binary"] for core, item in records.items()},
            "componentInputs": {core: item["inputsSHA256"] for core, item in records.items()}}


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def download(spec, name):
    target = TOOLS / "downloads" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and digest(target) == spec["sha256"]:
        return target
    partial = target.with_suffix(target.suffix + ".part")
    for attempt in range(4):
        try:
            print(f"Downloading {name}", flush=True)
            with urllib.request.urlopen(spec["url"], timeout=120) as response, partial.open("wb") as stream:
                shutil.copyfileobj(response, stream)
            if digest(partial) != spec["sha256"]:
                raise ValueError(f"SHA-256 mismatch for {name}; refusing unverified source")
            partial.replace(target)
            return target
        except (OSError, ValueError):
            partial.unlink(missing_ok=True)
            if attempt == 3:
                raise
            time.sleep(2)


def relative_member(name, prefix):
    name = name.rstrip("/")
    if name == prefix:
        return None
    if not name.startswith(prefix + "/"):
        raise ValueError(f"Archive member outside pinned source prefix: {name}")
    relative = PurePosixPath(name[len(prefix) + 1:])
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"Unsafe archive member: {name}")
    return relative


def extract(archive, prefix, destination):
    destination.mkdir(parents=True, exist_ok=True)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                # Go module archives may have directory entries above the module prefix.
                if member.is_dir() and prefix.startswith(member.filename.rstrip("/") + "/"):
                    continue
                relative = relative_member(member.filename, prefix)
                if relative is None:
                    continue
                target = destination / relative
                mode = member.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise ValueError(f"Unexpected archive symlink: {member.filename}")
                if member.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.open(member) as input_stream, target.open("wb") as output_stream:
                        shutil.copyfileobj(input_stream, output_stream)
                    target.chmod(0o755 if mode & 0o111 else 0o644)
    else:
        with tarfile.open(archive) as source:
            for member in source:
                relative = relative_member(member.name, prefix)
                if relative is None:
                    continue
                target = destination / relative
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as input_stream, target.open("wb") as output_stream:
                        shutil.copyfileobj(input_stream, output_stream)
                    target.chmod(0o755 if member.mode & 0o111 else 0o644)
                else:
                    raise ValueError(f"Unexpected archive special file: {member.name}")


def run(command, cwd, env, label):
    log = OUTPUT / "logs" / f"{label}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    print(label, flush=True)
    with log.open("w") as stream:
        result = subprocess.run([str(value) for value in command], cwd=cwd, env=env,
                                stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text(errors="replace")[-10000:], flush=True)
        raise RuntimeError(f"{label} failed ({result.returncode}); see {log}")
    return log


def toolchain(manifest):
    host = "arm64" if platform.machine() == "arm64" else "x64"
    spec = manifest["go"]["hosts"][host]
    version = manifest["go"]["version"]
    destination = TOOLS / "toolchains" / f"go{version}-{host}"
    go = destination / "bin/go"
    archive = download(spec, f"go{version}.darwin-{'amd64' if host == 'x64' else host}.zip")
    stamp = destination / ".archive-sha256"
    if not go.exists() or not stamp.exists() or stamp.read_text() != spec["sha256"]:
        if destination.exists():
            shutil.rmtree(destination)
        extract(archive, spec["prefix"], destination)
        stamp.write_text(spec["sha256"])
    env = dict(os.environ, GOROOT=str(destination), GOTOOLCHAIN="local", CGO_ENABLED="0",
               GOPATH=str(TOOLS / "gopath"), GOMODCACHE=str(TOOLS / "go-modcache"),
               GOCACHE=str(TOOLS / "go-cache"), GOPROXY="https://proxy.golang.org",
               GOSUMDB="sum.golang.org", MACOSX_DEPLOYMENT_TARGET="12.0", GOFLAGS="-mod=readonly",
               GOENV="off", GOWORK="off", GOEXPERIMENT="", GOAMD64="v1", GOARM64="v8.0")
    # Build subprocesses must never inherit an active TUN's bootstrap snapshot.
    env.pop("KEQDIS_BOOTSTRAP_DNS", None)
    env.pop("KEQDIS_BOOTSTRAP_INTERFACE", None)
    env.pop("KEQDIS_PRIVILEGED_RUNTIME", None)
    env.pop("GOOS", None)
    env.pop("GOARCH", None)
    env["PATH"] = str(destination / "bin") + os.pathsep + env.get("PATH", "")
    actual = subprocess.check_output([go, "version"], env=env, text=True).strip()
    if actual != f"go version go{version} darwin/{'amd64' if host == 'x64' else host}":
        raise RuntimeError(f"Unexpected Go toolchain: {actual}")
    return go, env


def prepare_sources(manifest, go, env, cores=CORES):
    sources = {}
    required = set(name for core in cores for name in DEPENDENCIES[core])
    for name, spec in manifest["sources"].items():
        if name not in required:
            continue
        archive = download(spec, f"{name}.{spec['format']}")
        source = OUTPUT / "sources" / name
        if source.exists():
            shutil.rmtree(source)
        extract(archive, spec["prefix"], source)
        # These are downloaded sources inside the app's ignored build directory.
        # Do not let git discover the app repository and silently skip patch paths
        # outside its current prefix.
        patch_env = dict(env, GIT_CEILING_DIRECTORIES=str(source.parent))
        patch_env.pop("GIT_DIR", None)
        patch_env.pop("GIT_WORK_TREE", None)
        for patch in spec["patches"]:
            run(["git", "apply", "--whitespace=nowarn", PATCHES / patch], source, patch_env,
                "patch-" + name + "-" + Path(patch).stem)
        for overlay, destination in OVERLAYS[name]:
            target = source / destination
            target.mkdir(parents=True, exist_ok=True)
            for item in (PATCHES / "macos" / overlay).glob("*.go"):
                shutil.copy2(item, target / item.name)
        sources[name] = source
    if "wireproxy" in sources:
        (sources["wireproxy"] / "cmd/wireproxy/bootstrap_init_darwin.go").write_text(
            '//go:build darwin\n\npackage main\n\nimport _ "github.com/artem-russkikh/wireproxy-awg/internal/keqdisdns"\n')
    # A relative replacement keeps the user's checkout path out of Go build info.
    if "keqrnel" in sources:
        run([go, "mod", "edit", "-replace", "github.com/xtls/xray-core=../xray"],
            sources["keqrnel"], env, "replace-xray")
        run([go, "mod", "edit", "-replace", "github.com/sagernet/sing-box=../singbox"],
            sources["keqrnel"], env, "replace-singbox")
        for name in ("keqrnel", "singbox"):
            run([go, "mod", "edit", "-replace", "github.com/sagernet/sing-tun=../singtun"],
                sources[name], env, "replace-singtun-" + name)
    return sources


def macho_info(path, arch):
    with path.open("rb") as stream:
        header = stream.read(32)
        if len(header) != 32:
            raise ValueError(f"Truncated Mach-O header in {path}")
        magic, cpu, _, _, count, _, _, _ = struct.unpack("<8I", header)
        expected = 0x0100000C if arch == "arm64" else 0x01000007
        if magic != 0xFEEDFACF or cpu != expected:
            raise ValueError(f"{path} is not a thin {arch} Mach-O")
        minimum = None
        for _ in range(count):
            header = stream.read(8)
            if len(header) != 8:
                raise ValueError(f"Truncated Mach-O load command in {path}")
            command, size = struct.unpack("<II", header)
            if size < 8 or size > path.stat().st_size:
                raise ValueError(f"Invalid Mach-O load command in {path}")
            data = stream.read(size - 8)
            if len(data) != size - 8 or (command == 0x32 and len(data) < 16) or (command == 0x24 and len(data) < 8):
                raise ValueError(f"Truncated Mach-O load command in {path}")
            if command == 0x32:
                target, minimum = struct.unpack_from("<II", data)
                if target != 1:
                    raise ValueError(f"{path} does not target macOS")
            elif command == 0x24:
                minimum = struct.unpack_from("<I", data)[0]
        if minimum is None or minimum > 12 << 16:
            raise ValueError(f"{path} requires newer than macOS 12, or has no deployment version")
    return {"sha256": digest(path), "size": path.stat().st_size, "architecture": arch,
            "minimumMacOS": f"{minimum >> 16}.{minimum >> 8 & 255}.{minimum & 255}"}


def test_sources(cores, go, env, sources):
    run([go, "test", "./..."], PATCHES / "macos/bootstrapdns", env, "test-bootstrapdns")
    if set(cores) & {"keqrnel", "mihomo"}:
        run([go, "test", "./..."], PATCHES / "macos/privilegedapi", env, "test-privileged-api-policy")
    if "keqrnel" in cores:
        run([go, "test", "-tags", "with_gvisor", ".", "-run", "^TestKeqdisRoute"], sources["singtun"], env,
            "test-singtun-route-ownership")
        run([go, "test", "./features/dns/localdns", "./transport/internet", "-run", "^TestKeqdis"], sources["xray"], env,
            "test-xray-bootstrap")
        run([go, "test", "-tags", "with_gvisor", "./core/localdns", "./internal/keqdisdns"],
            sources["keqrnel"], env, "test-keqrnel-localdns")
        run([go, "test", "-tags", "with_gvisor", "./experimental/clashapi", "-run", "^TestKeqdis"],
            sources["singbox"], env, "test-singbox-privileged-api")
    if "mihomo" in cores:
        run([go, "test", "-tags", "with_gvisor,no_tailscale,no_zerotier", "./dns", "-run", "^TestKeqdis"],
            sources["mihomo"], env, "test-mihomo-bootstrap")
        run([go, "test", "-tags", "with_gvisor,no_tailscale,no_zerotier", "./hub/route", "-run", "^TestKeqdis"],
            sources["mihomo"], env, "test-mihomo-privileged-api")


def build_component(core, arch, directory, source, go, env):
    inputs = core_inputs(core, arch)
    spec = inputs["sources"][core]
    directory.mkdir(parents=True, exist_ok=True)
    temporary = directory / (core + ".building")
    temporary.unlink(missing_ok=True)
    command = [go, *inputs["flags"]["arguments"]]
    if spec["tags"]:
        command += ["-tags", ",".join(spec["tags"])]
    if spec.get("ldflags"):
        command += ["-ldflags", spec["ldflags"]]
    command += ["-o", temporary, spec["target"]]
    target_env = dict(env, GOOS="darwin", GOARCH=inputs["flags"]["GOARCH"])
    run(command, source, target_env, f"build-{core}-{arch}")
    record = {"schemaVersion": 1, "core": core, "architecture": arch, "inputs": inputs,
              "inputsSHA256": json_digest(inputs), "binary": macho_info(temporary, arch)}
    temporary.replace(directory / core)
    atomic_json(directory / f"{core}-provenance.json", record)
    print(f"Verified {core}/{arch}: {directory / core}", flush=True)


def main():
    global OUTPUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["all", "arm64", "x64"], default="all")
    parser.add_argument("--core", choices=["all", *CORES], default="all")
    parser.add_argument("--output-dir", type=Path,
                        help="Direct component directory; requires a single --arch")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare-only", action="store_true")
    mode.add_argument("--assemble-only", action="store_true",
                      help="Validate all three checkpoints and write provenance.json without building")
    args = parser.parse_args()
    if args.output_dir and args.arch == "all":
        parser.error("--output-dir requires --arch arm64 or --arch x64")
    if args.assemble_only and args.core != "all":
        parser.error("--assemble-only requires --core all")
    if args.output_dir:
        OUTPUT = args.output_dir.resolve()
    arches = ["arm64", "x64"] if args.arch == "all" else [args.arch]
    cores = CORES if args.core == "all" else (args.core,)
    directories = {arch: OUTPUT if args.output_dir else OUTPUT / arch for arch in arches}
    if args.assemble_only:
        for arch, directory in directories.items():
            atomic_json(directory / "provenance.json", validate_core_set(directory, arch))
            print(f"Assembled verified {arch} cores: {directory}", flush=True)
        return

    pending = []
    for arch, directory in directories.items():
        for core in cores:
            try:
                validate_component(directory, core, arch)
                print(f"Reusing verified {core}/{arch}", flush=True)
            except (OSError, ValueError):
                pending.append((core, arch))
    if pending or args.prepare_only:
        if platform.system() != "Darwin":
            raise SystemExit("Build on macOS so the Darwin patch tests execute on their target OS")
        manifest = json.loads(MANIFEST.read_text())
        go, env = toolchain(manifest)
        required = cores if args.prepare_only else tuple(dict.fromkeys(core for core, _ in pending))
        # Preparing and testing one dependency group at a time preserves the
        # preceding checkpoint even if the next core fails before compilation.
        for core in required:
            sources = prepare_sources(manifest, go, env, (core,))
            if args.prepare_only:
                continue
            test_sources((core,), go, env, sources)
            for name, arch in pending:
                if name == core:
                    build_component(core, arch, directories[arch], sources[core], go, env)
    if args.prepare_only:
        return
    if args.core == "all":
        for arch, directory in directories.items():
            atomic_json(directory / "provenance.json", validate_core_set(directory, arch))
            print(f"Verified {arch} cores: {directory}", flush=True)


if __name__ == "__main__":
    main()
