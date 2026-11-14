"""Shared scanner contract and unconfigured-installation source boundary."""
import os
from pathlib import Path
import sys

import pytest

KIT = Path(__file__).resolve().parents[1]
LIBRARY = next(p for p in (KIT / 'lib', KIT.parent / 'team-kit/lib') if p.is_dir())
sys.path.insert(0, str(LIBRARY))
from hermes_facility.airport_boundaries import read_source, scan

FAKE_EMPLOYEE_ID = 'sns-manager'


@pytest.mark.parametrize(('line', 'kind'), [
    ('"' + FAKE_EMPLOYEE_ID.replace('-', '_') + '"', 'roster'), ('"가짜별칭"', 'roster'),
    ('\"' + 'C0' + 'ABCDEFGH1' + '\"', 'slack_id'), ("Path.home()/'.hermes'", 'fixed_home'),
    ('\"a' + '@' + 'example.test\"', 'email'), ('\"/' + 'Users/synthetic/a\"', 'absolute_path'),
    ('\"/' + 'Volumes/synthetic/a\"', 'absolute_path'), ('"$HOME/.hermes"', 'fixed_home'),
    ('"~/.hermes"', 'fixed_home'), ('"abcdef123456"', 'reservation_id'),
    ('"synthetic-vault-value"', 'vault'),
])
def test_scanner_finds_each_boundary(tmp_path, line, kind):
    (tmp_path / 'sample.py').write_text('value = ' + line + '\n')
    roster = {'agents': {FAKE_EMPLOYEE_ID: {'name': '가짜직원', 'aliases': ['가짜별칭']}}}
    findings = scan([('source', tmp_path)], roster, {'account': 'synthetic-vault-value'})
    assert kind in [row[0] for row in findings]
    assert all(len(row) == 3 and len(row[2]) == 16 for row in findings)
    assert all(line not in str(row) for row in findings)


def test_scanner_clean_and_line_movement(tmp_path):
    path = tmp_path / 'sample.py'
    path.write_text('value = 1\n')
    assert scan([('source', tmp_path)]) == []
    path.write_text('value = "abcdef123456"\n')
    before = scan([('source', tmp_path)])
    path.write_text('\n\nvalue = "abcdef123456"\n')
    assert scan([('source', tmp_path)]) == before
    path.write_text('value = "abcdef1234567890"\n')
    assert scan([('source', tmp_path)]) == []


def test_actual_plugins_without_roster():
    home = Path(os.environ.get('HERMES_HOME') or Path.home() / '.hermes')
    if home.parent.name == 'profiles':
        home = home.parent.parent
    team_file = home / 'owner/team.yaml'
    if team_file.exists():
        pytest.skip('운영 명부 있음: 기준선 판정은 airport-check')
    roots = [(p.name, p) for p in sorted(KIT.parent.iterdir()) if p.name in {'team-kit', 'team-delegation'}]
    assert roots and all(p.is_dir() for _, p in roots)
    assert scan(roots, read_source(team_file), patterns=False) == []


def test_reserved_profile_id_keeps_private_aliases(tmp_path):
    roster = {'agents': {'default': {'name': '가짜표시이름', 'aliases': ['가짜루트별칭']}}}
    path = tmp_path / 'sample.py'
    path.write_text('value = "default"\n')
    assert scan([('source', tmp_path)], roster, patterns=False) == []
    path.write_text('value = "가짜루트별칭"\n')
    assert len(scan([('source', tmp_path)], roster, patterns=False)) == 1


@pytest.mark.parametrize(('value', 'expected'), [
    ('login', 0), ('address', 0), ('mode_2-read', 0), ('a' * 16, 0),
    ('a' * 17, 1), ('Hermes_X_V1', 1), ('a' + '@' + 'b.co', 1),
    ('C0' + 'ABCDEFGH1', 1), ('새우튀김', 1), ('1234', 1),
])
def test_vault_configuration_words_and_private_values(tmp_path, value, expected):
    # AC-03f: isolate vault classification from the independent pattern checks.
    import json
    (tmp_path / 'sample.py').write_text('value = ' + json.dumps(value, ensure_ascii=False) + '\n')
    rows = scan([('source', tmp_path)], vault={'setting': value}, patterns=False)
    assert len(rows) == expected
    assert all(kind == 'vault' for kind, _, _ in rows)
