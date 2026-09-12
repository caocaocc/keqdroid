#!/usr/bin/env python3
"""Content-addressed macOS CI checkpoints, independent of the checkout commit.

Archives are transport containers, never trusted merely because a cache key
matches. Both cache restores and historical GitHub downloads use the same
validator before exposing any component to the packager. No third-party Python
packages or GitHub CLI are required.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[2]
COMPONENTS = ("keqrnel", "mihomo", "helper", "app")
ARCHITECTURES = ("arm64", "x64")
SCHEMA_VERSION = 1
WORKFLOW = ".github/workflows/macos.yml"
TRUSTED_BRANCH = "dev"
TOOLCHAIN = {
    "xcode": "16.4", "xcodeBuild": "16F6", "flutter": "3.44.4",
    "cocoaPods": "1.16.2", "minimumMacOS": "12.0",
}
IGNORED_DIRECTORIES = {
    ".git", ".dart_tool", ".build", ".swiftpm", "build", "Pods", "ephemeral",
    "__pycache__", "node_modules", ".pub-cache", ".pub", "xcuserdata",
}
IGNORED_FILES = {".DS_Store", "GeneratedPluginRegistrant.swift", ".flutter-plugins-dependencies"}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
MAX_ARCHIVE_BYTES = 8 * 1024 * 1024 * 1024
MAX_EXPANDED_BYTES = 16 * 1024 * 1024 * 1024
MAX_MEMBERS = 200000


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def sha256_file(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def check_component(component, arch):
    if component not in COMPONENTS or arch not in ARCHITECTURES:
        raise ValueError("Unknown component or architecture")


def input_files(root, paths):
    """Hash source trees without incorporating machine-generated build products."""
    result = {}
    for relative in paths:
        start = root / relative
        if not start.exists():
            raise ValueError(f"Required component input is missing: {relative}")
        candidates = [start]
        if start.is_dir():
            candidates = []
            for directory, directories, files in os.walk(start, followlinks=False):
                directories[:] = sorted(name for name in directories if name not in IGNORED_DIRECTORIES)
                for name in sorted(files):
                    if name not in IGNORED_FILES and not name.endswith((".pyc", ".log")):
                        candidates.append(Path(directory) / name)
                # Source symlinks must not silently escape the checkout.
                for name in directories[:]:
                    item = Path(directory) / name
                    if item.is_symlink():
                        candidates.append(item)
                        directories.remove(name)
        for path in candidates:
            relative_name = path.relative_to(root).as_posix()
            if path.is_symlink():
                raise ValueError(f"Unexpected symlink in component source inputs: {relative_name}")
            if not path.is_file():
                raise ValueError(f"Unexpected component source input: {relative_name}")
            result[relative_name] = {"sha256": sha256_file(path), "executable": bool(path.stat().st_mode & 0o111)}
    return result


def component_inputs(component, arch, root=None):
    check_component(component, arch)
    root = Path(root or ROOT)
    shared = input_files(root, ["tool/macos/ci_artifacts.py"])
    if component in ("keqrnel", "mihomo"):
        # The core builder owns the source graph, patches, overlays and Go flags.
        # Its fingerprint must not change when a different core changes.
        try:
            from . import build_cores
        except ImportError:
            import build_cores
        inputs = {"core": build_cores.core_inputs(component, arch)}
    elif component == "helper":
        inputs = {"files": input_files(root, [
            "macos/NetworkService/Package.swift", "macos/NetworkService/Sources",
            "macos/NetworkService/Tests", "tool/macos/build_helper.sh",
        ]), "toolchain": {key: TOOLCHAIN[key] for key in ("xcode", "xcodeBuild", "minimumMacOS")}}
    else:
        paths = [
            "pubspec.yaml", "pubspec.lock", "lib", "packages", "third_party",
            "macos/Runner", "macos/Runner.xcodeproj", "macos/Runner.xcworkspace",
            "macos/Flutter/Flutter-Debug.xcconfig", "macos/Flutter/Flutter-Release.xcconfig",
            "macos/Podfile", "macos/Podfile.lock", "macos/DesktopSupport",
            "macos/NetworkService/Package.swift", "macos/NetworkService/Sources/CNetworkXPC",
            "macos/NetworkService/Sources/KEQNetworkClient", "tool/macos/build_app.sh",
            "tool/macos/check_flutter_framework.py",
        ]
        for name in ("l10n.yaml", "analysis_options.yaml"):
            if (root / name).exists():
                paths.append(name)
        # Only Geo DAT files inside assets/bin are Flutter assets. Foreign core
        # binaries are deliberately omitted by pubspec and by the macOS packager.
        assets = input_files(root, ["assets"])
        assets = {name: value for name, value in assets.items()
                  if not name.startswith("assets/bin/") or name == "assets/bin/windows/geosite.dat"}
        inputs = {"files": {**input_files(root, paths), **assets}, "toolchain": TOOLCHAIN}
    return {"schemaVersion": SCHEMA_VERSION, "component": component, "arch": arch,
            "checkpointImplementation": shared, "inputs": inputs}


def fingerprint(component, arch, root=None):
    return hashlib.sha256(canonical_json(component_inputs(component, arch, root))).hexdigest()


def artifact_prefix(component, arch, value):
    return f"component-{component}-{arch}-{value}"


def safe_path(name):
    if not isinstance(name, str) or not name or len(name) > 4096 or "\\" in name or "\x00" in name:
        raise ValueError("Invalid checkpoint path")
    path = PurePosixPath(name)
    if path.is_absolute() or name != path.as_posix() or any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"Unsafe checkpoint path: {name}")
    return path


def validate_links(entries):
    for name, entry in entries.items():
        parent = PurePosixPath(name).parent
        while parent != PurePosixPath("."):
            if entries.get(parent.as_posix(), {}).get("type") != "directory":
                raise ValueError(f"Checkpoint entry parent is not a directory: {name}")
            parent = parent.parent
        if entry["type"] != "symlink":
            continue
        target = entry["target"]
        if not isinstance(target, str) or not target or "\\" in target or "\x00" in target or target.startswith("/"):
            raise ValueError(f"Invalid checkpoint symlink: {name}")
        # Resolve symlink chains as the filesystem would, not just the lexical
        # target. Versions/Current and Flutter framework links remain valid.
        pending = list(PurePosixPath(name).parts)
        resolved = []
        followed = 0
        while pending:
            part = pending.pop(0)
            if part in ("", "."):
                continue
            if part == "..":
                if not resolved:
                    raise ValueError(f"Checkpoint symlink escapes its component: {name}")
                resolved.pop()
                continue
            candidate = "/".join(resolved + [part])
            link = entries.get(candidate, {})
            if link.get("type") == "symlink":
                followed += 1
                if followed > 40:
                    raise ValueError(f"Cyclic or excessive checkpoint symlink chain: {name}")
                link_target = link.get("target")
                if not isinstance(link_target, str) or not link_target or link_target.startswith("/") or "\\" in link_target or "\x00" in link_target:
                    raise ValueError(f"Invalid checkpoint symlink: {candidate}")
                pending = list(PurePosixPath(link_target).parts) + pending
            else:
                resolved.append(part)


def source_entries(source):
    source = Path(source)
    if source.is_symlink() or not source.is_dir():
        raise ValueError("Component source must be a real directory")
    entries = {}
    expanded_size = 0
    for directory, directories, files in os.walk(source, followlinks=False):
        for name in sorted(directories + files):
            path = Path(directory) / name
            relative = path.relative_to(source).as_posix()
            safe_path(relative)
            metadata = path.lstat()
            if metadata.st_mode & 0o7000:
                raise ValueError(f"Privileged file mode in checkpoint source: {relative}")
            entry = {"mode": stat.S_IMODE(metadata.st_mode)}
            if stat.S_ISLNK(metadata.st_mode):
                entry.update(type="symlink", target=os.readlink(path))
            elif stat.S_ISDIR(metadata.st_mode):
                entry.update(type="directory")
            elif stat.S_ISREG(metadata.st_mode):
                entry.update(type="file", size=metadata.st_size, sha256=sha256_file(path))
                expanded_size += metadata.st_size
            else:
                raise ValueError(f"Special file in checkpoint source: {relative}")
            entries[relative] = entry
            if len(entries) > MAX_MEMBERS or expanded_size > MAX_EXPANDED_BYTES:
                raise ValueError("Checkpoint source exceeds resource limits")
    if not entries:
        raise ValueError("Refusing to save an empty component")
    validate_links(entries)
    return dict(sorted(entries.items()))


def source_commit(root):
    value = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if not COMMIT_PATTERN.fullmatch(value):
        raise ValueError("Cannot identify component source commit")
    return value


def pack(component, arch, source, archive, root=None, commit=None):
    root = Path(root or ROOT)
    source, archive = Path(source).absolute(), Path(archive).absolute()
    if archive.resolve().is_relative_to(source.resolve()):
        raise ValueError("Checkpoint archive must be outside its source directory")
    value = fingerprint(component, arch, root)
    commit = commit or source_commit(root)
    if not COMMIT_PATTERN.fullmatch(commit):
        raise ValueError("Invalid component source commit")
    entries = source_entries(source)
    manifest = {"schemaVersion": SCHEMA_VERSION, "component": component, "arch": arch,
                "fingerprint": value, "sourceCommit": commit, "entries": entries}
    data = canonical_json(manifest)
    if len(data) > MAX_MANIFEST_BYTES:
        raise ValueError("Checkpoint manifest exceeds resource limits")
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = archive.with_name(archive.name + f".{os.getpid()}.part")
    try:
        with tarfile.open(temporary, "w", format=tarfile.PAX_FORMAT) as output:
            header = tarfile.TarInfo("manifest.json")
            header.size, header.mode = len(data), 0o644
            output.addfile(header, io.BytesIO(data))
            payload = tarfile.TarInfo("payload")
            payload.type, payload.mode = tarfile.DIRTYPE, 0o755
            output.addfile(payload)
            for name, entry in entries.items():
                member = tarfile.TarInfo("payload/" + name)
                member.mode = entry["mode"]
                if entry["type"] == "directory":
                    member.type = tarfile.DIRTYPE
                    output.addfile(member)
                elif entry["type"] == "symlink":
                    member.type, member.linkname = tarfile.SYMTYPE, entry["target"]
                    output.addfile(member)
                else:
                    member.size = entry["size"]
                    with (source / name).open("rb") as stream:
                        output.addfile(member, stream)
        # Re-read the transport archive to catch source changes during packing.
        validate_archive(temporary, component, arch, value)
        temporary.replace(archive)
        digest = sha256_file(archive)
        archive.with_name(archive.name + ".sha256").write_text(f"{digest}  {archive.name}\n")
    finally:
        temporary.unlink(missing_ok=True)
    return {"fingerprint": value, "archive": str(archive), "archive-sha256": digest,
            "source-commit": commit}


def parse_manifest(data, component, arch, expected_fingerprint):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate checkpoint manifest JSON key")
            result[key] = value
        return result

    try:
        manifest = json.loads(data, object_pairs_hook=unique_keys)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("Invalid checkpoint manifest JSON") from error
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError("Unsupported checkpoint manifest schema")
    if manifest.get("component") != component or manifest.get("arch") != arch:
        raise ValueError("Checkpoint component or architecture mismatch")
    if manifest.get("fingerprint") != expected_fingerprint or not SHA256_PATTERN.fullmatch(expected_fingerprint):
        raise ValueError("Checkpoint input fingerprint mismatch")
    if not COMMIT_PATTERN.fullmatch(str(manifest.get("sourceCommit", ""))):
        raise ValueError("Invalid checkpoint source commit")
    entries = manifest.get("entries")
    if not isinstance(entries, dict) or not entries or len(entries) > MAX_MEMBERS:
        raise ValueError("Invalid checkpoint entry table")
    expanded_size = 0
    for name, entry in entries.items():
        safe_path(name)
        if not isinstance(entry, dict) or entry.get("type") not in ("file", "directory", "symlink"):
            raise ValueError("Invalid checkpoint entry type")
        mode = entry.get("mode")
        if type(mode) is not int or not 0 <= mode <= 0o777:
            raise ValueError("Invalid checkpoint entry permissions")
        if entry["type"] == "file":
            size = entry.get("size")
            if type(size) is not int or size < 0 or not SHA256_PATTERN.fullmatch(str(entry.get("sha256", ""))):
                raise ValueError("Invalid checkpoint file size or SHA-256")
            expanded_size += size
        elif entry["type"] == "symlink" and not isinstance(entry.get("target"), str):
            raise ValueError("Invalid checkpoint symlink target")
    if expanded_size > MAX_EXPANDED_BYTES:
        raise ValueError("Checkpoint expanded size exceeds resource limits")
    validate_links(entries)
    return manifest


def validate_archive(archive, component, arch, expected_fingerprint, destination=None):
    """Validate every member; optionally unpack into an empty private directory."""
    archive = Path(archive)
    if not archive.is_file() or archive.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("Invalid checkpoint archive size")
    try:
        with tarfile.open(archive, "r:*") as source:
            first = source.next()
            if first is None or first.name != "manifest.json" or not first.isfile() or first.size > MAX_MANIFEST_BYTES:
                raise ValueError("Checkpoint must begin with its bounded manifest")
            with source.extractfile(first) as stream:
                manifest = parse_manifest(stream.read(), component, arch, expected_fingerprint)
            entries, seen = manifest["entries"], set()
            payload_seen = False
            for member in source:
                # TarFile iteration revisits the member read using next().
                if member is first:
                    continue
                if member.name == "payload":
                    if payload_seen or not member.isdir() or member.mode != 0o755:
                        raise ValueError("Invalid checkpoint payload root")
                    payload_seen = True
                    continue
                if not member.name.startswith("payload/"):
                    raise ValueError("Unexpected member outside checkpoint payload")
                name = member.name[len("payload/"):]
                safe_path(name)
                if name in seen or name not in entries:
                    raise ValueError(f"Duplicate or unlisted checkpoint member: {name}")
                seen.add(name)
                entry = entries[name]
                if member.mode != entry["mode"] or member.uid != 0 or member.gid != 0:
                    raise ValueError(f"Checkpoint permission or ownership mismatch: {name}")
                target = Path(destination) / name if destination is not None else None
                if entry["type"] == "directory":
                    if not member.isdir():
                        raise ValueError(f"Checkpoint type mismatch: {name}")
                    if target:
                        target.mkdir(parents=True, exist_ok=True)
                elif entry["type"] == "symlink":
                    if not member.issym() or member.linkname != entry["target"]:
                        raise ValueError(f"Checkpoint symlink mismatch: {name}")
                    # Create links after files: no extraction write may traverse a link.
                else:
                    if not member.isfile() or member.size != entry["size"] or member.sparse is not None:
                        raise ValueError(f"Checkpoint file type or size mismatch: {name}")
                    result = hashlib.sha256()
                    if target:
                        target.parent.mkdir(parents=True, exist_ok=True)
                    output = target.open("xb") if target else None
                    try:
                        with source.extractfile(member) as stream:
                            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                                result.update(chunk)
                                if output:
                                    output.write(chunk)
                    finally:
                        if output:
                            output.close()
                    if result.hexdigest() != entry["sha256"]:
                        raise ValueError(f"Checkpoint SHA-256 mismatch: {name}")
                    if target:
                        target.chmod(entry["mode"])
            if not payload_seen or seen != set(entries):
                raise ValueError("Checkpoint is missing declared payload members")
            if destination is not None:
                for name, entry in entries.items():
                    target = Path(destination) / name
                    if entry["type"] == "symlink":
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.symlink_to(entry["target"])
                        # macOS preserves symlink modes; Linux uses fixed 0777.
                        if hasattr(os, "lchmod"):
                            os.lchmod(target, entry["mode"])
                # Apply restrictive directory modes only after all children exist.
                for name, entry in sorted(entries.items(), key=lambda pair: pair[0].count("/"), reverse=True):
                    if entry["type"] == "directory":
                        (Path(destination) / name).chmod(entry["mode"])
            return manifest
    except (tarfile.TarError, EOFError) as error:
        raise ValueError("Invalid or truncated checkpoint tar") from error


def restore(component, arch, archive, destination, root=None):
    value = fingerprint(component, arch, root)
    destination = Path(destination).absolute()
    if destination.is_symlink():
        raise ValueError("Checkpoint destination must not be a symlink")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{destination.name}.restore-", dir=destination.parent))
    backup = None
    try:
        manifest = validate_archive(archive, component, arch, value, temporary)
        if destination.exists():
            if not destination.is_dir():
                raise ValueError("Checkpoint destination must be a directory")
            backup = Path(tempfile.mkdtemp(prefix=f".{destination.name}.old-", dir=destination.parent))
            backup.rmdir()
            destination.replace(backup)
        try:
            temporary.replace(destination)
        except BaseException:
            if backup:
                backup.replace(destination)
                backup = None
            raise
        return {"fingerprint": value, "source-commit": manifest["sourceCommit"]}
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
        if backup and backup.exists():
            shutil.rmtree(backup)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


class GitHubAPI:
    def __init__(self, repository, token=None, api_url="https://api.github.com"):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("Invalid GitHub repository")
        parsed = urllib.parse.urlsplit(api_url)
        if parsed.scheme != "https" or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError("GitHub API must use an HTTPS origin")
        self.repository, self.token = repository, token
        self.api_url = api_url.rstrip("/")
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, path):
        if not path.startswith("/") or path.startswith("//"):
            raise ValueError("GitHub API requires a relative path")
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
                   "User-Agent": "keqdroid-ci-checkpoints"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(self.api_url + path, headers=headers)
        for attempt in range(4):
            try:
                return self.opener.open(request, timeout=60)
            except urllib.error.HTTPError as error:
                retry = error.code in (429, 500, 502, 503, 504)
                if not retry or attempt == 3:
                    raise
                error.close()
                time.sleep(2 ** attempt)
            except (TimeoutError, urllib.error.URLError):
                if attempt == 3:
                    raise
                time.sleep(2 ** attempt)

    def json(self, path):
        with self.request(path) as response:
            data = response.read(32 * 1024 * 1024 + 1)
            if len(data) > 32 * 1024 * 1024:
                raise ValueError("GitHub API response exceeds resource limits")
            return json.loads(data)

    def pages(self, path, key):
        separator = "&" if "?" in path else "?"
        page = 1
        while True:
            result = self.json(f"{path}{separator}per_page=100&page={page}")
            entries = result[key]
            if not isinstance(entries, list):
                raise ValueError("Unexpected GitHub pagination response")
            yield from entries
            if len(entries) < 100:
                break
            page += 1

    def download(self, artifact, destination):
        for attempt in range(4):
            try:
                self._download_once(artifact, destination)
                return
            except urllib.error.HTTPError as error:
                if error.code not in (429, 500, 502, 503, 504) or attempt == 3:
                    raise
                error.close()
            except (TimeoutError, ConnectionError, urllib.error.URLError):
                if attempt == 3:
                    raise
            Path(destination).unlink(missing_ok=True)
            time.sleep(2 ** attempt)

    def _download_once(self, artifact, destination):
        artifact_id = artifact.get("id")
        if type(artifact_id) is not int or artifact_id <= 0:
            raise ValueError("Invalid GitHub artifact ID")
        path = f"/repos/{self.repository}/actions/artifacts/{artifact_id}/zip"
        response = None
        try:
            response = self.request(path)
        except urllib.error.HTTPError as redirect:
            try:
                if redirect.code not in (301, 302, 303, 307, 308):
                    raise
                location = redirect.headers.get("Location", "")
                parsed = urllib.parse.urlsplit(location)
                if parsed.scheme != "https" or parsed.username or parsed.password or not parsed.hostname:
                    raise ValueError("Unsafe GitHub artifact download redirect")
            finally:
                redirect.close()
            # Deliberately construct a NEW unauthenticated request. GitHub's token
            # must never follow the API redirect to Azure/S3 object storage.
            response = urllib.request.urlopen(urllib.request.Request(location, headers={
                "User-Agent": "keqdroid-ci-checkpoints"}), timeout=60)
        result, size = hashlib.sha256(), 0
        with response, Path(destination).open("wb") as stream:
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                size += len(chunk)
                if size > MAX_ARCHIVE_BYTES:
                    raise ValueError("GitHub artifact download exceeds resource limits")
                result.update(chunk)
                stream.write(chunk)
        digest = artifact.get("digest")
        if digest is not None and digest != "sha256:" + result.hexdigest():
            raise ValueError("GitHub artifact ZIP digest mismatch")


def trusted_run(run, repository, workflow=WORKFLOW, branch=TRUSTED_BRANCH):
    return (run.get("event") in ("push", "workflow_dispatch")
            and run.get("head_branch") == branch
            and run.get("path", "").split("@", 1)[0] == workflow
            and (run.get("repository") or {}).get("full_name", "").lower() == repository.lower()
            and (run.get("head_repository") or {}).get("full_name", "").lower() == repository.lower()
            and COMMIT_PATTERN.fullmatch(str(run.get("head_sha", ""))) is not None)


def artifact_tar(zip_path, destination):
    """Read one tar from the ZIP without ever extracting ZIP paths to disk."""
    try:
        with zipfile.ZipFile(zip_path) as archive:
            members = archive.infolist()
            if not 1 <= len(members) <= 4:
                raise ValueError("Unexpected number of files in GitHub component artifact")
            tars = []
            for member in members:
                safe_path(member.filename)
                if "/" in member.filename or member.is_dir() or stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError("Unsafe GitHub artifact ZIP member")
                if member.file_size > MAX_ARCHIVE_BYTES or member.flag_bits & 1:
                    raise ValueError("Invalid GitHub artifact ZIP member size or encryption")
                if member.filename.endswith(".tar"):
                    tars.append(member)
                elif not member.filename.endswith(".tar.sha256"):
                    raise ValueError("Unexpected GitHub component artifact file")
            if len(tars) != 1 or len({member.filename for member in members}) != len(members):
                raise ValueError("GitHub component artifact must contain exactly one tar")
            with archive.open(tars[0]) as source, Path(destination).open("wb") as stream:
                shutil.copyfileobj(source, stream)
    except (zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise ValueError("Invalid GitHub component ZIP") from error


def fetch(component, arch, destination, repository, token=None, root=None, client=None,
          workflow=WORKFLOW, branch=TRUSTED_BRANCH, archive_output=None):
    # Public CLI policy is fixed, preventing an accidental fork/PR/default-branch
    # lookup from making less-trusted component code available to a dev build.
    if workflow not in (WORKFLOW, "macos.yml") or branch != TRUSTED_BRANCH:
        raise ValueError("Only the repository's dev macos.yml workflow is a trusted component producer")
    retained = Path(archive_output).absolute() if archive_output is not None else None
    if retained is not None and retained.resolve().is_relative_to(Path(destination).resolve()):
        raise ValueError("Retained checkpoint archive must be outside its restored component")
    value = fingerprint(component, arch, root)
    prefix = artifact_prefix(component, arch, value)
    pattern = re.compile(re.escape(prefix) + r"-attempt[1-9][0-9]*$")
    client = client or GitHubAPI(repository, token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    workflow_path = f"/repos/{repository}/actions/workflows/macos.yml/runs?branch={TRUSTED_BRANCH}"
    rejected = 0
    for run in client.pages(workflow_path, "workflow_runs"):
        if not trusted_run(run, repository):
            continue
        run_id = run.get("id")
        if type(run_id) is not int or run_id <= 0:
            continue
        artifacts_path = f"/repos/{repository}/actions/runs/{run_id}/artifacts"
        matches = [artifact for artifact in client.pages(artifacts_path, "artifacts")
                   if not artifact.get("expired", True) and pattern.fullmatch(artifact.get("name", ""))]
        # A successfully uploaded component remains usable even if the run later
        # fails or is cancelled. Never filter on the run's overall conclusion.
        for artifact in sorted(matches, key=lambda item: item.get("id", 0), reverse=True):
            try:
                with tempfile.TemporaryDirectory(prefix="keqdis-ci-fetch-") as temporary:
                    archive, transport = Path(temporary) / "component.tar", Path(temporary) / "artifact.zip"
                    try:
                        client.download(artifact, transport)
                    except urllib.error.HTTPError as error:
                        # Artifacts may expire or be removed after the listing.
                        if error.code in (404, 410):
                            error.close()
                            continue
                        raise
                    artifact_tar(transport, archive)
                    result = restore(component, arch, archive, destination, root)
                    if retained is not None:
                        # Republish the exact verified archive. Repacking with the
                        # current HEAD would incorrectly replace its build commit.
                        retained.parent.mkdir(parents=True, exist_ok=True)
                        partial = retained.with_name(retained.name + f".{os.getpid()}.part")
                        try:
                            shutil.copyfile(archive, partial)
                            digest = sha256_file(partial)
                            if digest != sha256_file(archive):
                                raise ValueError("Retained checkpoint archive SHA-256 mismatch")
                            partial.replace(retained)
                        finally:
                            partial.unlink(missing_ok=True)
                        retained.with_name(retained.name + ".sha256").write_text(f"{digest}  {retained.name}\n")
                        result.update(archive=str(retained), **{"archive-sha256": digest})
                    return {**result, "hit": "true", "source-run-id": str(run_id), "rejected-artifacts": str(rejected)}
            except ValueError as error:
                # A corrupt newest candidate must not poison every future retry.
                # Reject it explicitly, then try an older independently verified
                # checkpoint. If none survive, only this component is rebuilt.
                rejected += 1
                reason = str(error).replace("\r", " ").replace("\n", " ")[:500]
                print(f"Rejected checkpoint artifact {artifact.get('id')}: {reason}", file=sys.stderr)
    return {"fingerprint": value, "hit": "false", "rejected-artifacts": str(rejected)}


def write_outputs(values, github_output):
    if github_output:
        with Path(github_output).open("a") as stream:
            for key, value in values.items():
                if "\n" in str(value) or "\r" in str(value):
                    raise ValueError("Invalid GitHub output value")
                stream.write(f"{key}={value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("fingerprint", "pack", "restore", "fetch"))
    parser.add_argument("--component", required=True, choices=COMPONENTS)
    parser.add_argument("--arch", required=True, choices=ARCHITECTURES)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--workflow", default=WORKFLOW)
    parser.add_argument("--branch", default=TRUSTED_BRANCH)
    args = parser.parse_args()
    try:
        if args.operation == "fingerprint":
            value = fingerprint(args.component, args.arch)
            result = {"fingerprint": value, "artifact-prefix": artifact_prefix(args.component, args.arch, value)}
        elif args.operation == "pack":
            if not args.source or not args.archive:
                parser.error("pack requires --source and --archive")
            result = pack(args.component, args.arch, args.source, args.archive)
        elif args.operation == "restore":
            if not args.archive or not args.destination:
                parser.error("restore requires --archive and --destination")
            result = restore(args.component, args.arch, args.archive, args.destination)
        else:
            if not args.destination or not args.repository:
                parser.error("fetch requires --destination and --repository (or GITHUB_REPOSITORY)")
            result = fetch(args.component, args.arch, args.destination, args.repository,
                           token=os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"),
                           workflow=args.workflow, branch=args.branch, archive_output=args.archive)
        write_outputs(result, args.github_output)
        print(result["fingerprint"] if args.operation == "fingerprint" else json.dumps(result, sort_keys=True))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyError) as error:
        print(f"CI checkpoint error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
