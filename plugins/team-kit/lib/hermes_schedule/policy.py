"""Owner timing decisions, with the historical defaults only before installation."""
import os
from copy import deepcopy
from pathlib import Path
from .catalog import read

_CACHE: dict[str, tuple] = {}


def _policy(root=None):
    path = Path(root or root_home()) / 'owner/policy.yaml'
    try:
        stat = path.stat()
    except FileNotFoundError:
        _CACHE.pop(str(path), None)
        return {}
    stamp = (stat.st_mtime_ns, stat.st_size)
    cached = _CACHE.get(str(path))
    if cached and cached[0] == stamp:
        return cached[1]
    value = read(path)
    _CACHE[str(path)] = (stamp, value)
    return value


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
    """Read the current owner decision; a changed file invalidates the parsed value."""
    value = _policy(root)
    return deepcopy(value[name]) if name in value else default
