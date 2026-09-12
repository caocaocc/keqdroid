"""Validate live Dart exports with the precompiled, current Swift request CLI.

CI sets KEQDIS_MACOS_FIXTURE_DIR and KEQDIS_MACOS_CONTRACT_CHECKER after
restoring both artifacts from this workflow run. KEQDIS_MACOS_CONTRACT_REQUIRED=1
makes missing inputs a failure. No Swift/Flutter compilation, core execution,
service connection, or network operation occurs in this test.

For a local run, export the macos_*contract_test.dart suites to a
fresh directory, then pass that directory and a freshly compiled
keqdis-network-tests binary through the same environment variables.
"""

import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REQUEST_NAMES = tuple(
    f"{core}-{mode}" for core in ("xray", "mihomo", "awg")
    for mode in ("proxy", "tun")
) + tuple(f"xray-tun-dns-{name}" for name in (
    "default", "doh-direct", "doh-proxy", "bare-ip",
))
REQUEST_NAMES += ("xray-tun-china-default", "mihomo-tun-china-default")


class MacOSSessionContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = os.environ.get("KEQDIS_MACOS_FIXTURE_DIR")
        checker = os.environ.get("KEQDIS_MACOS_CONTRACT_CHECKER")
        required = os.environ.get("KEQDIS_MACOS_CONTRACT_REQUIRED") == "1"
        if not directory and not checker and not required:
            raise unittest.SkipTest("Dart exports and macOS Swift CLI are supplied by the packaging contract gate")
        if not directory or not checker:
            raise AssertionError("The cross-language gate requires both fresh Dart exports and a Swift checker")
        cls.directory = Path(directory).resolve()
        cls.checker = Path(checker).resolve()
        if not cls.checker.is_file() or not os.access(cls.checker, os.X_OK):
            raise AssertionError("The precompiled Swift request checker is missing or not executable")
        for name in REQUEST_NAMES:
            if not (cls.directory / f"{name}.json").is_file():
                raise AssertionError(f"Missing generated Dart session request: {name}")

    def validate(self, request):
        return subprocess.run(
            [str(self.checker), "--validate-request", str(request)],
            text=True, capture_output=True, timeout=15, check=False,
        )

    def test_generated_final_sessions_pass_real_swift_policy(self):
        for name in REQUEST_NAMES:
            with self.subTest(request=name):
                result = self.validate(self.directory / f"{name}.json")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {"valid": True})

    def test_generated_doh_session_does_not_allow_file_options(self):
        # Mutate the real final request, keeping its DNS HTTP path. The policy
        # must distinguish that URL path from unrelated filesystem options.
        original = json.loads((self.directory / "xray-tun-dns-doh-direct.json").read_text())
        for option in ("output", "certificate_path"):
            with self.subTest(option=option), tempfile.TemporaryDirectory() as temporary:
                request = copy.deepcopy(original)
                config = json.loads(request["configurations"]["keqrnel"])
                if option == "output":
                    config["log"][option] = "/private/var/root/contract-must-not-be-created"
                else:
                    config["dns"]["servers"][0][option] = "/private/var/root/contract-must-not-be-read"
                request["configurations"]["keqrnel"] = json.dumps(config)
                path = Path(temporary) / "request.json"
                path.write_text(json.dumps(request))
                result = self.validate(path)
                self.assertNotEqual(result.returncode, 0, "Unsafe generated request was accepted")
                self.assertIn(option, result.stderr)


if __name__ == "__main__":
    unittest.main()
