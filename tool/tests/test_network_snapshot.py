"""Small synthetic checks; no test reads or changes the host's network."""

import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "macos"))
import network_snapshot as snapshot


DNS = """DNS configuration
resolver #1
  nameserver[0] : 192.0.2.53
  if_index : 14 (en0)
  flags : Request A records
  reach : 0x00000002 (Reachable)
  order : 200000
DNS configuration (for scoped queries)
resolver #1
  nameserver[0] : 192.0.2.53
  if_index : 14 (en0)
  flags : Scoped, Request A records
"""
ROUTES = """Routing tables
Internet:
Destination Gateway Flags Refs Use Netif Expire
default 192.0.2.1 UGScg 7 30 en0
192.0.2/24 link#14 UCS 1 0 en0
192.0.2.100 00:11:22:33:44:55 UHLWI 2 500 en0 123
198.51.100.10 192.0.2.1 UGHS 1 5 en0
Internet6:
Destination Gateway Flags Netif Expire
default fe80::1%en0 UGcIg en0
"""


class SnapshotTests(unittest.TestCase):
    def test_dns_ignores_runtime_counters_and_display_indices_but_keeps_server_and_scope(self):
        baseline = snapshot.dns_configuration(DNS)
        changed_counters = DNS.replace("resolver #1", "resolver #5").replace("14 (en0)", "20 (en0)").replace(
            "0x00000002 (Reachable)", "0x00000000 (Not Reachable)") + "  queries : 500\n"
        self.assertEqual(baseline, snapshot.dns_configuration(changed_counters))
        self.assertNotEqual(baseline, snapshot.dns_configuration(DNS.replace("192.0.2.53", "198.51.100.53")))
        self.assertNotEqual(baseline, snapshot.dns_configuration(DNS.replace("Scoped, ", "")))

    def test_route_cache_and_counters_are_ignored_but_static_bypass_and_default_are_retained(self):
        baseline = snapshot.routes_configuration(ROUTES)
        changed_cache = ROUTES.replace("link#14", "link#22").replace("7 30", "9 600").replace(
            "192.0.2.100 00:11:22:33:44:55 UHLWI 2 500 en0 123", "192.0.2.200 11:22:33:44:55:66 UHLWI 8 1000 en0 1")
        self.assertEqual(baseline, snapshot.routes_configuration(changed_cache))
        self.assertNotEqual(baseline, snapshot.routes_configuration(ROUTES.replace("default 192.0.2.1", "default 192.0.2.2")))
        self.assertNotEqual(baseline, snapshot.routes_configuration(ROUTES.replace("198.51.100.10", "198.51.100.11")))

    def test_disabled_service_names_are_preserved_and_unsafe_cli_arguments_rejected(self):
        result = snapshot.services_from("An asterisk (*) denotes that a network service is disabled.\nOffice LAN\n*USB LAN\n")
        self.assertEqual(result, [{"name": "Office LAN", "disabled": False}, {"name": "USB LAN", "disabled": True}])
        with mock.patch.object(snapshot.subprocess, "run") as command:
            for arguments in (("/usr/sbin/networksetup", "-setdnsservers", "Office LAN"),
                              ("/usr/sbin/networksetup", "-getdnsservers", "-setairportpower"),
                              ("/bin/sh", "-c", "echo unexpected")):
                with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                    snapshot.query(arguments)
            command.assert_not_called()

    def fake_query(self, arguments):
        text = "Enabled: Yes\nServer: private-proxy.example.test\nPort: 8080\n"
        if tuple(arguments) == snapshot.SYSTEM_QUERIES["serviceList"]:
            text = "An asterisk (*) denotes that a network service is disabled.\nOffice LAN\n"
        elif tuple(arguments) == snapshot.SYSTEM_QUERIES["dns"]:
            text = DNS
        elif tuple(arguments) == snapshot.SYSTEM_QUERIES["routes"]:
            text = ROUTES
        return {"arguments": list(arguments), "returnCode": 0, "stdout": text, "stderr": ""}

    def test_capture_keeps_complete_raw_and_separate_private_comparison_without_console_details(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "before"
            with mock.patch.object(snapshot, "query", side_effect=self.fake_query), mock.patch.object(sys, "stdout", new_callable=io.StringIO) as console:
                self.assertEqual(snapshot.capture(output), 0)
            self.assertNotIn("Office LAN", console.getvalue())
            self.assertNotIn("private-proxy", console.getvalue())
            self.assertNotIn("192.0.2", console.getvalue())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
            for name in ("raw.json", "configuration.json"):
                self.assertEqual(stat.S_IMODE((output / name).stat().st_mode), 0o600)
            raw = json.loads((output / "raw.json").read_text())
            comparable = json.loads((output / "configuration.json").read_text())
            self.assertIn("reach :", raw["system"]["dns"]["stdout"])
            self.assertNotIn("reach", comparable["configuration"]["dns"][0]["settings"])
            self.assertEqual(len(raw["services"][0]["queries"]), len(snapshot.SERVICE_QUERIES))
            with self.assertRaises(ValueError):
                snapshot.capture(output)

    def test_partial_snapshot_cannot_report_equivalence_and_metadata_times_are_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            value = {"schemaVersion": 1, "normalizationVersion": 1, "complete": True,
                     "configuration": {"services": {}, "dns": []}, "unavailable": []}
            for name in ("before", "after"):
                directory = snapshot.private_directory(root / name)
                snapshot.private_json(directory / "configuration.json", dict(value, capturedAt=name))
            with mock.patch.object(sys, "stdout", new_callable=io.StringIO):
                self.assertEqual(snapshot.compare(root / "before", root / "after", root / "equal"), 0)
            data = json.loads((root / "after/configuration.json").read_text())
            data["complete"] = False
            data["unavailable"] = ["dns"]
            (root / "after/configuration.json").write_text(json.dumps(data))
            with mock.patch.object(sys, "stdout", new_callable=io.StringIO):
                self.assertEqual(snapshot.compare(root / "before", root / "after", root / "incomplete"), 2)
            report = json.loads((root / "incomplete/comparison.json").read_text())
            self.assertFalse(report["equivalent"])
            self.assertEqual(stat.S_IMODE((root / "incomplete/comparison.json").stat().st_mode), 0o600)

    def test_failed_reads_and_unrecognized_dns_or_routes_mark_snapshot_incomplete(self):
        raw = {"startedAt": "fixture", "system": {name: self.fake_query(arguments) for name, arguments in snapshot.SYSTEM_QUERIES.items()}, "services": []}
        raw["system"]["systemProxy"]["returnCode"] = 1
        raw["system"]["dns"]["stdout"] = "unknown DNS format"
        raw["system"]["routes"]["stdout"] = "unknown route format"
        result = snapshot.comparable(raw)
        self.assertFalse(result["complete"])
        self.assertEqual(result["unavailable"], ["systemProxy", "dns/parse", "routes/parse"])


if __name__ == "__main__":
    unittest.main()
