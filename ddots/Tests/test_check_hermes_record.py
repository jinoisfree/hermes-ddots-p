import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_hermes_record', ROOT / 'scripts/check_hermes_record.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class HermesRecordContract(unittest.TestCase):
    def setUp(self):
        self.contract = json.loads(m.CONTRACT.read_text())
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def store(self, *statements):
        path = Path(self.folder.name) / 'state.db'
        with sqlite3.connect(path) as db:
            for statement in statements:
                db.execute(statement)
        return path

    def test_a_record_with_every_column_passes(self):
        tables = {}
        for part in ('required', 'optional'):
            for table, names in self.contract[part].items():
                tables.setdefault(table, []).extend(names)
        path = self.store(*[f'CREATE TABLE {table} ({", ".join(names)})' for table, names in tables.items()])
        self.assertEqual(m.check(path, self.contract), ([], []))

    def test_missing_columns_are_named(self):
        path = self.store('CREATE TABLE sessions (id TEXT, source TEXT)',
                          'CREATE TABLE messages (id INTEGER, session_id TEXT, role TEXT, content TEXT, timestamp REAL)')
        required, optional = m.check(path, self.contract)
        self.assertEqual(required, ['messages.tool_calls'])
        self.assertIn('session_turn_leases.holder', optional)
        self.assertIn('sessions.chat_id', optional)

    def test_the_contract_names_what_the_app_asks_for(self):
        # The same names stand in HermesBridge's own checks; a column added there belongs here too.
        source = (ROOT / 'Sources/HermesBridge.swift').read_text()
        for part in ('required', 'optional'):
            for names in self.contract[part].values():
                for name in names:
                    self.assertIn(f'"{name}"', source, name)


if __name__ == '__main__':
    unittest.main()
