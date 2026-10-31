"""Fixed watchers entrypoints. Configuration is data, never a shell fragment."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit
import importlib.util as _ilu, pathlib as _pl, sys as _sys
team = _sys.modules.get('hermes_team_registry')
if team is None:
    _spec = _ilu.spec_from_file_location('hermes_team_registry', _pl.Path(__file__).with_name('team_registry.py'))
    team = _sys.modules['hermes_team_registry'] = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(team)

SCRIPTS = {'watch-rss.py': 'rss', 'watch-github.py': 'github', 'watch-http-json.py': 'http_json'}


def arguments(kind, item):
    if kind not in SCRIPTS.values() or not isinstance(item, dict):
        raise ValueError('invalid watcher')
    allowed = {'name', 'max', 'timeout'} | ({'repo', 'scope'} if kind == 'github' else {'url'})
    if kind == 'http_json':
        allowed |= {'id-field', 'items-path', 'title-field', 'url-field', 'body-field'}
    if set(item) - allowed or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', str(item.get('name', ''))):
        raise ValueError('invalid watcher keys/name')
    if kind == 'github':
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', str(item.get('repo', ''))):
            raise ValueError('invalid repository')
        if item.get('scope', 'issues') not in {'issues', 'pulls', 'releases', 'commits'}:
            raise ValueError('invalid scope')
    else:
        url = urlsplit(str(item.get('url', '')))
        if url.scheme not in {'https', 'http'} or not url.hostname or url.username or url.password:
            raise ValueError('public HTTP(S) URL required')
        from tools.url_safety import is_safe_url
        if not is_safe_url(item['url']):
            raise ValueError('unsafe URL')
    result = []
    for key, value in item.items():
        if not isinstance(value, (str, int, float)) or isinstance(value, bool) or len(str(value)) > 2048:
            raise ValueError('invalid argument')
        if key in {'max', 'timeout'} and not 1 <= float(value) <= (50 if key == 'max' else 60):
            raise ValueError('argument outside bounds')
        result += ['--' + key, str(value)]
    return result


def run(kind):
    home = team.home_of_role('doctor', Path.home() / '.hermes')
    config = home / 'workspace/watchers' / (kind + '.json')
    if config.is_symlink() or config.stat().st_size > 32768:
        raise ValueError('invalid watcher configuration')
    items = json.loads(config.read_text())
    if not isinstance(items, list) or not 1 <= len(items) <= 10:
        raise ValueError('configure 1..10 watchers')
    calls = [arguments(kind, item) for item in items]
    script = home / 'skills/devops/watchers/scripts' / ('watch_' + kind + '.py')
    import importlib.util
    import shlex
    from hermes_governance import selected_skills as sandbox
    for args in calls:
        # State location is non-secret, fixed by the trusted runner, never inherited.
        inner = ['/usr/bin/env', 'WATCHER_STATE_DIR=' + str(home/'watcher-state'),
                 'python', str(script), *args]
        subprocess.run(sandbox.sandbox_argv(team.first_with('doctor'), shlex.join(inner)),
                       cwd=home/'workspace', check=True, timeout=90)
