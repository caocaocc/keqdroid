"""Synthetic supervisor tests. Never touch Wi-Fi, launch an app or read prefs."""
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'macos'))
import recovery_supervisor as supervisor


class FakeClock:
    value = 0.0
    def now(self):
        return self.value
    def sleep(self, seconds):
        self.value += seconds


class FakeGUI:
    pid = 4242
    alive = True
    def poll(self):
        return None if self.alive else 0


class FakeSystem:
    def __init__(self, powered=True, running=False):
        self.powered, self.running = powered, running
        self.changes = []
        self.launched = self.quit = False
        self.gui = FakeGUI()
    def wifi_devices(self):
        return ['en0']
    def power(self, _device):
        return self.powered
    def set_power(self, _device, enabled):
        self.changes.append(enabled)
        self.powered = enabled
    def gui_processes(self):
        return [4241] if self.running else []
    def launch_gui(self):
        self.launched = True
        return self.gui
    def quit_gui(self, process):
        assert process is self.gui
        self.quit = True
        process.alive = False
        return 'graceful'


def fake_capture(directory):
    directory.mkdir(mode=0o700)
    supervisor.private_json(directory / 'configuration.json', {
        'schemaVersion': 1, 'normalizationVersion': 1, 'complete': True,
        'configuration': {}, 'unavailable': [],
    })
    return True


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.system, self.clock = FakeSystem(), FakeClock()
        self.plan = {'device': 'en0', 'offlineSeconds': 2, 'armSeconds': 2, 'observeSeconds': 0}

    def run_supervisor(self, go=True, **overrides):
        if go:
            (self.directory / 'GO').touch(mode=0o600)
        return supervisor.supervise(self.plan, self.directory,
            system=self.system, clock=self.clock.now, sleep=self.clock.sleep,
            capture=fake_capture, **overrides)

    def test_default_cli_is_read_only_and_does_not_create_output(self):
        with mock.patch.object(supervisor.sys, 'platform', 'darwin'), mock.patch.object(supervisor.os, 'geteuid', return_value=501), \
             mock.patch.object(supervisor, 'System', return_value=self.system), mock.patch.object(supervisor.subprocess, 'Popen') as spawn, \
             mock.patch.object(sys, 'stdout', new_callable=io.StringIO) as output:
            self.assertEqual(supervisor.main(['--output-dir', str(self.directory / 'must-not-exist')]), 0)
        spawn.assert_not_called()
        self.assertEqual(self.system.changes, [])
        self.assertFalse(self.system.launched)
        self.assertFalse((self.directory / 'must-not-exist').exists())
        self.assertTrue(json.loads(output.getvalue())['dryRun'])

    def test_normal_cycle_restores_only_own_power_and_quits_owned_gui(self):
        result = self.run_supervisor()
        self.assertEqual(self.system.changes, [False, True])
        self.assertTrue(self.system.powered)
        self.assertTrue(self.system.quit)
        self.assertTrue(result['success'])
        self.assertTrue(result['networkEquivalent'])
        self.assertEqual(result['wifiRestoration'], 'restored')
        for path in self.directory.rglob('*'):
            if path.is_file():
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_no_go_deadline_never_changes_power_but_closes_launched_gui(self):
        result = self.run_supervisor(go=False)
        self.assertEqual(result['errorCode'], 'arm-deadline-expired')
        self.assertEqual(self.system.changes, [])
        self.assertTrue(self.system.quit)

    def test_cancel_while_off_restores_even_when_caller_is_gone(self):
        result = self.run_supervisor(cancelled=lambda: self.clock.value >= 1)
        self.assertEqual(result['errorCode'], 'cancelled')
        self.assertEqual(self.system.changes, [False, True])
        self.assertTrue(self.system.quit)

    def test_cancel_before_go_never_turns_on_an_unowned_setting(self):
        (self.directory / 'CANCEL').touch(mode=0o600)
        self.run_supervisor()
        self.assertEqual(self.system.changes, [])
        self.assertTrue(self.system.quit)

    def test_initial_wifi_off_or_existing_gui_refuses_execution(self):
        for powered, running in [(False, False), (True, True)]:
            with self.subTest(powered=powered, running=running):
                self.system = FakeSystem(powered=powered, running=running)
                result = supervisor.supervise(self.plan, self.directory, system=self.system,
                    clock=self.clock.now, sleep=self.clock.sleep, capture=lambda _: True)
                self.assertFalse(result['success'])
                self.assertFalse(self.system.launched)
                self.assertEqual(self.system.changes, [])

    def test_timed_out_off_command_is_reconciled_and_restored(self):
        original = self.system.set_power
        def set_power(device, enabled):
            original(device, enabled)
            if not enabled:
                raise subprocess.TimeoutExpired(['omitted'], 10)
        self.system.set_power = set_power
        result = self.run_supervisor()
        self.assertEqual(result['errorCode'], 'TimeoutExpired')
        self.assertEqual(self.system.changes, [False, True])
        self.assertTrue(self.system.quit)

    def test_failed_first_restore_retries_without_touching_other_settings(self):
        original = self.system.set_power
        failures = 0
        def set_power(device, enabled):
            nonlocal failures
            if enabled and failures == 0:
                failures += 1
                raise OSError('synthetic private address must not be logged')
            original(device, enabled)
        self.system.set_power = set_power
        result = self.run_supervisor()
        self.assertTrue(self.system.powered)
        self.assertEqual(self.system.changes, [False, True])
        self.assertNotIn('private address', (self.directory / 'report.json').read_text())
        self.assertEqual(result['wifiRestoration'], 'restored')

    def test_observed_external_restore_releases_ownership(self):
        events = []
        lease = supervisor.WifiLease(self.system, 'en0', events.append)
        lease.disable()
        self.system.powered = True
        lease.observe()
        self.system.powered = False  # A later user's off must remain off.
        self.assertEqual(lease.restore(), 'not-owned')
        self.assertEqual(self.system.changes, [False])
        self.assertFalse(self.system.powered)

    def test_unknown_off_outcome_does_not_toggle_an_already_restored_setting(self):
        lease = supervisor.WifiLease(self.system, 'en0', lambda _: None)
        lease.disable()
        self.system.powered = True
        self.assertEqual(lease.restore(), 'already-on')
        self.assertEqual(self.system.changes, [False])

    def test_missing_journal_blocks_power_mutation(self):
        lease = supervisor.WifiLease(self.system, 'en0', lambda _: False)
        with self.assertRaises(supervisor.SupervisorError):
            lease.disable()
        lease.restore()
        self.assertEqual(self.system.changes, [])

    def test_disk_failure_after_off_does_not_prevent_restoration(self):
        original_write = supervisor.private_json
        def write(path, value):
            if not self.system.powered:
                raise OSError('disk unavailable')
            original_write(path, value)
        with mock.patch.object(supervisor, 'private_json', side_effect=write):
            result = self.run_supervisor()
        self.assertTrue(self.system.powered)
        self.assertTrue(self.system.quit)
        self.assertTrue(result['logWriteFailed'])

    def test_gui_exit_during_outage_also_restores_wifi(self):
        original_sleep = self.clock.sleep
        def sleep(seconds):
            original_sleep(seconds)
            if not self.system.powered:
                self.system.gui.alive = False
        self.clock.sleep = sleep
        result = self.run_supervisor()
        self.assertEqual(result['errorCode'], 'owned-gui-exited')
        self.assertTrue(self.system.powered)

    def test_control_plan_cannot_inject_commands_or_unbounded_delay(self):
        for changes in [{'device': 'en0;false'}, {'offlineSeconds': 31}, {'armSeconds': 0},
                        {'observeSeconds': -1}, {'offlineSeconds': True}, {'command': '/bin/sh'}]:
            with self.subTest(changes=changes), self.assertRaises(supervisor.SupervisorError):
                supervisor.validate_plan(dict(self.plan, **changes))

    def test_system_uses_only_fixed_wifi_power_arguments(self):
        real = supervisor.System()
        with mock.patch.object(real, 'command') as command:
            real.set_power('en0', False)
            real.set_power('en0', True)
            self.assertEqual(command.call_args_list, [
                mock.call([supervisor.NETWORKSETUP, '-setairportpower', 'en0', 'off']),
                mock.call([supervisor.NETWORKSETUP, '-setairportpower', 'en0', 'on'])])
            for bad in ['-setdnsservers', 'en0\n', 'en0;false']:
                with self.assertRaises(supervisor.SupervisorError):
                    real.set_power(bad, False)

    def test_quit_only_targets_owned_process_and_never_opens_bundle(self):
        real = supervisor.System()
        process = mock.Mock(pid=4242)
        process.poll.return_value = None
        with mock.patch.object(real, 'command') as command:
            self.assertEqual(real.quit_gui(process), 'graceful')
        self.assertIn('runningApplicationWithProcessIdentifier(4242)', command.call_args.args[0][-1])
        process.terminate.assert_not_called()
        process.kill.assert_not_called()

    def test_detached_worker_is_started_before_any_mutation(self):
        output = self.directory / 'new-run'
        with mock.patch.object(supervisor.sys, 'platform', 'darwin'), mock.patch.object(supervisor.os, 'geteuid', return_value=501), \
             mock.patch.object(supervisor, 'System', return_value=self.system), mock.patch.object(supervisor.subprocess, 'Popen') as spawn, \
             mock.patch.object(sys, 'stdout', new_callable=io.StringIO):
            spawn.return_value.pid = 3131
            self.assertEqual(supervisor.main(['--execute', '--output-dir', str(output)]), 0)
        self.assertEqual(self.system.changes, [])
        self.assertFalse(self.system.launched)
        self.assertTrue(spawn.call_args.kwargs['start_new_session'])
        self.assertTrue(spawn.call_args.kwargs['close_fds'])
        self.assertEqual(spawn.call_args.kwargs['stdin'], subprocess.DEVNULL)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((output / 'supervisor.jsonl').stat().st_mode), 0o600)


if __name__ == '__main__':
    unittest.main()
