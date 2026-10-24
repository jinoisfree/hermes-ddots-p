import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import release_update as m


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'ddots-1.7.0-arm64.zip'
        self.archive.write_bytes(b'synthetic archive')
        self.commit = 'a' * 40
        self.manifest = dict(version='1.7.0', build='112', minimumSystem='13.0',
                             archive=self.archive.name, length=self.archive.stat().st_size,
                             sha256=m.digest(self.archive), signature='synthetic',
                             source=dict(commit=self.commit, dirty=False))

    def save(self):
        (self.root / 'prepared.json').write_text(json.dumps(self.manifest))

    def test_private_asset_feed_has_no_external_notes_or_package(self):
        root = ET.fromstring(m.appcast(self.manifest, 123))
        enclosure = root.find('./channel/item/enclosure')
        self.assertEqual(enclosure.get('url'), 'https://api.github.com/repos/jinoisfree/hermes-ddots-p/releases/assets/123')
        self.assertEqual(enclosure.get('length'), str(self.manifest['length']))
        self.assertEqual(enclosure.get(f'{{{m.NAMESPACE}}}installationType'), 'application')
        self.assertIsNone(root.find(f'.//{{{m.NAMESPACE}}}releaseNotesLink'))

    def test_no_publication_without_exact_commit_approval(self):
        self.save()
        with patch.object(m, 'run') as run:
            with self.assertRaises(ValueError): m.publish(self.root, 'wrong')
            run.assert_not_called()

    def test_dirty_build_not_published(self):
        self.manifest['source']['dirty'] = True
        self.save()
        with patch.object(m, 'run') as run:
            with self.assertRaises(ValueError): m.publish(self.root, self.commit)
            run.assert_not_called()

    def test_modified_archive_not_published(self):
        self.save()
        self.archive.write_bytes(b'changed')
        with patch.object(m, 'run') as run:
            with self.assertRaises(ValueError): m.publish(self.root, self.commit)
            run.assert_not_called()

    def test_foreign_origin_not_published(self):
        self.save()
        with patch.object(m, 'run', side_effect=['', 'https://github.com/elsewhere/app.git']) as run:
            with self.assertRaises(ValueError): m.publish(self.root, self.commit)
            self.assertEqual(run.call_count, 2)

    def test_unpushed_commit_not_published(self):
        self.save()
        with patch.object(m, 'run', side_effect=['', 'https://github.com/jinoisfree/hermes-ddots-p.git',
                                               'b' * 40 + '\trefs/heads/main']) as run:
            with self.assertRaises(ValueError): m.publish(self.root, self.commit)
            self.assertEqual(run.call_count, 3)

    def test_draft_is_resolved_by_id_and_published_only_after_signed_feed(self):
        self.save()
        calls, feed_ref = [], ['f' * 40]
        release_target = 'd' * 40
        def remote(*args, **kwargs):
            args = tuple(str(arg) for arg in args)
            calls.append(args)
            if args[:3] == ('git', 'remote', 'get-url'):
                self.assertEqual(kwargs['cwd'], m.SOURCE_ROOT)
            if args[:2] == ('git', 'push') or 'commit-tree' in args:
                self.assertNotEqual(kwargs['cwd'], m.SOURCE_ROOT)
                self.assertNotEqual(kwargs['cwd'], m.ROOT)
            if args[:3] == ('gh', 'release', 'create'):
                self.assertEqual(args[args.index('--repo') + 1], 'jinoisfree/hermes-ddots-p')
                self.assertEqual(args[args.index('--target') + 1], release_target)
                self.assertIn(self.commit, args[args.index('--notes') + 1])
            if args[:3] == ('git', 'remote', 'get-url'): return 'https://github.com/jinoisfree/hermes-ddots-p.git'
            if args[:2] == ('git', 'ls-remote'):
                if args[3] == 'refs/heads/update-feed': return feed_ref[0] + '\trefs/heads/update-feed'
                if args[2] == m.RELEASE_REMOTE and args[3] == 'refs/heads/main': return release_target + '\trefs/heads/main'
                return self.commit + '\trefs/heads/main' if args[3] == 'refs/heads/main' else ''
            if args[:2] == ('git', 'rev-parse'): return 'f' * 40
            if 'commit-tree' in args:
                self.assertIn('-p', args)
                self.assertEqual(args[args.index('-p') + 1], 'f' * 40)
                return 'c' * 40
            if args[:2] == ('git', 'push'):
                self.assertEqual(args[2:], (m.RELEASE_REMOTE, 'c' * 40 + ':refs/heads/update-feed'))
                feed_ref[0] = 'c' * 40
            if args[:3] == ('gh', 'release', 'view'): return '42'
            if args[:2] == ('gh', 'api'):
                # GitHub cannot resolve a draft through /releases/tags/<tag>.
                self.assertEqual(args[2], 'repos/jinoisfree/hermes-ddots-p/releases/42')
                return json.dumps(dict(draft=True, tag_name='v1.7.0', target_commitish=release_target,
                                       assets=[dict(name=self.archive.name, id=100, state='uploaded',
                                                    size=self.manifest['length'], digest='sha256:' + self.manifest['sha256'])]))
            return ''
        with patch.object(m, 'run', side_effect=remote), patch('builtins.print'):
            m.publish(self.root, self.commit)
        # The feed branch moves only after the release is public, and is checked on the remote afterwards.
        edit = next(i for i, call in enumerate(calls) if call[:3] == ('gh', 'release', 'edit'))
        self.assertIn('--draft=false', calls[edit])
        self.assertLess(edit, next(i for i, call in enumerate(calls) if call[:2] == ('git', 'push')))
        self.assertEqual(calls[-1][:2], ('git', 'ls-remote'))
        self.assertEqual(feed_ref[0], 'c' * 40)
        feed = ET.fromstring((self.root / 'appcast.xml').read_bytes())
        self.assertTrue(feed.find('./channel/item/enclosure').get('url').endswith('/assets/100'))

    def test_existing_version_tag_cannot_point_to_another_commit(self):
        self.save()
        with patch.object(m, 'run', side_effect=['', 'https://github.com/jinoisfree/hermes-ddots-p.git',
                 self.commit + '\trefs/heads/main', 'd' * 40 + '\trefs/heads/main', 'b' * 40 + '\trefs/tags/v1.7.0']) as run:
            with self.assertRaises(ValueError): m.publish(self.root, self.commit)
            self.assertEqual(run.call_count, 5)

    def test_empty_source_main_is_rejected_before_distribution_writes(self):
        self.save()
        with patch.object(m, 'run', side_effect=['', 'https://github.com/jinoisfree/hermes-ddots-p.git', '']) as run:
            with self.assertRaises(ValueError): m.publish(self.root, self.commit)
            self.assertEqual(run.call_count, 3)

    def test_feed_fetches_parent_before_creating_commit_and_has_no_source_objects(self):
        import subprocess
        remote = self.root / 'distribution'
        subprocess.run(['git', 'init', '-q', str(remote)], check=True)
        subprocess.run(['git', '-C', str(remote), 'config', 'user.name', 'Fixture'], check=True)
        subprocess.run(['git', '-C', str(remote), 'config', 'user.email', 'fixture@example.invalid'], check=True)
        (remote / 'appcast.xml').write_text('old feed')
        subprocess.run(['git', '-C', str(remote), 'add', 'appcast.xml'], check=True)
        subprocess.run(['git', '-C', str(remote), '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)
        parent = subprocess.check_output(['git', '-C', str(remote), 'rev-parse', 'HEAD'], text=True).strip()
        subprocess.run(['git', '-C', str(remote), 'branch', 'update-feed'], check=True)
        feed = self.root / 'appcast.xml'
        feed.write_text('new signed feed')
        real_run, pushed = m.run, []
        def local_only(*args, **kwargs):
            if args[:2] == ('git', 'push'):
                sha = args[3].split(':')[0]
                self.assertEqual(args[2], str(remote))
                self.assertEqual(real_run('git', 'rev-parse', sha + '^', **kwargs), parent)
                self.assertEqual(real_run('git', 'ls-tree', '--name-only', sha, **kwargs), 'appcast.xml')
                self.assertEqual(real_run('git', 'show', sha + ':appcast.xml', **kwargs), 'new signed feed')
                pushed.append(sha)
                return ''  # No push, including to the local fixture.
            if args[:2] == ('git', 'ls-remote') and pushed:
                return pushed[0] + '\trefs/heads/update-feed'
            return real_run(*args, **kwargs)
        with patch.object(m, 'RELEASE_REMOTE', str(remote)), patch.object(m, 'run', side_effect=local_only), patch('builtins.print'):
            m.publish_feed(feed, '1.7.0')
        self.assertEqual(len(pushed), 1)

    def test_build_info_records_monorepo_commit_from_app_subdirectory(self):
        import subprocess
        import build_info
        repo = self.root / 'source'
        app = repo / 'ddots'
        (app / 'Sources').mkdir(parents=True)
        (app / 'Sources/fixture.swift').write_text('// fixture')
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c',
                        'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
                        'commit', '-qm', 'fixture'], check=True)
        sha = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        with patch.object(build_info, 'ROOT', app):
            self.assertEqual(build_info.source_info(), dict(commit=sha, dirty=False))
            (app / 'Sources/fixture.swift').write_text('// changed')
            self.assertTrue(build_info.source_info()['dirty'])


if __name__ == '__main__': unittest.main()
