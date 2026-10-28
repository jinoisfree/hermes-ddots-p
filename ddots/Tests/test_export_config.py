import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS=Path(__file__).resolve().parents[1]/'scripts'
sys.path.insert(0,str(SCRIPTS))
import export_config as E
import migrate_local_settings as M

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
        config={'gateway':{'common_router':{'profiles':{'fallback':'guide'},'aliases':{'guide':['Guide']},'patterns':{}}},'token':'xoxb-not-exported'}
        calls=[]
        def read(path):
            calls.append(path.name)
            return config if path.name=='config.yaml' else {'display_name':'Guide','secret':'sk-not-exported'}
        with tempfile.TemporaryDirectory() as d, patch.object(E,'yaml_load',side_effect=read), patch.object(E.importlib,'import_module',side_effect=lambda n:router if n.endswith('common_router') else project):
            first=E.export(Path(d));second=E.export(Path(d))
            self.assertEqual(first,second)
            self.assertGreaterEqual(len(first['routing_samples']),30)
            self.assertNotIn('not-exported',json.dumps(first))
            self.assertEqual(set(calls),{'config.yaml','profile.yaml'})

    def test_numeric_error_does_not_echo_input(self):
        secret='sk-do-not-echo'
        with self.assertRaises(ValueError) as caught:E.contract({'typo_correction':{'max_distance':secret}})
        self.assertNotIn(secret,str(caught.exception))

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

if __name__=='__main__':unittest.main()
