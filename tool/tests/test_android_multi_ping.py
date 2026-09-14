"""Run actual Android batch ping code on the JVM, without an Android device.

Only Android logging/process and JNI launch boundaries are stubbed. Socket
readiness, SOCKS HTTP failure and cleanup execute the production Kotlin code.
Requires a local kotlinc + Java (or Android Studio's bundled tools); no downloads.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).parent / "fixtures" / "android_multi_ping"
STUDIO = Path("/Applications/Android Studio.app/Contents")


class AndroidMultiPingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = os.environ.get("KOTLINC") or shutil.which("kotlinc")
        if not compiler:
            bundled = STUDIO / "plugins/Kotlin/kotlinc/bin/kotlinc"
            if bundled.is_file():
                compiler = str(bundled)
        if not compiler:
            raise unittest.SkipTest("Kotlin compiler unavailable; install kotlinc or set KOTLINC")
        cls.env = os.environ.copy()
        bundled_java = STUDIO / "jbr/Contents/Home"
        if not cls.env.get("JAVA_HOME") and bundled_java.is_dir():
            cls.env["JAVA_HOME"] = str(bundled_java)
        java_home = cls.env.get("JAVA_HOME")
        cls.java = str(Path(java_home) / "bin/java") if java_home else shutil.which("java")
        if not cls.java:
            raise unittest.SkipTest("Java unavailable")
        cls.scratch = tempfile.TemporaryDirectory(prefix="keqdroid-multi-ping-")
        cls.addClassCleanup(cls.scratch.cleanup)
        cls.jar = Path(cls.scratch.name) / "batch-tests.jar"
        source = ROOT / "android/app/src/main/kotlin/com/keqdroid/keqdroid/EphemeralXrayPing.kt"
        # Android Studio bundles this Unix script without an executable bit.
        compiler_command = [compiler] if os.access(compiler, os.X_OK) else ["bash", compiler]
        command = [*compiler_command, str(source), *map(str, sorted(FIXTURES.glob("*.kt"))),
                   "-include-runtime", "-d", str(cls.jar)]
        result = subprocess.run(command, env=cls.env, capture_output=True, text=True,
                                encoding="utf-8", timeout=120)
        if result.returncode:
            raise AssertionError(f"production Kotlin compile failed:\n{result.stdout}\n{result.stderr}")

    def run_case(self, scenario):
        with tempfile.TemporaryDirectory(prefix="case-", dir=self.scratch.name) as directory:
            result = subprocess.run([self.java, "-jar", str(self.jar), scenario, directory],
                                    env=self.env, capture_output=True, text=True,
                                    encoding="utf-8", timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(f"PASS {scenario}", result.stdout)

    def test_empty_input_never_starts(self):
        self.run_case("empty")

    def test_missing_binary_requests_batch_split(self):
        self.run_case("missing-binary")

    def test_negative_pid_requests_batch_split_and_deletes_config(self):
        self.run_case("negative-pid")

    def test_zero_pid_requests_batch_split_and_deletes_config(self):
        self.run_case("zero-pid")

    def test_immediate_core_exit_requests_split_without_progress(self):
        self.run_case("exited-pid")

    def test_native_start_exception_requests_batch_split_and_deletes_config(self):
        self.run_case("start-exception")

    def test_config_failure_requests_batch_split_without_launch(self):
        self.run_case("config-exception")

    def test_port_timeout_requests_batch_split_and_stops_core(self):
        self.run_case("port-not-ready")

    def test_ready_core_individual_http_failures_preserve_probe_results(self):
        self.run_case("per-probe-failures")

    def test_probe_progress_arrives_before_the_whole_batch_finishes(self):
        self.run_case("streamed-probe-failures")


if __name__ == "__main__":
    unittest.main()
