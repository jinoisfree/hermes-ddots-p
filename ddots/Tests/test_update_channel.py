import plistlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import update_channel as channel
import release_update as release
import update_installed as installed


class ChannelTests(unittest.TestCase):
    def tearDown(self):
        release.select_channel('private')

    def test_private_plist_is_byte_identical(self):
        original = (Path(__file__).resolve().parents[1] / 'Resources/Info.plist').read_bytes()
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / 'Info.plist'
            p.write_bytes(original)
            channel.configure(p, 'private')
            self.assertEqual(p.read_bytes(), original)
            channel.configure(p, 'public')
            info = plistlib.loads(p.read_bytes())
            self.assertEqual(info['CFBundleIdentifier'], channel.PUBLIC_BUNDLE)
            self.assertEqual(info['SUPublicEDKey'], plistlib.loads(original)['SUPublicEDKey'])
            self.assertFalse(info['DDotsUpdateRequiresToken'])

    def test_public_release_repository_and_channel_binding(self):
        release.select_channel('public')
        self.assertEqual(release.SOURCE_REPOSITORY, channel.PUBLIC_REPOSITORY)
        self.assertEqual(release.REPOSITORY, channel.PUBLIC_REPOSITORY)
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)
            (p / 'prepared.json').write_text('{"source": {}}')
            with self.assertRaisesRegex(ValueError, '채널'):
                release.check_prepared(p, 'a' * 40)

    def test_public_verification_cannot_accept_private_or_adhoc(self):
        import subprocess
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)
            _, private_bundle, private_identity = channel.policy('private')
            cases = [('Authority=ddots Public Signing\nIdentifier=' + channel.PUBLIC_BUNDLE + '\n', True),
                     ('Authority=Other Local Signing\nIdentifier=com.example.other\n', False),
                     ('Signature=adhoc\n', False)]
            # A generated public tree has a single channel; only a separate private identity is a distinct case.
            if (private_bundle, private_identity) != (channel.PUBLIC_BUNDLE, channel.PUBLIC_IDENTITY):
                cases.append(('Authority=' + private_identity + '\nIdentifier=' + private_bundle + '\n', False))
            for details, ok in cases:
                with patch.object(installed, 'run', return_value=subprocess.CompletedProcess([], 0, '', details)):
                    if ok: installed.verify(p, channel='public')
                    else:
                        with self.assertRaises(RuntimeError): installed.verify(p, channel='public')
