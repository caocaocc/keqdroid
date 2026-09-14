"""Inspect the APK's merged identity and native payload with Android's aapt."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

APPLICATION_ID = "io.github.caocaocc.keqdroid"
NAMESPACE = "com.keqdroid.keqdroid"
MAIN_ACTIVITY = NAMESPACE + ".MainActivity"
PROVIDER = NAMESPACE + ".VpnStatusProvider"
AUTHORITY = APPLICATION_ID + ".vpnstatus"


def xml_nodes(text):
    """Read aapt xmltree nodes without confusing attributes of adjacent nodes."""
    nodes, stack = [], []
    for line in text.splitlines():
        element = re.match(r"^(\s*)E: ([^\s]+)", line)
        if element:
            depth = len(element[1])
            while stack and stack[-1][0] >= depth:
                stack.pop()
            node = {"tag": element[2], "attributes": {}, "parent": stack[-1][1] if stack else None}
            nodes.append(node)
            stack.append((depth, node))
            continue
        attribute = re.match(r"^\s*A: ([^=(]+)(?:\([^)]*\))?=(.*)$", line)
        if attribute and stack:
            raw = attribute[2]
            if raw.startswith('"'):
                value = json.JSONDecoder().raw_decode(raw)[0]
            elif raw.startswith("@0x"):
                value = raw.split()[0].lower()
            else:
                typed = re.match(r"\(type 0x[0-9a-f]+\)(0x[0-9a-f]+)", raw)
                value = int(typed[1], 16) if typed else raw
            stack[-1][1]["attributes"][attribute[1]] = value
    return nodes


def resource_strings(text):
    result, current = {}, None
    for line in text.splitlines():
        resource = re.match(r"^\s*resource (0x[0-9a-f]+) \S+:", line)
        if resource:
            current = "@" + resource[1]
        elif "resource " in line or "config " in line:
            current = None
        string = re.match(r'^\s*\(string(?:8|16)?\) (".*")$', line)
        if string and current:
            result.setdefault(current, set()).add(json.loads(string[1]))
    return result


def resolved(value, resources):
    if isinstance(value, str) and value.startswith("@0x"):
        values = resources.get(value, set())
        if len(values) != 1:
            raise ValueError("Missing or inconsistent Android string resource")
        return next(iter(values))
    return value


def inspect_identity(badging, manifest, resources_text, shortcuts, version, build_number):
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.M)
    if not package or tuple(package.groups()) != (APPLICATION_ID, str(build_number), version):
        raise ValueError("APK application ID or version mismatch")
    resources = resource_strings(resources_text)
    nodes = xml_nodes(manifest)
    providers = [n for n in nodes if n["tag"] == "provider" and n["attributes"].get("android:name") == PROVIDER]
    if len(providers) != 1 or providers[0]["attributes"].get("android:authorities") != AUTHORITY:
        raise ValueError("APK VPN status Provider identity mismatch")
    if providers[0]["attributes"].get("android:exported") != 0:
        raise ValueError("APK VPN status Provider must remain private")
    activities = [n for n in nodes if n["tag"] == "activity" and n["attributes"].get("android:name") == MAIN_ACTIVITY]
    if len(activities) != 1:
        raise ValueError("APK MainActivity namespace mismatch")
    metadata = [n for n in nodes if n["tag"] == "meta-data" and n["parent"] is activities[0]
                and n["attributes"].get("android:name") == "android.app.shortcuts"]
    if len(metadata) != 1:
        raise ValueError("APK launcher shortcut metadata is missing")
    shortcut_path = resolved(metadata[0]["attributes"].get("android:resource"), resources)
    if shortcut_path not in shortcuts:
        raise ValueError("APK launcher shortcut resource mismatch")
    shortcut_nodes = xml_nodes(shortcuts[shortcut_path])
    entries = [n for n in shortcut_nodes if n["tag"] == "shortcut"]
    if {n["attributes"].get("android:shortcutId") for n in entries} != {"connect", "disconnect"} or len(entries) != 2:
        raise ValueError("APK connection shortcuts are missing or duplicated")
    for entry in entries:
        intents = [n for n in shortcut_nodes if n["tag"] == "intent" and n["parent"] is entry]
        if len(intents) != 1:
            raise ValueError("APK shortcut has an unexpected intent chain")
        attributes = intents[0]["attributes"]
        if (resolved(attributes.get("android:targetPackage"), resources) != APPLICATION_ID
                or resolved(attributes.get("android:targetClass"), resources) != MAIN_ACTIVITY
                or attributes.get("android:action") != "android.intent.action.MAIN"):
            raise ValueError("APK shortcut points to a different application or activity")
    return {"applicationId": APPLICATION_ID, "version": version, "versionCode": str(build_number),
            "providerAuthority": AUTHORITY, "mainActivity": MAIN_ACTIVITY,
            "shortcutResource": shortcut_path, "shortcutIds": ["connect", "disconnect"]}


def verify_signing_output(output, expected):
    """Require the configured certificate for every verified APK signer.

    apksigner labels v3.1 SDK-targeted signers with their SDK range instead of
    ``Signer #1``; Build Tools 37 prints ``V2 Signer:`` for v2 signatures.
    A source stamp's certificate never authenticates the APK.
    """
    expected = expected.lower()
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Invalid expected Android signing certificate digest")
    signer_prefix = r"(?:Signer (?:#[1-9][0-9]*|\(minSdkVersion=[0-9]+(?: \(dev release=true\))?, maxSdkVersion=[0-9]+\))|V2 Signer:)"
    records = []
    for line in output.splitlines():
        if "certificate SHA-256 digest:" not in line or line.startswith("Source Stamp Signer"):
            continue
        match = re.fullmatch(signer_prefix + r" certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*", line)
        if not match:
            raise ValueError("apksigner returned an unrecognized or malformed APK signer certificate record")
        records.append(match[1])
    digests = {value.lower() for value in records}
    if not records:
        raise ValueError("apksigner returned no recognized APK signing certificate digest")
    if digests != {expected}:
        raise ValueError(f"APK signing certificate mismatch: expected {expected}; found {', '.join(sorted(digests))}")
    return {"signingCertificateSHA256": expected, "signerCertificateRecords": len(records)}

def file_hash(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inspect_native(apk, source_root):
    result = {}
    required = {"lib/arm64-v8a/libxray.so", "lib/arm64-v8a/libmihomo.so"}
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names) or not required.issubset(names):
            raise ValueError("APK has duplicate entries or missing native proxy cores")
        for name in names:
            if not name.startswith("lib/") or name.endswith("/"):
                continue
            if not name.startswith("lib/arm64-v8a/") or not name.endswith(".so"):
                raise ValueError("APK contains an unexpected native architecture or library")
            with archive.open(name) as stream:
                header = stream.read(64)
                if len(header) != 64 or header[:6] != b"\x7fELF\x02\x01" or int.from_bytes(header[18:20], "little") != 183:
                    raise ValueError("APK native payload is not AArch64 ELF: " + name)
                digest = hashlib.sha256(header)
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            result[name] = {"architecture": "arm64", "packagedSHA256": digest.hexdigest()}
            if name in required:
                source = Path(source_root) / "android/app/src/main/jniLibs" / name.removeprefix("lib/")
                # AGP may strip symbols. Record both identities without treating
                # that valid transformation as evidence of a wrong core.
                result[name]["sourceSHA256"] = file_hash(source)
    return result


def verify(apk, aapt, version, build_number, source_root):
    def dump(kind, asset=None):
        return subprocess.check_output([str(aapt), "dump", "--values", kind, str(apk)]
                                       + ([asset] if asset else []), text=True, timeout=60)
    badging, manifest, resources = dump("badging"), dump("xmltree", "AndroidManifest.xml"), dump("resources")
    resource_values = resource_strings(resources)
    candidates = {resolved(node["attributes"].get("android:resource"), resource_values)
                  for node in xml_nodes(manifest) if node["tag"] == "meta-data"
                  and node["attributes"].get("android:name") == "android.app.shortcuts"}
    with zipfile.ZipFile(apk) as archive:
        for name in candidates:
            if not isinstance(name, str) or not name.startswith("res/") or name not in archive.namelist():
                raise ValueError("APK shortcut XML resource is missing")
    # Use the manifest resource, not a guessed filename: resource shrinking can
    # rename res/xml/shortcuts.xml in a release APK.
    shortcuts = {name: dump("xmltree", name) for name in sorted(candidates)}
    result = inspect_identity(badging, manifest, resources, shortcuts, version, build_number)
    result["nativeLibraries"] = inspect_native(apk, source_root)
    return result
