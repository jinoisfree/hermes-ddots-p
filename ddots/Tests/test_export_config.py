import importlib.util
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS=Path(__file__).resolve().parents[1]/'scripts'
sys.path.insert(0,str(SCRIPTS))
import export_config as E
import migrate_local_settings as M

def _owner_contract():
    path = Path(__file__).resolve().parents[2] / 'hermes/plugins/team-kit/lib/hermes_router/owner_contract.py'
    spec = importlib.util.spec_from_file_location('owner_contract_under_test', path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


class ConfigExportTests(unittest.TestCase):
    def test_conversation_allowlist(self):
        value = E.conversation_contract({'schema': 1, 'patterns': {'approval1': '[', 'secret': 'ignored'},
             'sets': {'yes': ['go']}, 'numbers': {'longThread': True}, 'credentials': 'ignored'})
        self.assertEqual(value, {'schema': 1, 'patterns': {'approval1': '['}, 'sets': {'yes': ['go']}})
        self.assertIsNone(E.conversation_contract({'schema': True}))
        self.assertIsNone(E.conversation_contract({'schema': 2}))
        with self.assertRaises(ValueError):
            E.conversation_contract({'schema': 1, 'texts': {'approveText': 'xoxb-' + '1'*30}})

    def test_allowlist(self):
        result=E.contract({'profiles':{'wiki':'guide','fallback':'helper','token':'not-exported'},'patterns':{'wiki_target':'wiki','private':'not-exported'},'credentials':'not-exported'})
        self.assertNotIn('not-exported',json.dumps(result))
    def test_secrets_fail_before_replace(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'settings.json';p.write_text('existing')
            for secret in ['xoxb-'+'1234567890'*3,'sk-'+'a'*30,'aB9/'*16,'ghp_'+'a'*36,'github_pat_'+'a'*32,'ya29.'+'a'*32]:
                with self.assertRaises(ValueError): E.atomic_json(p,{'displayName':secret})
                self.assertEqual(p.read_text(),'existing')
    def test_deterministic_atomic(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'settings.json';E.atomic_json(p,{'z':1,'a':2});before=p.read_bytes();E.atomic_json(p,{'a':2,'z':1});self.assertEqual(p.read_bytes(),before)
            self.assertEqual([x.name for x in Path(d).iterdir()],['settings.json'])
    def test_export_reads_only_metadata_and_is_deterministic(self):
        from types import SimpleNamespace
        router=SimpleNamespace(select_profile=lambda text,contract:SimpleNamespace(profile='guide'))
        project=SimpleNamespace(routing_contract=lambda raw,*args:raw)
        registry=SimpleNamespace(roster=lambda:{'guide':{'name':'Guide','label':'Guide','aliases':(), 'roles':()}}, home_of=lambda p,h:h)
        config={'gateway':{'common_router':{'profiles':{'fallback':'guide'},'aliases':{'guide':['Guide']},'patterns':{}}},'token':'xoxb-not-exported'}
        owner=_owner_contract()
        calls=[]
        def read(path):
            calls.append(path.name)
            return config if path.name=='config.yaml' else {} if path.name=='vault.yaml' else {'display_name':'Guide','secret':'sk-not-exported'}
        modules={'hermes_facility.team_registry':registry,'hermes_router.owner_contract':owner,'hermes_router.common_router':router}
        with tempfile.TemporaryDirectory() as d, patch.object(E,'yaml_load',side_effect=read), patch.object(E.importlib,'import_module',side_effect=lambda n:modules.get(n,project)) as load:
            first=E.export(Path(d));second=E.export(Path(d))
            self.assertEqual(first,second)
            self.assertEqual([member['profile'] for member in first['members']], ['guide'])
            self.assertEqual(first['routing']['base']['profiles']['fallback'], 'guide')
            self.assertGreaterEqual(len(first['routing_samples']),30)
            self.assertNotIn('not-exported',json.dumps(first))
            self.assertEqual(set(calls),{'config.yaml','vault.yaml'})
            self.assertEqual([call.args[0] for call in load.call_args_list],
                             ['hermes_facility.team_registry', 'hermes_router.owner_contract',
                              'hermes_router.common_router', 'hermes_router.project_threads'] * 2)

    def test_missing_router_reports_team_kit_lib(self):
        config = {'gateway': {'common_router': {'profiles': {'fallback': 'guide'}}}}
        with tempfile.TemporaryDirectory() as d, patch.object(E, 'yaml_load', return_value=config), \
             patch.object(E.importlib, 'import_module', side_effect=ModuleNotFoundError('missing')):
            with self.assertRaisesRegex(RuntimeError, 'team-kit.*lib.*PYTHONPATH.*--team-kit-lib'):
                E.export(Path(d))

    def test_classification_metadata_is_not_exported(self):
        result = E.contract({'profiles': {'fallback': 'helper', 'wiki': 'guide'},
                             'patterns': {'wiki': 'wiki'}, 'aliases': {'guide': ['Guide']},
                             'alias_order': ['guide'], 'address_prefixes': {'enabled': True},
                             'typo_correction': {'max_distance': 'unused'}})
        self.assertEqual(result, {'profiles': {'fallback': 'helper'}, 'cross_owner': {}})

    def test_yaml_error_does_not_echo_source(self):
        from types import SimpleNamespace
        parser=SimpleNamespace(load=lambda text:(_ for _ in ()).throw(ValueError('secret-source-line')))
        with tempfile.TemporaryDirectory() as d, patch.dict(sys.modules,{'ruamel.yaml':SimpleNamespace(YAML=lambda **kw:parser)}):
            path=Path(d)/'config.yaml';path.write_text('invalid')
            with self.assertRaises(ValueError) as caught:E.yaml_load(path)
            self.assertNotIn('secret-source-line',str(caught.exception))
            self.assertIn('config.yaml',str(caught.exception))

    def test_missing_ruamel(self):
        with patch.dict(sys.modules,{'ruamel.yaml':None}):
            with self.assertRaisesRegex(RuntimeError,'gateway venv'): E.yaml_load(Path('/unused'))
    def test_migration_allowlist_and_disabled_defaults(self):
        result=M.migrate({'vaultBotUserID':'B_TEST','secret':'unused','threeTap':{'profile':'doctor','channel':'C_TEST','token':'unused'}})
        self.assertNotIn('unused',json.dumps(result));self.assertEqual(result['threeTap'],{'profile':'doctor','channel':'C_TEST'})
        self.assertEqual(M.migrate({})['vaultBotUserID'],'');self.assertEqual(M.migrate({})['order'],[])
    def test_migration_secret_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):E.atomic_json(Path(d)/'out.json',M.migrate({'vaultBotUserID':'xoxb-'+'a'*50}))

class RosterExportIntegrationTests(unittest.TestCase):
    """T-01/03/05: exercise the CLI, facility parser and atomic output in synthetic homes."""
    lib = Path(__file__).resolve().parents[2] / 'hermes/plugins/team-kit/lib'
    # The exporter requires Hermes' ruamel environment; CI may select it explicitly.
    hermes_python = Path.home() / '.hermes/hermes-agent/venv/bin/python'
    python = os.environ.get('DDOTS_EXPORT_PYTHON') or (str(hermes_python) if hermes_python.is_file() else sys.executable)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'hermes'
        (self.home / 'owner').mkdir(parents=True)
        self.output = Path(self.tmp.name) / 'ddots-config.json'
        self.agents = {
            'zeta': {'name': 'Full Name', 'label': 'Display', 'aliases': ['Alias', 'Full Name', 'Alias'], 'roles': ['responder']},
            'default': {'name': 'Root', 'roles': []},
            'alpha': {'name': 'Alpha', 'aliases': ['A'], 'roles': []},
        }
        self.write_roster()
        for profile in ['zeta', 'alpha', 'unlisted']:
            root = self.home / 'profiles' / profile
            root.mkdir(parents=True)
            (root / 'profile.yaml').write_text('display_name: Wrong Name\n')
        (self.home / 'profile.yaml').write_text('display_name: Wrong Root\n')

    def write_roster(self):
        (self.home / 'owner/team.yaml').write_text(json.dumps({'agents': self.agents}))

    def run_export(self, code=0):
        result = subprocess.run([self.python, str(SCRIPTS / 'export_config.py'),
            '--home', str(self.home), '--output', str(self.output), '--team-kit-lib', str(self.lib)],
            env={**os.environ, 'HERMES_HOME': str(self.home), 'HERMES_TEAM_FILE': '/must-not-read'},
            capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def test_roster_names_aliases_order_and_slack_source(self):
        router = {'profiles': {'fallback': 'alpha'}, 'aliases': {'alpha': ['Router Only']},
                  'project_hub': {'staff_user_ids': {'alpha': 'B_ALPHA'}}}
        (self.home / 'config.yaml').write_text(json.dumps({'gateway': {'common_router': router}}))
        self.run_export()
        value = json.loads(self.output.read_text())
        self.assertEqual(value['members'], [
            {'profile': 'default', 'displayName': 'Root', 'aliases': [], 'slackUserID': ''},
            {'profile': 'alpha', 'displayName': 'Alpha', 'aliases': ['A'], 'slackUserID': 'B_ALPHA'},
            {'profile': 'zeta', 'displayName': 'Display', 'aliases': ['Full Name', 'Alias'], 'slackUserID': ''}])
        self.assertNotIn('Wrong', self.output.read_text())
        self.assertNotIn('Router Only', str(value['members']))
        first = self.output.read_bytes()
        self.run_export()
        self.assertEqual(first, self.output.read_bytes())

    def test_missing_broken_empty_and_no_home_preserve_output(self):
        roster = self.home / 'owner/team.yaml'
        for text in [None, 'agents: [broken', 'agents: {}', 'agents: {missing: {name: Missing}}']:
            with self.subTest(text=text):
                if text is None:
                    roster.unlink()
                else:
                    roster.write_text(text)
                self.output.write_bytes(b'existing-output\x00')
                result = self.run_export(1)
                self.assertEqual(self.output.read_bytes(), b'existing-output\x00')
                self.assertEqual(len([line for line in result.stderr.splitlines() if not line.startswith('경고:')]), 1)
                self.assertRegex(result.stderr, '[가-힣]')
                self.assertEqual(result.stdout, '')

    def test_unreadable_roster_preserves_output(self):
        roster = self.home / 'owner/team.yaml'
        roster.unlink()
        roster.mkdir()  # Portable read failure even when the test process can bypass file modes.
        self.output.write_bytes(b'previous')
        result = self.run_export(1)
        self.assertEqual(self.output.read_bytes(), b'previous')
        self.assertEqual(len(result.stderr.splitlines()), 1)
        self.assertRegex(result.stderr, '[가-힣]')

    def test_no_router_fallback_remains_in_filtered_members(self):
        cases = [('zeta', None), ('default', 'zeta'), ('alpha', 'default')]
        for expected, remove in cases:
            with self.subTest(expected=expected):
                if remove == 'zeta':
                    import shutil
                    shutil.rmtree(self.home / 'profiles/zeta')
                elif remove:
                    del self.agents[remove]
                    self.write_roster()
                result = self.run_export()
                value = json.loads(self.output.read_text())
                members = {m['profile'] for m in value['members']}
                self.assertEqual(value['defaults']['recipient'], expected)
                self.assertIn(expected, members)
                self.assertEqual(value['routing']['base']['profiles']['fallback'], expected)
                self.assertEqual(value['routing']['hub']['profiles']['fallback'], expected)
                self.assertEqual(value['routing_samples'], [])
                self.assertNotIn('unlisted', members)
                if expected != 'zeta':
                    self.assertNotIn('zeta', members)
                    self.assertIn('zeta', result.stderr)

    def test_multiple_responders_choose_first_in_roster(self):
        # Same rule as the facility's first_with: roster order, so the router and ddots agree.
        self.agents['alpha']['roles'] = ['responder']
        self.write_roster()
        self.run_export()
        self.assertEqual(json.loads(self.output.read_text())['defaults']['recipient'], 'zeta')

    def test_present_router_takes_responder_from_roster(self):
        # The router contract keeps rules only; its own fallback value is ignored.
        for raw in [{}, {'profiles': {'data_operations': 'alpha'}}, {'profiles': {'fallback': 'unlisted'}},
                    {'profiles': {'fallback': 'missing'}}]:
            with self.subTest(raw=raw):
                (self.home / 'config.yaml').write_text(json.dumps({'gateway': {'common_router': raw}}))
                self.run_export()
                value = json.loads(self.output.read_text())
                self.assertEqual(value['defaults']['recipient'], 'zeta')
                self.assertEqual(value['routing']['base']['profiles']['fallback'], 'zeta')
                self.assertEqual(value['routing']['hub']['profiles']['fallback'], 'zeta')

    def test_roster_responder_without_home_preserves_output(self):
        import shutil
        shutil.rmtree(self.home / 'profiles/zeta')
        (self.home / 'config.yaml').write_text(json.dumps({'gateway': {'common_router': {'profiles': {}}}}))
        self.output.write_bytes(b'previous')
        self.run_export(1)
        self.assertEqual(self.output.read_bytes(), b'previous')

    def test_vault_staff_ids_win_over_router_copy(self):
        router = {'profiles': {}, 'project_hub': {'staff_user_ids': {'alpha': 'B_ROUTER'}}}
        (self.home / 'config.yaml').write_text(json.dumps({'gateway': {'common_router': router}}))
        (self.home / 'owner/vault.yaml').write_text(json.dumps({'slack': {'staff_user_ids': {'alpha': 'B_VAULT'}}}))
        self.run_export()
        members = {m['profile']: m for m in json.loads(self.output.read_text())['members']}
        self.assertEqual(members['alpha']['slackUserID'], 'B_VAULT')

if __name__=='__main__':unittest.main()
