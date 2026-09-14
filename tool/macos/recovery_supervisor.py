#!/usr/bin/env python3
"""Independent, opt-in Wi-Fi interruption supervisor for local acceptance.

Default: inspect Wi-Fi power and KEQDIS processes; do not write files or change
networking. After installing/verifying the test package, exit KEQDIS and arm:

  python3 tool/macos/recovery_supervisor.py --execute \
    --output-dir build/ci-downloads/recovery-acceptance --offline-seconds 8

The detached process launches its own KEQDIS GUI, captures a private baseline,
and creates ARMED. Connect KEQDIS and prepare observations, then create GO in the
output directory. It switches Wi-Fi off once, restores power after the bounded
interval, leaves time to observe automatic reconnection, and quits its own GUI.
Create CANCEL to finish early; this NEVER disables restoration. No GO within
--arm-seconds also finishes without switching Wi-Fi off.

Only a Wi-Fi power change made by this process is restored. DNS, proxies,
routes, other VPNs and preferences are never restored or edited by this tool.
Restoration compares the current power to the applied value. An observed user
power-on releases ownership; the tool will not undo a later user power-off.
The OS exposes no change-owner token, so an unobserved on/off cycle cannot be
distinguished. Process/OS termination with SIGKILL or shutdown cannot be made
failure-proof; detached execution survives the calling terminal/Codex timeout,
and HUP/INT/TERM, ordinary errors and command timeouts all enter cleanup.

All records are 0600 under a new 0700 directory. Command output and exception
messages are not logged. network_snapshot keeps its existing private evidence
format; reports contain no subscriptions, node credentials, SSIDs or addresses.
Never run as root. Real machine sleep is intentionally outside this tool.
"""

import argparse
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

import network_snapshot


APP = Path('/Applications/KEQDIS.app/Contents/MacOS/KEQDIS')
NETWORKSETUP = '/usr/sbin/networksetup'
DEVICE = re.compile(r'en[0-9]{1,3}\Z')


class SupervisorError(Exception):
    """The code is safe to log; never store raw command output in exceptions."""


def private_json(path, value):
    temporary = path.with_name(path.name + '.new')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                         getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def safe_error(error):
    return str(error) if isinstance(error, SupervisorError) else type(error).__name__


class System:
    @staticmethod
    def command(arguments, timeout=10):
        result = subprocess.run(arguments, capture_output=True, text=True,
                                timeout=timeout, env=dict(os.environ, LC_ALL='C'))
        if result.returncode:
            raise SupervisorError('system-command-failed')
        return result.stdout

    def wifi_devices(self):
        output = self.command([NETWORKSETUP, '-listallhardwareports'])
        devices = []
        for section in output.split('\n\n'):
            port = re.search(r'^Hardware Port: (Wi-Fi|AirPort)$', section, re.M)
            device = re.search(r'^Device: (en[0-9]{1,3})$', section, re.M)
            if port and device:
                devices.append(device.group(1))
        return devices

    def power(self, device):
        if not DEVICE.fullmatch(device):
            raise SupervisorError('invalid-wifi-device')
        output = self.command([NETWORKSETUP, '-getairportpower', device])
        match = re.fullmatch(r'(?:Wi-Fi|AirPort) Power \(' + re.escape(device) + r'\): (On|Off)\s*', output)
        if not match:
            raise SupervisorError('unknown-wifi-power-state')
        return match.group(1) == 'On'

    def set_power(self, device, enabled):
        if not DEVICE.fullmatch(device) or not isinstance(enabled, bool):
            raise SupervisorError('invalid-power-operation')
        self.command([NETWORKSETUP, '-setairportpower', device, 'on' if enabled else 'off'])

    def gui_processes(self):
        rows = self.command(['/bin/ps', '-axo', 'pid=,uid=,comm=']).splitlines()
        found = []
        for row in rows:
            match = re.fullmatch(r'\s*(\d+)\s+(\d+)\s+(.+)', row)
            if match and int(match.group(2)) == os.getuid() and match.group(3).endswith('/KEQDIS.app/Contents/MacOS/KEQDIS'):
                found.append(int(match.group(1)))
        return found

    def launch_gui(self):
        if not APP.is_file() or APP.is_symlink() or self.gui_processes():
            raise SupervisorError('gui-must-be-installed-and-not-running')
        environment = {key: value for key, value in os.environ.items()
                       if key in {'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG'}}
        environment['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
        # Keep app/core logs out of the sanitized supervisor log. No login flag:
        # a tester explicitly chooses and connects the node after ARMED.
        return subprocess.Popen([str(APP)], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                env=environment, close_fds=True, start_new_session=True)

    def quit_gui(self, process):
        if process.poll() is not None:
            return 'already-exited'
        # Address the exact process, without launching a replacement application.
        # NSRunningApplication.terminate goes through AppDelegate's asynchronous
        # Flutter quit handler, which cancels reconnect intent and disconnects.
        try:
            self.command(['/usr/bin/osascript', '-l', 'JavaScript', '-e',
                'ObjC.import("AppKit"); '
                f'$.NSRunningApplication.runningApplicationWithProcessIdentifier({process.pid}).terminate;'], timeout=5)
            process.wait(timeout=12)
            return 'graceful'
        except (OSError, subprocess.TimeoutExpired, SupervisorError):
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
                return 'terminated-owned-gui'
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
                return 'killed-owned-gui'


class WifiLease:
    def __init__(self, system, device, record):
        self.system, self.device, self.record = system, device, record
        self.attempted = False
        self.owned = False

    def disable(self):
        if self.system.power(self.device) is not True:
            raise SupervisorError('wifi-changed-before-interruption')
        # Write intent before invoking the OS: a command timeout may happen
        # after the requested mutation, so cleanup must reconcile current state.
        self.attempted = self.owned = True
        if self.record('wifi-off-requested') is False:
            self.attempted = self.owned = False
            raise SupervisorError('cannot-journal-power-change')
        self.system.set_power(self.device, False)
        if self.system.power(self.device) is not False:
            self.owned = False
            raise SupervisorError('wifi-off-not-confirmed')
        self.record('wifi-off-confirmed')

    def observe(self):
        if self.owned and self.system.power(self.device) is True:
            self.owned = False
            self.record('wifi-restored-externally')

    def restore(self):
        if not self.attempted or not self.owned:
            return 'not-owned'
        if self.system.power(self.device) is True:
            self.owned = False
            self.record('wifi-already-on')
            return 'already-on'
        self.record('wifi-on-requested')
        self.system.set_power(self.device, True)
        if self.system.power(self.device) is not True:
            raise SupervisorError('wifi-restore-not-confirmed')
        self.owned = False
        self.record('wifi-restored')
        return 'restored'


def validate_plan(plan):
    if set(plan) != {'device', 'offlineSeconds', 'armSeconds', 'observeSeconds'}:
        raise SupervisorError('invalid-plan')
    if not isinstance(plan['device'], str) or not DEVICE.fullmatch(plan['device']):
        raise SupervisorError('invalid-wifi-device')
    for key, minimum, maximum in [('offlineSeconds', 1, 30), ('armSeconds', 1, 600), ('observeSeconds', 0, 180)]:
        if type(plan[key]) is not int or not minimum <= plan[key] <= maximum:
            raise SupervisorError('invalid-time-bound')


def inspect(system, device=None):
    devices = system.wifi_devices()
    if device is None:
        if len(devices) != 1:
            raise SupervisorError('select-one-wifi-device')
        device = devices[0]
    if device not in devices:
        raise SupervisorError('device-is-not-wifi')
    power = system.power(device)
    running = bool(system.gui_processes())
    return {'dryRun': True, 'device': device, 'wifiPowerOn': power,
            'keqdisRunning': running, 'canArm': power and not running}


def evidence(directory):
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            return network_snapshot.capture(directory) == 0
    except Exception:
        return False


def supervise(plan, directory, system=None, clock=time.monotonic, sleep=time.sleep, cancelled=lambda: False, capture=evidence):
    validate_plan(plan)
    system = system or System()
    started = clock()
    report = {'schemaVersion': 1, 'events': [], 'wifiRestoration': 'not-changed',
              'guiExit': 'not-started', 'success': False}

    def record(event):
        report['events'].append({'event': event, 'elapsedSeconds': round(clock() - started, 3)})
        try:
            private_json(directory / 'report.json', report)
            return True
        except OSError:
            # Disk/full/permission failures cannot prevent power restoration or
            # GUI cleanup. Refuse the initial mutation if its intent was not saved.
            report['logWriteFailed'] = True
            return False

    def cancellation():
        return cancelled() or (directory / 'CANCEL').exists()

    def wait(seconds, until_go=False):
        deadline = clock() + seconds
        next_power_check = clock()
        while clock() < deadline:
            if cancellation():
                raise SupervisorError('cancelled')
            if gui is not None and gui.poll() is not None:
                raise SupervisorError('owned-gui-exited')
            if until_go and (directory / 'GO').exists():
                return True
            if lease.owned and clock() >= next_power_check:
                lease.observe()
                next_power_check = clock() + 1
            sleep(min(0.2, max(0, deadline - clock())))
        return not until_go

    lease = WifiLease(system, plan['device'], record)
    gui = None
    try:
        current = inspect(system, plan['device'])
        if not current['canArm']:
            raise SupervisorError('wifi-must-be-on-and-gui-must-be-closed')
        report['baselineComplete'] = capture(directory / 'before')
        if not report['baselineComplete']:
            raise SupervisorError('incomplete-network-baseline')
        gui = system.launch_gui()
        wait(0.5)
        private_json(directory / 'ARMED', {'supervisorPid': os.getpid(), 'guiPid': gui.pid})
        record('armed')
        if not wait(plan['armSeconds'], until_go=True):
            raise SupervisorError('arm-deadline-expired')
        record('go-received')
        lease.disable()
        wait(plan['offlineSeconds'])
        report['wifiRestoration'] = lease.restore()
        wait(plan['observeSeconds'])
        report['success'] = True
    except BaseException as error:
        report['errorCode'] = safe_error(error)
        record('finishing')
    finally:
        # Cleanup is independent of CANCEL, signals, the original caller and
        # elapsed test deadlines. Retry only this one owned power setting.
        for attempt in range(3):
            try:
                restored = lease.restore()
                if restored != 'not-owned':
                    report['wifiRestoration'] = restored
                break
            except BaseException as error:
                report['restoreErrorCode'] = safe_error(error)
                report['success'] = False
                if attempt < 2:
                    sleep(1)
                else:
                    report['wifiRestoration'] = 'failed'
        if gui is not None:
            try:
                report['guiExit'] = system.quit_gui(gui)
            except BaseException as error:
                report['guiExit'] = 'failed'
                report['quitErrorCode'] = safe_error(error)
                report['success'] = False
        report['afterComplete'] = capture(directory / 'after')
        if report.get('baselineComplete') and report['afterComplete']:
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    report['networkEquivalent'] = network_snapshot.compare(directory / 'before', directory / 'after', directory / 'comparison') == 0
            except Exception:
                report['networkEquivalent'] = False
        if report.get('networkEquivalent') is not True:
            # A changed/incomplete snapshot needs review, never a broad rollback.
            report['success'] = False
        record('finished')
    return report


def worker(plan, directory):
    stopped = False
    def interrupt(_signum, _frame):
        nonlocal stopped
        stopped = True
    for name in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(name, interrupt)
    lock_path = Path(tempfile.gettempdir()) / f'keqdis-wifi-acceptance-{os.getuid()}.lock'
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        attributes = os.fstat(descriptor)
        if attributes.st_uid != os.getuid() or not stat.S_ISREG(attributes.st_mode):
            raise SupervisorError('invalid-supervisor-lock')
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = supervise(plan, directory, cancelled=lambda: stopped)
        return 0 if result['success'] else 2
    finally:
        os.close(descriptor)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--device')
    parser.add_argument('--offline-seconds', type=int, default=8)
    parser.add_argument('--arm-seconds', type=int, default=120)
    parser.add_argument('--observe-seconds', type=int, default=45)
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        if sys.platform != 'darwin' or os.geteuid() == 0:
            raise SupervisorError('requires-unprivileged-macos-user')
        if args.worker:
            if not args.execute or args.output_dir is None:
                raise SupervisorError('worker-requires-explicit-execute')
            directory = args.output_dir.resolve()
            metadata = directory.stat()
            if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
                raise SupervisorError('invalid-private-directory')
            return worker(json.loads((directory / 'plan.json').read_text()), directory)
        current = inspect(System(), args.device)
        plan = {'device': current['device'], 'offlineSeconds': args.offline_seconds,
                'armSeconds': args.arm_seconds, 'observeSeconds': args.observe_seconds}
        validate_plan(plan)
        if not args.execute:
            print(json.dumps(current, sort_keys=True))
            return 0
        if not current['canArm'] or args.output_dir is None:
            raise SupervisorError('execute-needs-new-output-directory-wifi-on-and-closed-gui')
        directory = args.output_dir.absolute()
        if directory.exists() or directory.is_symlink():
            raise SupervisorError('output-directory-already-exists')
        directory.mkdir(mode=0o700, parents=True)
        directory = directory.resolve()
        private_json(directory / 'plan.json', plan)
        log = os.open(directory / 'supervisor.jsonl', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                '--worker', '--execute', '--output-dir', str(directory)],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                start_new_session=True, close_fds=True)
        finally:
            os.close(log)
        # Return immediately. The independent worker must report ARMED before a
        # tester creates GO; the launching tool need not remain alive.
        print(json.dumps({'started': True, 'supervisorPid': process.pid,
                          'outputDirectory': str(directory), 'waitFor': 'ARMED',
                          'beginMarker': 'GO', 'cancelMarker': 'CANCEL'}))
        return 0
    except Exception as error:
        print(json.dumps({'errorCode': safe_error(error)}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
