#!/usr/bin/env python3
"""Check that a Hermes record still has the tables and columns ddots reads from it.

Opens each profile's state.db read-only and looks at column names only; no conversation is read.
"""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / 'Tests/Fixtures/hermes-record-columns.json'


def columns(path):
    """Column names by table, read without taking a write lock."""
    with sqlite3.connect(f'file:{path}?mode=ro', uri=True) as db:
        tables = [row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        return {table: {row[1] for row in db.execute(f'PRAGMA table_info("{table}")')} for table in tables}


def missing(found, wanted):
    return sorted(f'{table}.{column}' for table, names in wanted.items() for column in names if column not in found.get(table, set()))


def check(path, contract):
    """What ddots needs and does not find: (required, optional)."""
    found = columns(path)
    return missing(found, contract['required']), missing(found, contract['optional'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, default=Path(os.environ.get('HERMES_HOME', Path.home() / '.hermes')))
    args = parser.parse_args()
    contract = json.loads(CONTRACT.read_text())
    stores = sorted(args.home.glob('profiles/*/state.db')) + ([args.home / 'state.db'] if (args.home / 'state.db').is_file() else [])
    if not stores:
        print('Hermes 기록을 찾지 못했습니다.')
        return 1
    failed = False
    for store in stores:
        name = store.parent.name
        try:
            required, optional = check(store, contract)
        except sqlite3.Error as error:
            print(f'{name}: 열지 못함 ({type(error).__name__})')
            failed = True
            continue
        failed = failed or bool(required)
        print(f'{name}: ' + ('맞음' if not required and not optional else ' / '.join(
            part for part in ['없으면 안 되는 열 없음: ' + ', '.join(required) if required else '', '선택 열 없음: ' + ', '.join(optional) if optional else ''] if part)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
