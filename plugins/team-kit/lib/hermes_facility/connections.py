"""Read-only connection inventory and owner-initiated Google reconnect CLI.

Display policy: docs/연결-상태.md and
docs/changes/AGENT-CONNECTIONS-20261107/handoff.md. Never emit raw errors.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

# Identical to the existing auth CLI. A source-contract test detects drift.
CONFIG_PATTERN = r'(        personal_scopes:\n[\s\S]*?          personal:\n[\s\S]*?            connected:) false(?=\n          company:)'
CONFIG_MARKER = '            connected: true\n          company:'


def reconnect_preflight(root):
    """Fail closed before starting personal login; no writes."""
    try:
        text = (Path(root) / 'config.yaml').read_text(encoding='utf-8')
    except (OSError, UnicodeError):
        return 'CONFIG_MARKER_MISSING'
    if re.search(CONFIG_PATTERN, text):
        return 'CONFIG_WOULD_CHANGE'
    return None if CONFIG_MARKER in text else 'CONFIG_MARKER_MISSING'


def read_yaml(path):
    from ruamel.yaml import YAML
    value = YAML(typ='safe').load(path.read_text(encoding='utf-8'))
    return value if isinstance(value, dict) else {}


def now():
    return datetime.now(timezone.utc).isoformat()


def google_status(root, account, runner=subprocess.run):
    try:
        result = runner([sys.executable, str(Path(root) / 'bin/hermes-personal-google-auth'),
                         '--account', account, '--check'], capture_output=True, text=True,
                        timeout=15, check=False,
                        env={**os.environ, 'HERMES_DISABLE_LAZY_INSTALLS': '1',
                             'PYTHONDONTWRITEBYTECODE': '1'})
    except subprocess.TimeoutExpired:
        return 'unknown', 'TIMEOUT'
    except OSError:
        return 'unknown', 'CHECK_FAILED'
    if result.returncode == 0:
        return 'connected', 'GOOGLE_VERIFIED'
    if re.search(r'\b(?:PERSONAL|COMPANY)_SCOPE_MISSING\b', result.stderr):
        return 'needs_reconnect', 'SCOPE_MISSING'
    if re.search(r'\b(?:PERSONAL|COMPANY)_ACCOUNT_NOT_CONNECTED\b', result.stderr):
        return 'not_connected', 'NOT_CONNECTED'
    return 'unknown', 'CHECK_FAILED'


def environment_names(home):
    """Only variable presence crosses this boundary; never retain values."""
    names = {k for k, v in os.environ.items() if v}
    path = home / '.env'
    if path.is_file():
        for line in path.read_text(encoding='utf-8').splitlines():
            match = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(.*?)\s*$', line)
            if match and match[2].strip('\"\''):
                names.add(match[1])
    return names


def channel_events(root):
    path = root / 'logs/gateway.log'
    events = {}
    if not path.is_file():
        return events
    # A startup marker invalidates all earlier success lines. No raw log escapes.
    with path.open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            if 'Starting Hermes Gateway...' in line:
                events.clear()
            match = re.search(r'✓ (slack|photon) connected(?: \(profile: ([A-Za-z0-9_-]+)\))?', line)
            stamp = re.search(r'\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}', line)
            if match and stamp:
                events[(match[2] or 'default', match[1])] = stamp[0]
    return events


def settings(config, plugin):
    return config.get('plugins', {}).get('entries', {}).get(plugin, {}).get('settings', {})


def inventory(root, runner=subprocess.run):
    root = Path(root)
    homes = [root] + sorted(p for p in (root / 'profiles').iterdir()
                            if p.is_dir() and not p.name.startswith('.')) if (root / 'profiles').is_dir() else [root]
    profiles = []
    for home in homes:
        if not (home / 'profile.yaml').is_file():
            continue
        profile = 'default' if home == root else home.name
        profiles.append((profile, home, read_yaml(home / 'profile.yaml'), read_yaml(home / 'config.yaml')))
    scopes = settings(read_yaml(root / 'config.yaml'), 'team-kit').get('personal_scopes', {})
    accounts = {key: scopes.get(key, {}).get('gmail') for key in ('personal', 'company')}
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = {key: pool.submit(google_status, root, key, runner) for key in accounts}
        google = {key: f.result() for key, f in futures.items()}
    events, checked = channel_events(root), now()
    common_names = environment_names(root)
    agents = []
    for profile, home, metadata, config in profiles:
        kit, delegation = settings(config, 'team-kit'), settings(config, 'team-delegation')
        names = common_names | environment_names(home)
        rows = []

        def add(key, group, service, label, state, reason, *, scope=None, account=None,
                reconnect=None, capabilities=None, rules=None, timestamp=None):
            rows.append(dict(id=key, group=group, service=service, label=label, state=state,
                             reason=reason, checked_at=timestamp or checked, scope=scope,
                             account=account, reconnect=reconnect,
                             capabilities=capabilities or ['설정된 연결 상태를 확인합니다.'],
                             rules=rules or ['이 화면에서는 연결 설정을 바꾸지 않습니다.']))

        gmail = delegation.get('gmail', kit.get('gmail'))
        selected = []
        if gmail is not None:
            value = gmail.get('account')
            selected = [key for key, email in accounts.items() if email and value in (email, email.split('@')[0])]
            if not selected:
                add('google', 'account', 'google', 'Google', 'unknown', 'ACCOUNT_UNMAPPED')
        for scope in selected:
            state, reason = google[scope]
            add('google-' + scope, 'account', 'google', 'Google ' + ('개인' if scope == 'personal' else '회사'),
                state, reason, scope=scope, account=accounts[scope], reconnect=scope,
                capabilities=['메일·캘린더·Drive·Sheets·Docs·Slides의 연결 상태를 확인합니다.'],
                rules=['개인·회사 담당 범위를 유지합니다.', '발송·삭제 승인과 배경 쓰기 제한은 그대로입니다.'])
        for key, label in [('mail_read', 'Mail 앱'), ('notes_read', '메모'), ('calendar_read', '캘린더')]:
            if key in kit:
                enabled = kit[key].get('enabled', True)
                add(key, 'mac', key, label, 'unknown' if enabled else 'off',
                    'MAC_PERMISSION_UNVERIFIED' if enabled else 'DISABLED',
                    rules=['설정 상태만 확인했습니다. Hermes의 macOS 권한은 확인하지 못했습니다.'])
        notion = kit.get('notion')
        if notion is not None:
            enabled = notion.get('enabled', True)
            present = notion.get('token') in names
            add('notion', 'account', 'notion', 'Notion',
                ('connected' if present else 'not_connected') if enabled else 'off',
                'CONFIG_ONLY' if enabled else 'DISABLED',
                rules=['설정과 환경변수 존재만 확인합니다. 토큰 유효성은 검사하지 않습니다.'])
        files = kit.get('files', {})
        storage = files.get('synology')
        if storage is not None:
            enabled = files.get('enabled', True) and storage.get('enabled', True)
            present = all(storage.get(key) in names for key in ('user', 'password'))
            add('synology', 'account', 'synology', '시놀로지',
                ('connected' if present else 'not_connected') if enabled else 'off',
                'CONFIG_ONLY' if enabled else 'DISABLED',
                rules=['설정과 환경변수 존재만 확인합니다. 네트워크 연결은 검사하지 않습니다.'])
        if 'x_read' in kit:
            add('x', 'account', 'x', 'X', 'unknown' if kit['x_read'].get('enabled', True) else 'off', 'CONFIG_ONLY')
        entries = config.get('plugins', {}).get('entries', {})
        if 'instagram-dm' in entries:
            add('instagram', 'account', 'instagram', 'Instagram',
                'unknown' if entries['instagram-dm'].get('enabled', True) else 'off', 'CONFIG_ONLY',
                rules=['기존 자동 답장·알림 설정을 유지합니다. 이 화면은 로그인 유효성을 확인하지 않습니다.'])
        for key, value in config.get('platforms', {}).items():
            if key not in ('slack', 'photon') or not isinstance(value, dict):
                continue
            enabled = value.get('enabled', True)
            event = events.get((profile, key))
            add(key, 'channel', key, 'Slack' if key == 'slack' else 'iMessage',
                ('connected' if event else 'unknown') if enabled else 'off',
                ('GATEWAY_LOG' if event else 'NO_CONNECTION_EVENT') if enabled else 'DISABLED', timestamp=event)
        agents.append(dict(profile=profile, display_name=metadata.get('display_name') or profile,
                           connections=rows))
    return dict(schema='hermes-connections/1', checked_at=checked, agents=agents)


def reconnect(root, action, account, *, runner=subprocess.run, popen=subprocess.Popen):
    if account not in ('company', 'personal') or action not in ('start', 'status'):
        return dict(state='refused', reason='INVALID_ARGUMENTS')
    if action == 'start' and account == 'personal' and (reason := reconnect_preflight(root)):
        return dict(state='refused', reason=reason)
    from hermes_facility import team_registry as team
    from hermes_packs.mail import google_reauth as auth
    folder = team.home_of_role('work' if account == 'company' else 'personal', root) / 'state/google-reauth'
    if folder.parent.parent.name.startswith('(no-'):
        return dict(state='refused', reason='PROFILE_MISSING')
    # Reconnect and the existing Slack tool share account verification as well as
    # the worker. The CLI's shorter deadline stays at its subprocess boundary.
    def bounded_runner(command, **kwargs):
        return runner(command, **{**kwargs, 'timeout': 15})
    checked = auth.check(Path(root) / 'bin/hermes-personal-google-auth', bounded_runner, account=account)
    error = checked.get('error', '')
    verified = (('connected', 'GOOGLE_VERIFIED') if checked.get('ok') else
                ('needs_reconnect', 'SCOPE_MISSING') if error.endswith('_SCOPE_MISSING') else
                ('not_connected', 'NOT_CONNECTED') if error.endswith('_ACCOUNT_NOT_CONNECTED') else
                ('unknown', 'TIMEOUT') if error.endswith('TimeoutExpired') else ('unknown', 'CHECK_FAILED'))
    with auth.locked(folder):
        state = auth.read_state(folder)
        running = auth.alive(state)
        if running and time.time() - state.get('started_at', 0) >= 900:
            return dict(state='timeout', reason='TIMEOUT', account=account)
        if action == 'start' and not running and verified[0] != 'connected':
            proc = popen([sys.executable, '-B', str(Path(auth.__file__).resolve()), '--worker',
                          str(folder), str(Path(root) / 'bin/hermes-personal-google-auth'), account],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, env={**os.environ, 'HERMES_DISABLE_LAZY_INSTALLS': '1',
                                                      'PYTHONDONTWRITEBYTECODE': '1'})
            state = dict(status='running', pid=proc.pid, started_at=time.time())
            auth.write_state(folder, state)
            running = True
    if action == 'start' and running:
        # The shared worker prints its URL asynchronously. Match the existing tool's
        # bounded wait, outside the lock so the worker can publish it.
        for _ in range(50):
            with auth.locked(folder):
                state = auth.read_state(folder)
            if state.get('url') or state.get('status') != 'running':
                break
            time.sleep(0.1)
        running = auth.alive(state)
    result = dict(state='connected' if verified[0] == 'connected' else
                  ('running' if running else state.get('status', 'not_started')),
                  reason=verified[1], account=account, exit_code=state.get('exit_code'),
                  check=dict(state=verified[0], reason=verified[1]))
    if running and (url := auth.login_url(state.get('url', ''))):
        result['url'] = url
    return result


def main(root, argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    status = sub.add_parser('status')
    status.add_argument('--json', action='store_true', required=True)
    login = sub.add_parser('reconnect')
    login.add_argument('action', choices=['start', 'status'])
    login.add_argument('--account', choices=['company', 'personal'], required=True)
    login.add_argument('--json', action='store_true', required=True)
    args = parser.parse_args(argv)
    try:
        value = inventory(root) if args.command == 'status' else reconnect(root, args.action, args.account)
    except Exception:
        # No exception text, config fragments, raw auth output or paths leave the CLI.
        print(json.dumps(dict(error='CONNECTIONS_READ_FAILED')))
        return 1
    print(json.dumps(value, ensure_ascii=False))
    return 0
