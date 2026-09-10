"""Exercise package scripts in temporary directories with all service tools mocked."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / 'macos/installer'
MOCK = r'''
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['FAKE_ROOT'])
with (root / 'commands').open('a') as out:
    out.write(name + ' ' + ' '.join(args) + '\n')
loaded = root / 'loaded'
if name == 'id' or name == 'stat':
    print('0')
elif name == 'pgrep':
    sys.exit(0 if os.environ.get('FAKE_GUI') else 1)
elif name == 'codesign':
    sys.exit(1 if os.environ.get('FAKE_BAD_SIGNATURE') else 0)
elif name == 'PlistBuddy':
    print('wrong.application' if os.environ.get('FAKE_BAD_APP') else 'io.github.caocaocc.keqdroid')
elif name == 'launchctl':
    if args[0] == 'print':
        if not loaded.exists(): sys.exit(1)
        print('state = running')
    elif args[0] == 'bootout':
        if not loaded.exists(): sys.exit(1)
        loaded.unlink()
    elif args[0] == 'bootstrap':
        marker = root / 'failed-once'
        if os.environ.get('FAKE_BOOTSTRAP_FAIL_ONCE') and not marker.exists():
            marker.touch()
            sys.exit(1)
        loaded.touch()
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.mock = self.root / 'tools'
        self.mock.mkdir()
        for name in ('id', 'stat', 'pgrep', 'codesign', 'PlistBuddy', 'launchctl', 'chown', 'sleep', 'security', 'pkgutil'):
            path = self.mock / name
            path.write_text(f'#!{sys.executable}\n' + MOCK)
            path.chmod(0o755)
        self.runtime = self.root / 'Library/Application Support/io.github.caocaocc.keqdroid'
        self.incoming = Path(str(self.runtime) + '.incoming')
        self.backup = Path(str(self.runtime) + '.previous')
        self.app = self.root / 'Applications/KEQDIS.app'
        self.daemon = self.root / 'Library/LaunchDaemons/io.github.caocaocc.keqdroid.network-service.plist'
        self.daemon.parent.mkdir(parents=True)
        self.daemon.write_text('old-launchd-plist')
        self.make_runtime(self.runtime, 'old')
        self.make_app(self.app, 'old')
        self.make_runtime(self.incoming / 'runtime', 'new')
        self.make_app(self.incoming / 'KEQDIS.app', 'new')
        (self.root / 'loaded').touch()

    def make_runtime(self, path, label):
        (path / 'bin').mkdir(parents=True)
        (path / 'network-service.plist').write_text(label + '-launchd-plist')
        (path / 'identity').write_text(label)
        if label == 'old':
            (path / 'state').mkdir()
            (path / 'state/journal').write_text('keep-recovery-journal')
        helper = path / 'bin/keqdis-network-service'
        helper.write_text('#!/bin/bash\n'
                          f'echo "helper-{label} $*" >> "$FAKE_ROOT/commands"\n'
                          'if [[ "$1" == --recover && "${FAKE_RECOVERY_FAIL:-}" == 1 ]]; then exit 1; fi\n'
                          f'if [[ "$1" == --recover && "${{FAKE_NEW_RECOVERY_FAIL:-}}" == 1 && {label} == new ]]; then exit 1; fi\n')
        helper.chmod(0o755)

    def make_app(self, path, label):
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_text('test-only')
        (path / 'identity').write_text(label)

    def execute(self, name, **extra):
        source = (INSTALLER / name).read_text()
        # Production scripts have no override of protected paths or tool search.
        # Only these test copies are translated into this isolated filesystem.
        source = source.replace("'/Library/", "'" + str(self.root) + '/Library/')
        source = source.replace("'/Applications/", "'" + str(self.root) + '/Applications/')
        source = source.replace('/Users/', str(self.root) + '/Users/')
        source = source.replace('export PATH=/usr/bin:/bin:/usr/sbin:/sbin',
                                f'export PATH="{self.mock}:/usr/bin:/bin:/usr/sbin:/sbin"')
        for executable in ('/usr/bin/codesign', '/usr/libexec/PlistBuddy', '/usr/bin/security', '/usr/sbin/pkgutil'):
            source = source.replace(executable, str(self.mock / Path(executable).name))
        script = self.root / (name + '.sh')
        script.write_text(source)
        return subprocess.run(['/bin/bash', script, 'package', '/', '/'], capture_output=True, text=True,
                              env=dict(os.environ, FAKE_ROOT=str(self.root), **extra))

    def assert_old_intact(self):
        self.assertEqual((self.runtime / 'identity').read_text(), 'old')
        self.assertEqual((self.runtime / 'state/journal').read_text(), 'keep-recovery-journal')
        self.assertEqual((self.app / 'identity').read_text(), 'old')
        self.assertTrue(self.daemon.exists())
        self.assertTrue((self.root / 'loaded').exists())

    def test_preinstall_payload_failure_leaves_old_service_available(self):
        result = self.execute('preinstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_old_intact()

    def test_validation_failure_does_not_touch_old_installation(self):
        shutil.rmtree(self.incoming / 'KEQDIS.app')
        result = self.execute('postinstall')
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_intact()

    def test_bad_signature_does_not_stop_old_service(self):
        result = self.execute('postinstall', FAKE_BAD_SIGNATURE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_intact()

    def test_startup_failure_restores_old_runtime_app_and_journal(self):
        self.daemon.write_text('customized-old-launchd-plist')
        result = self.execute('postinstall', FAKE_BOOTSTRAP_FAIL_ONCE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_intact()
        self.assertEqual(self.daemon.read_text(), 'customized-old-launchd-plist')
        self.assertFalse(self.backup.exists())
        self.assertFalse(Path(str(self.app) + '.previous').exists())

    def test_upgrade_recovers_before_switching_runtime(self):
        result = self.execute('postinstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = (self.root / 'commands').read_text()
        self.assertIn('helper-old --recover', commands)
        self.assertLess(commands.index('helper-old --recover'), commands.index('launchctl bootstrap'))
        self.assertEqual((self.runtime / 'identity').read_text(), 'new')
        self.assertEqual((self.runtime / 'state/journal').read_text(), 'keep-recovery-journal')
        self.assertFalse(self.backup.exists())

    def test_recovery_failure_keeps_old_runtime_and_restarts_service(self):
        result = self.execute('postinstall', FAKE_RECOVERY_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_intact()

    def test_uninstall_validates_app_before_removing_runtime(self):
        result = self.execute('uninstall', FAKE_BAD_APP='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_intact()

    def test_uninstall_failed_recovery_preserves_installation(self):
        result = self.execute('uninstall', FAKE_RECOVERY_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_intact()

    def test_interrupted_upgrade_backup_is_preserved(self):
        self.backup.mkdir()
        (self.backup / 'journal').write_text('preserve interrupted upgrade')
        result = self.execute('postinstall')
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_intact()
        self.assertEqual((self.backup / 'journal').read_text(), 'preserve interrupted upgrade')

    def test_rollback_does_not_load_previously_unloaded_service(self):
        (self.root / 'loaded').unlink()
        result = self.execute('postinstall', FAKE_BOOTSTRAP_FAIL_ONCE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.runtime / 'identity').read_text(), 'old')
        self.assertFalse((self.root / 'loaded').exists())

    def test_fresh_install_failure_removes_only_new_payload(self):
        shutil.rmtree(self.runtime)
        shutil.rmtree(self.app)
        self.daemon.unlink()
        (self.root / 'loaded').unlink()
        result = self.execute('postinstall', FAKE_BOOTSTRAP_FAIL_ONCE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.runtime.exists())
        self.assertFalse(self.app.exists())
        self.assertFalse(self.daemon.exists())
        self.assertFalse((self.root / 'loaded').exists())

    def test_fresh_install_creates_complete_runtime(self):
        shutil.rmtree(self.runtime)
        shutil.rmtree(self.app)
        self.daemon.unlink()
        (self.root / 'loaded').unlink()
        result = self.execute('postinstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.runtime / 'identity').read_text(), 'new')
        self.assertEqual((self.app / 'identity').read_text(), 'new')
        self.assertTrue((self.runtime / 'state').is_dir())
        self.assertTrue((self.root / 'loaded').exists())

    def test_failed_rollback_recovery_preserves_both_versions_and_journal(self):
        result = self.execute('postinstall', FAKE_BOOTSTRAP_FAIL_ONCE='1', FAKE_NEW_RECOVERY_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.backup / 'identity').read_text(), 'old')
        self.assertEqual((self.runtime / 'identity').read_text(), 'new')
        self.assertEqual((self.runtime / 'state/journal').read_text(), 'keep-recovery-journal')
        self.assertTrue(Path(str(self.app) + '.previous').is_dir())
        self.assertFalse((self.root / 'loaded').exists())


if __name__ == '__main__':
    unittest.main()
