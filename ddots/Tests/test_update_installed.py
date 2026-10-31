import importlib.util
from pathlib import Path
import tempfile
import unittest
import plistlib
from unittest.mock import call, patch

spec = importlib.util.spec_from_file_location('update_installed', Path(__file__).resolve().parents[1] / 'scripts/update_installed.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class UpdateTests(unittest.TestCase):
    def transition(self, previous=True):
        from update_channel import policy, PUBLIC_BUNDLE
        _, previous_bundle, _ = policy('private')
        for app, bundle in [(self.dest, previous_bundle), (self.source, PUBLIC_BUNDLE)]:
            (app / 'Contents').mkdir()
            info = dict(CFBundleIdentifier=bundle)
            if app == self.source and previous:
                info['DDotsPreviousBundleIdentifiers'] = [previous_bundle]
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))

    def test_public_transition_requires_declared_previous_identity_before_stopping(self):
        self.transition(previous=False)
        with patch.object(m, 'verify'), patch.object(m, 'stop') as stop:
            with self.assertRaisesRegex(RuntimeError, '이전 설치'):
                m.update(self.source, self.dest, channel='public', migrate_private=True)
            stop.assert_not_called()
        self.assertTrue((self.dest / 'old').exists())

    def test_public_transition_is_explicit_and_preserves_recovery_app(self):
        self.transition()
        def copy(*args):
            import shutil
            shutil.copytree(self.source, self.dest)
        with patch.object(m, 'verify') as verify, patch.object(m, 'stop'), \
                patch.object(m, 'run', side_effect=copy), patch.object(m, 'launch'), \
                patch.object(m, 'prune') as prune:
            m.update(self.source, self.dest, channel='public', migrate_private=True)
            self.assertEqual(verify.call_args_list, [call(self.source, channel='public'),
                              call(self.dest, channel='private'), call(self.dest, channel='public')])
            prune.assert_not_called()
        backups = list(self.root.glob('*.bak-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'old').read_text(), 'preserve')

    def test_public_update_cannot_silently_replace_private_installation(self):
        self.transition()
        with patch.object(m, 'verify'), patch.object(m, 'stop') as stop:
            with self.assertRaisesRegex(RuntimeError, 'migrate-private'):
                m.update(self.source, self.dest, channel='public')
            stop.assert_not_called()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'build.app'
        self.dest = self.root / 'ddots.app'
        self.source.mkdir()
        self.dest.mkdir()
        (self.dest / 'old').write_text('preserve')

    def test_stop_targets_only_the_installation(self):
        with patch.object(m, 'run') as run:
            m.stop(self.source, self.dest)
            run.assert_called_once_with(str(self.source / 'Contents/MacOS/ddots'), '--quit-app', str(self.dest))

    def test_invalid_signature_does_not_stop_or_touch_app(self):
        with patch.object(m, 'verify', side_effect=RuntimeError('invalid')), patch.object(m, 'stop') as stop:
            with self.assertRaises(RuntimeError):
                m.update(self.source, self.dest)
            stop.assert_not_called()
        self.assertEqual((self.dest / 'old').read_text(), 'preserve')

    def test_stop_failure_preserves_install(self):
        with patch.object(m, 'verify'), patch.object(m, 'stop', side_effect=RuntimeError('busy')):
            with self.assertRaises(RuntimeError):
                m.update(self.source, self.dest)
        self.assertTrue((self.dest / 'old').exists())
        self.assertEqual(list(self.root.glob('*.bak-*')), [])

    def test_copy_failure_restores_backup_and_relaunches(self):
        with patch.object(m, 'verify'), patch.object(m, 'stop'), patch.object(m, 'run', side_effect=RuntimeError('copy')), patch.object(m, 'launch') as launch:
            with self.assertRaises(RuntimeError):
                m.update(self.source, self.dest)
            launch.assert_called_once_with(self.dest)
        self.assertEqual((self.dest / 'old').read_text(), 'preserve')

    def test_new_signature_failure_removes_partial_and_restores(self):
        def copy(*args):
            self.dest.mkdir()
            (self.dest / 'new').touch()
        with patch.object(m, 'verify', side_effect=[None, RuntimeError('signature')]), patch.object(m, 'stop'), patch.object(m, 'run', side_effect=copy), patch.object(m, 'launch'):
            with self.assertRaises(RuntimeError):
                m.update(self.source, self.dest)
        self.assertTrue((self.dest / 'old').exists())
        self.assertFalse((self.dest / 'new').exists())

    def test_launch_failure_stops_new_app_and_restores_old(self):
        def copy(*args):
            self.dest.mkdir()
            (self.dest / 'new').touch()
        with patch.object(m, 'verify'), patch.object(m, 'stop') as stop, patch.object(m, 'run', side_effect=copy), patch.object(m, 'launch', side_effect=[RuntimeError('launch'), None]) as launch:
            with self.assertRaises(RuntimeError):
                m.update(self.source, self.dest)
            self.assertEqual(stop.call_args_list, [call(self.source, self.dest), call(self.source, self.dest)])
            self.assertEqual(launch.call_count, 2)
        self.assertTrue((self.dest / 'old').exists())
        self.assertFalse((self.dest / 'new').exists())

    def test_success_removes_recovery_backups(self):
        for stamp in ['20260101-000000-000001', '20260102-000000-000001']:
            self.dest.with_name(self.dest.name + '.bak-' + stamp).mkdir()
        unrelated = self.dest.with_name(self.dest.name + '.bak-manual')
        unrelated.mkdir()
        def copy(*args):
            self.dest.mkdir()
        with patch.object(m, 'verify') as verify, patch.object(m, 'stop') as stop, patch.object(m, 'run', side_effect=copy), patch.object(m, 'launch') as launch:
            m.update(self.source, self.dest)
            self.assertEqual(verify.call_count, 2)
            stop.assert_called_once_with(self.source, self.dest)
            launch.assert_called_once_with(self.dest)
        kept = list(self.root.glob('*.bak-2*'))
        self.assertEqual(len(kept), 0)
        self.assertTrue(unrelated.exists())

    def test_real_install_keeps_recovery_copies_outside_applications(self):
        self.assertEqual(m.backup_folder(m.DESTINATION.expanduser().absolute()), m.BACKUPS)
        self.assertNotIn('Applications', m.BACKUPS.parts[-3:])
        self.assertEqual(m.backup_folder(self.dest), self.root)

    def test_ad_hoc_build_is_refused_before_anything_changes(self):
        adhoc = type('Result', (), {'stdout': '', 'stderr': 'Identifier=io.github.hermes-ddots-p.ddots\nSignature=adhoc\n'})()
        with patch.object(m, 'run', return_value=adhoc), patch.object(m, 'stop') as stop:
            with self.assertRaisesRegex(RuntimeError, 'setup-signing'):
                m.update(self.source, self.dest)
            stop.assert_not_called()
        self.assertEqual((self.dest / 'old').read_text(), 'preserve')
        self.assertEqual(list(self.root.glob('*.bak-*')), [])
