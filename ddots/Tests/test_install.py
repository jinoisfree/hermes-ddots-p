import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location('install', Path(__file__).resolve().parents[1] / 'scripts/install.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def app(path, identifier, version='1.0', script=None):
    (path / 'Contents').mkdir(parents=True)
    values = {'CFBundleIdentifier': identifier, 'CFBundleShortVersionString': version, 'CFBundleVersion': '1'}
    with open(path / 'Contents/Info.plist', 'wb') as file:
        plistlib.dump(values, file)
    if script is not None:
        binary = path / 'Contents/MacOS' / m.EXECUTABLE
        binary.parent.mkdir()
        binary.write_text('#!/bin/sh\n' + script)
        binary.chmod(0o755)
    return path


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.user = Path(self.temp.name) / 'user'
        self.system = Path(self.temp.name) / 'system'
        self.user.mkdir(); self.system.mkdir()
        self.destination = self.user / m.NAME
        self.log = Path(self.temp.name) / 'calls'
        self.record = f'echo "$(basename "$0") $*" >> "{self.log}"\n'
        self.updater = MagicMock()
        for target, value in [('load_updater', MagicMock(return_value=self.updater)), ('check_signature', MagicMock())]:
            patcher = patch.object(m, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def build(self, version='2.0'):
        return app(Path(self.temp.name) / 'build' / m.NAME, m.BUNDLE_ID, version=version, script=self.record)

    def test_first_install_leaves_other_running_copies_alone(self):
        source = self.build()
        self.assertEqual(m.install(source, self.destination, [self.user, self.system]), [])
        self.updater.stop.assert_not_called()
        self.updater.launch.assert_called_once_with(self.destination)
        self.assertTrue(source.is_dir())
        self.assertTrue(m.is_current(self.destination))

    def test_finds_backups_and_copy_in_other_folder(self):
        other = app(self.system / m.NAME, m.BUNDLE_ID)
        app(self.destination, m.BUNDLE_ID)
        backup = app(self.user / 'ddots.app.bak-20261004-014901-479311', m.BUNDLE_ID)
        self.assertEqual(set(m.outdated([self.user, self.system], self.destination)), {other, backup})

    def test_destination_outside_the_application_folders_is_refused(self):
        installed = app(self.destination, m.BUNDLE_ID)
        elsewhere = Path(self.temp.name) / 'elsewhere' / m.NAME
        with self.assertRaises(RuntimeError):
            m.install(self.build(), elsewhere, [self.user, self.system])
        self.assertTrue(installed.exists())
        self.assertFalse(elsewhere.exists())
        self.assertEqual(self.calls(), [])

    def test_public_app_and_unrelated_items_are_never_touched(self):
        app(self.user / 'assistant-pet.app', 'com.starter-owner.taesik')
        app(self.system / m.NAME, 'com.example.other')
        app(self.user / 'ddots.app.bak-20261004-014901-479311', 'com.example.other')
        (self.user / 'ddots.app.bak-notes').mkdir()
        self.assertEqual(m.outdated([self.user, self.system, self.user / 'missing'], self.destination), [])

    def test_old_copy_that_will_not_quit_is_kept(self):
        other = app(self.system / m.NAME, m.BUNDLE_ID, script=self.record)
        tool = m.binary(app(self.destination, m.BUNDLE_ID, script='exit 1\n'))
        with self.assertRaises(RuntimeError):
            m.retire(other, tool)
        self.assertTrue(other.is_dir())
        self.assertEqual(self.calls(), [])

    def test_old_copy_is_quit_by_folder_through_the_new_build(self):
        other = app(self.system / m.NAME, m.BUNDLE_ID, script=self.record)
        tool = m.binary(app(self.destination, m.BUNDLE_ID, script=self.record))
        m.retire(other, tool)
        self.assertFalse(other.exists())
        # The new build quits only the copy running from the requested folder.
        self.assertEqual(self.calls(), [f'ddots --quit-app {other}', 'ddots --disable-login'])

    def test_backup_folder_is_deleted_without_running_it(self):
        backup = app(self.user / 'ddots.app.bak-20261004-004255-358766', m.BUNDLE_ID)
        with patch.object(m.subprocess, 'run') as run:
            m.retire(backup, self.destination / 'unused')
            run.assert_not_called()
        self.assertFalse(backup.exists())

    def test_first_install_places_new_build_before_removing_other_copy_and_keeps_login(self):
        other = app(self.system / m.NAME, m.BUNDLE_ID,
                     script=self.record + 'echo login=enabled\n')
        order = []
        retire = m.retire
        def retire_after_copy(path, tool):
            self.assertTrue(m.is_current(self.destination))
            self.assertEqual(m.version(self.destination), ('2.0', '1'))
            retire(path, tool)
        self.updater.launch.side_effect = lambda path: order.append(('launch', other.exists()))
        with patch.object(m, 'retire', side_effect=retire_after_copy):
            self.assertEqual(m.install(self.build(), self.destination, [self.user, self.system]), [])
        self.assertTrue(m.is_current(self.destination))
        self.assertFalse(other.exists())
        self.assertEqual(order, [('launch', False)])
        self.assertIn('ddots --enable-login', self.calls())
        self.updater.update.assert_not_called()

    def test_failed_first_install_leaves_the_old_copy_and_no_partial_app(self):
        other = app(self.system / m.NAME, m.BUNDLE_ID, script=self.record)
        def broken(source, destination):
            destination.mkdir()
            raise RuntimeError('copy')
        with patch.object(m, 'copy', side_effect=broken), self.assertRaises(RuntimeError):
            m.install(self.build(), self.destination, [self.user, self.system])
        self.assertTrue(other.is_dir())
        self.assertFalse(self.destination.exists())
        self.updater.launch.assert_not_called()

    def test_failed_update_leaves_older_copies(self):
        app(self.destination, m.BUNDLE_ID, version='1.9', script=self.record)
        other = app(self.system / m.NAME, m.BUNDLE_ID, script=self.record)
        self.updater.update.side_effect = RuntimeError('signature')
        with self.assertRaises(RuntimeError):
            m.install(self.build(), self.destination, [self.user, self.system])
        self.assertTrue(other.is_dir())
        # The share taken down for the update comes back with the app that was rolled back to.
        self.updater.start_relay.assert_called_once_with(self.destination)

    def test_existing_install_is_updated_then_other_copy_removed(self):
        source = self.build()
        app(self.destination, m.BUNDLE_ID, version='1.9', script=self.record)
        other = app(self.system / m.NAME, m.BUNDLE_ID, script=self.record)
        self.assertEqual(m.install(source, self.destination, [self.user, self.system]), [])
        self.updater.update.assert_called_once_with(source, self.destination)
        self.updater.stop_relay.assert_called_once()
        self.updater.start_relay.assert_called_once_with(self.destination)
        self.updater.launch.assert_not_called()
        self.assertFalse(other.exists())

    def test_same_version_is_not_reinstalled_unless_forced(self):
        source = self.build()
        app(self.destination, m.BUNDLE_ID, version='2.0', script=self.record)
        stale = app(self.user / 'ddots.app.bak-20261004-014901-479311', m.BUNDLE_ID)
        m.install(source, self.destination, [self.user, self.system])
        self.updater.update.assert_not_called()
        self.assertFalse(stale.exists())
        m.install(source, self.destination, [self.user, self.system], force=True)
        self.updater.update.assert_called_once_with(source, self.destination)

    def test_copy_that_cannot_be_removed_is_reported(self):
        app(self.destination, m.BUNDLE_ID, version='2.0', script='exit 1\n')
        other = app(self.system / m.NAME, m.BUNDLE_ID, script=self.record)
        self.assertEqual(m.install(self.build(), self.destination, [self.user, self.system]), [other])
        self.assertTrue(other.is_dir())

    def test_other_builds_are_refused(self):
        source = app(Path(self.temp.name) / 'public.app', 'com.starter-owner.taesik')
        with self.assertRaises(RuntimeError):
            m.install(source, self.destination, [self.user, self.system])
        self.assertFalse(self.destination.exists())


if __name__ == '__main__':
    unittest.main()
