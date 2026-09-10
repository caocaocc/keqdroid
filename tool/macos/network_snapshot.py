#!/usr/bin/env python3
"""Read-only before/after network evidence for local macOS acceptance testing.

Usage:
  python3 tool/macos/network_snapshot.py capture --output-dir build/private-network/before
  python3 tool/macos/network_snapshot.py capture --output-dir build/private-network/after
  python3 tool/macos/network_snapshot.py compare --before build/private-network/before \
    --after build/private-network/after --output-dir build/private-network/comparison

Each output directory is private (0700), and each JSON file is 0600. Use distinct
directories: existing records are never overwritten. stdout contains only counts
and a result summary, not service names, addresses, PAC URLs or search domains.

raw.json retains complete stdout/stderr and exit status for every fixed read-only
system command. configuration.json is a separate comparable view: DNS reachability
and statistics are omitted, resolver/interface display numbers are normalized,
and ARP/neighbor/cloned or redirected host routes are excluded. Route use/refcount
and expiry counters are omitted. Default routes, static host exceptions, network
routes, DNS ordering/scopes and complete per-service proxy/DNS settings remain.
comparison.json contains private before/after values for changed sections.

Equal comparable settings are evidence of configuration restoration, not proof of
traffic connectivity or DNS behavior. An incomplete snapshot cannot compare equal.
Exit codes: 0 = capture complete / equivalent, 1 = changed, 2 = error / incomplete.
This tool never changes networking, installs software or reads test subscriptions.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys


SCHEMA_VERSION = 1
NORMALIZATION_VERSION = 1
SYSTEM_QUERIES = {
    "systemProxy": ("/usr/sbin/scutil", "--proxy"),
    "dns": ("/usr/sbin/scutil", "--dns"),
    "routes": ("/usr/sbin/netstat", "-rn"),
    "serviceList": ("/usr/sbin/networksetup", "-listallnetworkservices"),
}
SERVICE_QUERIES = {
    "httpProxy": "-getwebproxy", "httpsProxy": "-getsecurewebproxy",
    "socksProxy": "-getsocksfirewallproxy", "pac": "-getautoproxyurl",
    "autoDiscovery": "-getproxyautodiscovery", "bypassDomains": "-getproxybypassdomains",
    "dnsServers": "-getdnsservers", "searchDomains": "-getsearchdomains",
}
DNS_KEYS = {"domain", "nameserver", "search domain", "options", "flags", "order",
            "timeout", "if_index", "service_identifier", "port"}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def query(arguments):
    arguments = tuple(arguments)
    is_system = arguments in SYSTEM_QUERIES.values()
    is_service = (len(arguments) == 3 and arguments[0] == "/usr/sbin/networksetup"
                  and arguments[1] in SERVICE_QUERIES.values()
                  and arguments[2] and not arguments[2].startswith("-")
                  and not any(character in arguments[2] for character in "\r\n\x00"))
    if not is_system and not is_service:
        raise ValueError("Unsupported network read operation")
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=20,
                                env=dict(os.environ, LC_ALL="C"))
        return {"arguments": list(arguments), "returnCode": result.returncode,
                "stdout": result.stdout, "stderr": result.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        def text(value):
            return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
        return {"arguments": list(arguments), "returnCode": None,
                "stdout": text(getattr(error, "stdout", "")),
                "stderr": text(getattr(error, "stderr", "")), "errorType": type(error).__name__}


def services_from(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines or not lines[0].startswith("An asterisk ("):
        raise ValueError("Unrecognized network service listing")
    result = []
    for line in lines[1:]:
        disabled = line.startswith("*")
        name = line[1:] if disabled else line
        if not name or name.startswith("-") or "\x00" in name:
            raise ValueError("Unsupported network service name")
        result.append({"name": name, "disabled": disabled})
    if len({item["name"] for item in result}) != len(result):
        raise ValueError("Ambiguous network service names")
    return result


def normalized_lines(text):
    return [line.strip() for line in text.splitlines() if line.strip()]


def dns_configuration(text):
    if text.strip() == "No DNS configuration available":
        return []
    resolvers = []
    current = None
    section = "default"
    saw_header = False
    for line in normalized_lines(text):
        if line.startswith("DNS configuration"):
            section = line
            saw_header = True
            current = None
        elif re.fullmatch(r"resolver #\d+", line):
            current = {"scope": section, "settings": {}}
            resolvers.append(current)
        elif current is not None and " : " in line:
            key, value = line.split(" : ", 1)
            key = re.sub(r"\[\d+\]$", "", key.strip())
            if key not in DNS_KEYS:
                continue
            if key == "if_index":
                # Numeric interface indices can change across sleep/recreation.
                interface = re.search(r"\(([^)]+)\)", value)
                value = interface.group(1) if interface else value
            current["settings"].setdefault(key, []).append(value.strip())
    if not saw_header:
        raise ValueError("Unrecognized DNS configuration output")
    return resolvers


def routes_configuration(text):
    routes = []
    family = None
    columns = None
    saw_table = False
    for line in normalized_lines(text):
        if line == "Routing tables":
            saw_table = True
            continue
        if line in ("Internet:", "Internet6:"):
            family, columns = line[:-1], None
            continue
        fields = line.split()
        if fields and fields[0] == "Destination":
            columns = fields
            if "Netif" not in columns or fields[:3] != ["Destination", "Gateway", "Flags"]:
                raise ValueError("Unrecognized route table columns")
            continue
        if family is None or columns is None:
            continue
        interface_index = columns.index("Netif")
        if len(fields) <= interface_index:
            raise ValueError("Incomplete route table entry")
        destination, gateway, flags = fields[:3]
        interface = fields[interface_index]
        # Keep default routes regardless of flags. Static host bypass routes are
        # material; dynamic neighbor/cloned/redirected host entries are not.
        cached = any(flag in flags for flag in "LW") or ("D" in flags and "H" in flags)
        if destination != "default" and cached:
            continue
        if re.fullmatch(r"link#\d+", gateway):
            gateway = "link@" + interface
        routes.append({"family": family, "destination": destination, "gateway": gateway,
                       "flags": "".join(sorted(flags)), "interface": interface})
    if not saw_table:
        raise ValueError("Unrecognized route table output")
    return sorted(routes, key=lambda value: json.dumps(value, sort_keys=True))


def comparable(raw):
    errors = list(raw.get("collectionErrors", []))
    values = {"services": {}}
    for name, operation in raw["system"].items():
        if operation["returnCode"] != 0:
            errors.append(name)
    for service in raw["services"]:
        settings = {"disabled": service["disabled"]}
        for name, operation in service["queries"].items():
            if operation["returnCode"] != 0:
                errors.append(f"services/{service['name']}/{name}")
            else:
                settings[name] = normalized_lines(operation["stdout"])
        values["services"][service["name"]] = settings
    for name, normalize in (("systemProxy", normalized_lines), ("dns", dns_configuration), ("routes", routes_configuration)):
        if raw["system"][name]["returnCode"] == 0:
            try:
                values[name] = normalize(raw["system"][name]["stdout"])
            except ValueError:
                errors.append(name + "/parse")
    return {"schemaVersion": SCHEMA_VERSION, "normalizationVersion": NORMALIZATION_VERSION,
            "capturedAt": raw["startedAt"], "complete": not errors, "unavailable": errors,
            "configuration": values}


def private_directory(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("Output directory must not be a symlink")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise ValueError("Output must be a directory")
    path.chmod(0o700)
    return path


def private_json(path, value):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def capture(output):
    output = private_directory(output)
    if any((output / name).exists() for name in ("raw.json", "configuration.json")):
        raise ValueError("Snapshot output already exists; select a new directory")
    raw = {"schemaVersion": SCHEMA_VERSION, "startedAt": now(), "system": {}, "services": [], "collectionErrors": []}
    with ThreadPoolExecutor(max_workers=4) as executor:
        pending = {name: executor.submit(query, arguments) for name, arguments in SYSTEM_QUERIES.items()}
        for name, future in pending.items():
            raw["system"][name] = future.result()
        if raw["system"]["serviceList"]["returnCode"] == 0:
            try:
                services = services_from(raw["system"]["serviceList"]["stdout"])
            except ValueError:
                services = []
                raw["collectionErrors"].append("serviceList/parse")
            pending = []
            for service in services:
                queries = {name: executor.submit(query, ("/usr/sbin/networksetup", argument, service["name"]))
                           for name, argument in SERVICE_QUERIES.items()}
                pending.append((service, queries))
            for service, queries in pending:
                raw["services"].append({**service, "queries": {name: future.result() for name, future in queries.items()}})
    raw["completedAt"] = now()
    configuration = comparable(raw)
    private_json(output / "raw.json", raw)
    private_json(output / "configuration.json", configuration)
    print(f"Captured {len(raw['services'])} network services; {len(configuration['unavailable'])} unavailable reads. Private records saved.")
    return 0 if configuration["complete"] else 2


def compare(before, after, output):
    snapshots = []
    for directory in (before, after):
        with (Path(directory) / "configuration.json").open() as stream:
            snapshot = json.load(stream)
        if snapshot.get("schemaVersion") != SCHEMA_VERSION or snapshot.get("normalizationVersion") != NORMALIZATION_VERSION:
            raise ValueError("Snapshot schema or normalization version is incompatible")
        snapshots.append(snapshot)
    output = private_directory(output)
    first, last = (snapshot["configuration"] for snapshot in snapshots)
    changed = {name: {"before": first.get(name), "after": last.get(name)}
               for name in sorted(set(first) | set(last)) if first.get(name) != last.get(name)}
    complete = all(snapshot.get("complete") is True for snapshot in snapshots)
    result = {"schemaVersion": SCHEMA_VERSION, "normalizationVersion": NORMALIZATION_VERSION,
              "comparedAt": now(), "complete": complete, "equivalent": complete and not changed,
              "changedSections": changed, "beforeUnavailable": snapshots[0].get("unavailable", []),
              "afterUnavailable": snapshots[1].get("unavailable", [])}
    private_json(output / "comparison.json", result)
    status = "equivalent" if result["equivalent"] else "changed" if complete else "incomplete"
    print(f"Comparable network configuration: {status}; {len(changed)} changed sections. Details saved privately.")
    return 0 if result["equivalent"] else 1 if complete else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("operation", choices=("capture", "compare"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--before", type=Path)
    parser.add_argument("--after", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "capture":
            if sys.platform != "darwin":
                parser.error("Capture requires macOS")
            return capture(args.output_dir)
        if not args.before or not args.after:
            parser.error("Compare requires --before and --after snapshot directories")
        return compare(args.before, args.after, args.output_dir)
    except (OSError, ValueError, KeyError):
        # Paths and malformed private network values may appear in exceptions.
        # Do not print those values into terminal/chat/CI logs.
        print("Network snapshot operation failed; inspect the selected private directory and input paths.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
