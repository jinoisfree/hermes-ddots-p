"""Owner timing decisions, with the historical defaults only before installation."""
import os
from pathlib import Path
from .catalog import read


def root_home():
    return Path(os.environ.get('HERMES_ROOT') or Path.home() / '.hermes')


def clock(key, default, root=None):
    path = Path(root or root_home()) / 'owner/policy.yaml'
    if not path.exists(): return default
    value = read(path)['time_policy'][key]
    if not isinstance(value, str) or len(value) != 5 or value[2] != ':':
        raise ValueError('invalid owner time policy')
    hour, minute = map(int, value.split(':'))
    if not 0 <= hour < 24 or not 0 <= minute < 60:
        raise ValueError('invalid owner time policy')
    return hour, minute


def section(name, default=None, root=None):
    """Read an owner decision directly; absent sections do not enable a feature."""
    path = Path(root or root_home()) / 'owner/policy.yaml'
    return read(path).get(name, default) if path.exists() else default
