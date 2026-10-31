"""Read-only checks for private state placement; never print ledger contents."""
import json
from pathlib import Path
import sqlite3

RUNTIME_KEYS = frozenset({'last_run_at', 'next_run_at', 'last_status', 'last_error',
    'last_delivery_error', 'failure_streak', 'fire_claim', 'last_dispatch', 'pending_slot',
    'paused_at', 'created_at', 'updated_at', 'completed_at', 'quota_hold_until', 'manual_run_prompt'})


def read(path):
    text = Path(path).read_text()
    try:
        return json.loads(text)
    except ValueError:
        from ruamel.yaml import YAML
        parser = YAML(typ='safe')
        parser.version = (1, 1)
        return parser.load(text)


def state_keys(value, prefix=''):
    found = []
    if isinstance(value, dict):
        for key, child in value.items():
            route = f'{prefix}.{key}' if prefix else str(key)
            if key in RUNTIME_KEYS: found.append(route)
            found.extend(state_keys(child, route))
    elif isinstance(value, list):
        for child in value: found.extend(state_keys(child, prefix + '[]'))
    return found


def inspect(root):
    root = Path(root).resolve()
    schema = read(root / 'schemas/shared-ledgers.json')
    if schema.get('version') != 1: raise ValueError('unsupported state layout version')
    issues = []
    checked = 0
    for entry in schema['entries']:
        relative = Path(entry['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('invalid ledger path')
        path = root / relative
        if root not in path.resolve().parents:
            issues.append({'path': str(relative), 'reason': 'outside_home'})
            continue
        if not path.exists():
            if not entry.get('optional'): issues.append({'path': str(relative), 'reason': 'missing'})
            continue
        checked += 1
        try:
            if entry['kind'] == 'directory':
                if not path.is_dir(): raise ValueError('not_directory')
            elif entry['kind'] == 'json':
                value = json.loads(path.read_text())
                if not isinstance(value, dict) or set(entry['required_keys']) - value.keys():
                    raise ValueError('invalid_shape')
            elif entry['kind'] == 'sqlite':
                with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=2) as db:
                    db.execute('PRAGMA query_only=ON')
                    for table, columns in entry['tables'].items():
                        if not table.isidentifier(): raise ValueError('invalid_table')
                        actual = {row[1] for row in db.execute(f'PRAGMA table_info("{table}")')}
                        if set(columns) - actual: raise ValueError('missing_columns')
            else: raise ValueError('unknown_kind')
        except (ValueError, OSError, sqlite3.Error):
            issues.append({'path': str(relative), 'reason': 'schema_mismatch'})
    configs = []
    for home in [root, *sorted((root / 'profiles').glob('*'))]:
        config = home / 'config.yaml'
        if not config.exists(): continue
        value = read(config)
        configs.append(config)
        for key in state_keys(value):
            issues.append({'path': str(config.relative_to(root)), 'reason': 'runtime_field', 'field': key})
        enabled = (value.get('memory') or {}).get('user_profile_enabled', True)
        user = home / 'memories/USER.md'
        shared = root / 'memories/USER.md'
        if home != root:
            if enabled and (not user.is_symlink() or user.resolve() != shared.resolve() or not shared.is_file()):
                issues.append({'path': str(user.relative_to(root)), 'reason': 'shared_user_link_missing'})
            elif not enabled and user.is_symlink():
                issues.append({'path': str(user.relative_to(root)), 'reason': 'external_profile_user_link'})
    return {'ledgers_checked': checked, 'configs_checked': len(configs), 'issues': issues}
