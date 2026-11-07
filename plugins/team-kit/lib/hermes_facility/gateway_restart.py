"""Owner-initiated gateway restart (REQ-05): refuse while a turn is running, at most once per hour,
and confirm every Slack/iMessage channel reconnected. Never retries on its own.

A turn is "running" when any profile's state.db holds an unexpired row in session_turn_leases —
the lease the gateway itself takes for the length of a conversation turn.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time

RESTART_INTERVAL_SECONDS = 3600
RECONNECT_SECONDS = 120
POLL_SECONDS = 2
RESTART_SECONDS = 90


def state_files(root):
    root = Path(root)
    return [root / 'state.db', *sorted((root / 'profiles').glob('*/state.db'))]


def running_turns(root, clock=time.time):
    """Number of unexpired turn leases, or None when a database cannot be read (fail closed)."""
    total = 0
    for path in state_files(root):
        if not path.is_file():
            continue
        try:
            with sqlite3.connect('file:%s?mode=ro' % path, uri=True, timeout=2) as db:
                total += db.execute('SELECT COUNT(*) FROM session_turn_leases WHERE expires_at > ?',
                                    (clock(),)).fetchone()[0]
        except sqlite3.OperationalError as error:
            if 'no such table' not in str(error):
                return None
        except sqlite3.Error:
            return None
    return total


def expected_channels(root):
    """(profile, service) pairs the gateway should connect: every enabled Slack/iMessage row."""
    from hermes_facility import connections
    pairs = []
    for profile in connections.profile_contexts(root):
        ids = connections.connection_ids(root, profile[0]) or []
        pairs += [(profile[0], i) for i in ids if i in ('slack', 'photon')]
    return pairs


def connected_after(log, offset):
    """Channels connected after the last gateway start marker in the log text added since offset."""
    try:
        with open(log, encoding='utf-8', errors='replace') as stream:
            stream.seek(offset)
            lines = stream.read().splitlines()
    except OSError:
        return None
    events, started = set(), False
    for line in lines:
        if 'Starting Hermes Gateway...' in line:
            events.clear()
            started = True
        match = re.search(r'✓ (slack|photon) connected(?: \(profile: ([A-Za-z0-9_-]+)\))?', line)
        if started and match:
            events.add((match[2] or 'default', match[1]))
    return events if started else None


def read_limit(root):
    try:
        return float(json.loads((Path(root) / 'state/connections/restart.json').read_text(encoding='utf-8'))['at'])
    except (OSError, ValueError, KeyError, TypeError):
        return None


def write_limit(root, at):
    path = Path(root) / 'state/connections/restart.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(dict(at=at)), encoding='utf-8')
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def restart(root, *, runner=subprocess.run, clock=time.time, sleep=time.sleep):
    root = Path(root)
    base = dict(action='gateway_restart')
    turns = running_turns(root, clock)
    if turns is None:
        return dict(base, outcome='refused', reason='BUSY_CHECK_FAILED')
    if turns:
        return dict(base, outcome='refused', reason='BUSY')
    last = read_limit(root)
    if last is not None and clock() - last < RESTART_INTERVAL_SECONDS:
        return dict(base, outcome='refused', reason='RATE_LIMITED', last_restart_at=last)
    expected = expected_channels(root)
    log = root / 'logs/gateway.log'
    offset = log.stat().st_size if log.is_file() else 0
    started = clock()
    write_limit(root, started)   # the attempt counts even when it fails; nothing retries it
    command = [str(root / 'hermes-agent/.hermes/bin/hermes'), '--profile', 'default', 'gateway', 'restart']
    try:
        answer = runner(command, capture_output=True, text=True, timeout=RESTART_SECONDS, check=False,
                        env={**os.environ, 'HERMES_HOME': str(root), 'HERMES_DISABLE_LAZY_INSTALLS': '1'})
    except subprocess.TimeoutExpired:
        return dict(base, outcome='failed', reason='RESTART_TIMEOUT', restarted_at=started)
    except OSError:
        return dict(base, outcome='failed', reason='RESTART_FAILED', restarted_at=started)
    if answer.returncode != 0:
        return dict(base, outcome='failed', reason='RESTART_FAILED', restarted_at=started)
    deadline = clock() + RECONNECT_SECONDS
    while True:
        events = connected_after(log, offset) or set()
        missing = [pair for pair in expected if pair not in events]
        if not missing:
            return dict(base, outcome='done', reason='OK', restarted_at=started, connected=len(expected))
        if clock() >= deadline:
            return dict(base, outcome='failed', reason='NOT_RECONNECTED', restarted_at=started,
                        connected=len(expected) - len(missing),
                        missing=[dict(profile=p, connection=c) for p, c in missing])
        sleep(POLL_SECONDS)
