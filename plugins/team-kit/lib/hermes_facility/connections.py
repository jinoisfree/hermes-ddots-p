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

from hermes_facility.app_registry import enabled as app_enabled

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


CONNECT_KIND = {'google': 'oauth', 'notion': 'secret', 'synology': 'secret', 'x': 'secret',
                'instagram': 'secret', 'slack': 'channel', 'photon': 'channel',
                'mail_read': 'mac_permission', 'notes_read': 'mac_permission',
                'calendar_read': 'mac_permission'}
# (first connection, change) button words of the secret connections.
SECRET_LABELS = {'notion': ('연결', '토큰 바꾸기'), 'synology': ('연결', '비밀번호 바꾸기'),
                 'x': ('연결', '로그인 값 바꾸기'), 'instagram': ('연결', '토큰 바꾸기')}
VERIFIED_RULES = ['마지막으로 직접 확인한 결과입니다. 확인은 읽기·로그인 확인만 하고 외부에 쓰지 않습니다.']


def action(identifier, label, primary=False):
    return dict(id=identifier, label=label, primary=primary)


def actions_for(row):
    """The only source of what a connection row offers; the app draws these and never infers its own."""
    state, reason, kind = row['state'], row['reason'], row['connect_kind']
    if state == 'off' or kind is None:
        return []
    check = action('check', '확인')
    if kind == 'oauth':
        if state in ('needs_reconnect', 'not_connected') and row['reconnect']:
            return [action('oauth_connect', '권한 업데이트' if reason == 'SCOPE_MISSING' else '다시 연결', True), check]
    elif kind == 'secret':
        first, change = SECRET_LABELS[row['service']]
        if state in ('needs_reconnect', 'not_connected'):
            return [action('secret_set', first if state == 'not_connected' else change, True), check]
        return [dict(check, primary=True), action('secret_set', change)]
    elif kind == 'channel':
        guide = [action('secret_set', '연결 안내')] if row['service'] == 'slack' else []
        # A revoked token is not fixed by a restart; the owner reinstalls the app in Slack.
        if state != 'connected' and not (state == 'needs_reconnect' and reason == 'TOKEN_INVALID'):
            return [action('gateway_restart', '다시 시작', True), check, *guide]
    elif kind == 'mac_permission':
        if reason == 'NOT_DETERMINED':
            return [action('permission_request', '권한 요청', True), check]
        if reason == 'PERMISSION_DENIED':
            return [action('open_settings', '시스템 설정', True), check]
    return [dict(check, primary=True), *([action('secret_set', '연결 안내')] if row['service']=='slack' else [])]


def event_time(stamp):
    return datetime.strptime(stamp.replace('T', ' '), '%Y-%m-%d %H:%M:%S').timestamp()


def apply_checks(rows, profile, records, events):
    """Last explicit check over the config-only state. Off wins, Google is always fresh, and a
    channel connected after the check (gateway restart) is not shadowed by it."""
    for row in rows:
        record = records.get(profile + '/' + row['id'])
        if row['state'] == 'off' or row['service'] == 'google' or not isinstance(record, dict):
            continue
        event = events.get((profile, row['service'])) if row['group'] == 'channel' else None
        if event and event_time(event) > record.get('at', 0):
            continue
        row.update(state=record['state'], reason=record['reason'], checked_at=record['checked_at'],
                   verified_by=record['verified_by'], rules=list(VERIFIED_RULES))
        if record.get('expires_at'):
            row['expires_at'] = record['expires_at']


class ConnectionContext:
    def __init__(self, root, profile, home, config, row):
        self.root, self.profile, self.home, self.config, self.row = root, profile, home, config, row
        self.settings = settings(config, 'team-kit')


def profile_contexts(root):
    root = Path(root)
    homes = [root] + sorted(p for p in (root / 'profiles').iterdir()
                            if p.is_dir() and not p.name.startswith('.')) if (root / 'profiles').is_dir() else [root]
    return [('default' if home == root else home.name, home, read_yaml(home / 'profile.yaml'), read_yaml(home / 'config.yaml'))
            for home in homes if (home / 'profile.yaml').is_file()]


def personal_accounts(root):
    scopes = settings(read_yaml(Path(root) / 'config.yaml'), 'team-kit').get('personal_scopes', {})
    return {key: scopes.get(key, {}).get('gmail') for key in ('personal', 'company')}


def connection_rows(root, profile, home, config, *, accounts, google, events, checked, common_names):
    kit, delegation = settings(config, 'team-kit'), settings(config, 'team-delegation')
    names = common_names | environment_names(home)
    rows = []

    def add(key, group, service, label, state, reason, *, scope=None, account=None,
            reconnect=None, capabilities=None, rules=None, timestamp=None, verified_by='config'):
        rows.append(dict(id=key, group=group, service=service, label=label, state=state,
                         reason=reason, checked_at=timestamp or checked, scope=scope,
                         account=account, reconnect=reconnect, connect_kind=CONNECT_KIND.get(service),
                         verified_by=verified_by,
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
            state, reason, scope=scope, account=accounts[scope], reconnect=scope, verified_by='google_check',
            capabilities=['메일·캘린더·Drive·Sheets·Docs·Slides의 연결 상태를 확인합니다.'],
            rules=['개인·회사 담당 범위를 유지합니다.', '발송·삭제 승인과 배경 쓰기 제한은 그대로입니다.'])
    for key, label in [('mail_read', 'Mail 앱'), ('notes_read', '메모'), ('calendar_read', '캘린더')]:
        if key in kit:
            enabled = app_enabled(kit[key])
            add(key, 'mac', key, label, 'unknown' if enabled else 'off',
                'MAC_PERMISSION_UNVERIFIED' if enabled else 'DISABLED',
                rules=['설정 상태만 확인했습니다. Hermes의 macOS 권한은 확인하지 못했습니다.'])
    notion = kit.get('notion')
    if notion is not None:
        enabled = app_enabled(notion)
        present = notion.get('token') in names
        add('notion', 'account', 'notion', 'Notion',
            ('connected' if present else 'not_connected') if enabled else 'off',
            'CONFIG_ONLY' if enabled else 'DISABLED',
            rules=['설정과 환경변수 존재만 확인합니다. 토큰 유효성은 검사하지 않습니다.'])
    files = kit.get('files', {})
    storage = files.get('synology')
    if storage is not None:
        enabled = app_enabled(files) and app_enabled(storage)
        present = all(storage.get(key) in names for key in ('user', 'password'))
        add('synology', 'account', 'synology', '시놀로지',
            ('connected' if present else 'not_connected') if enabled else 'off',
            'CONFIG_ONLY' if enabled else 'DISABLED',
            rules=['설정과 환경변수 존재만 확인합니다. 네트워크 연결은 검사하지 않습니다.'])
    if 'x_read' in kit:
        add('x', 'account', 'x', 'X', 'unknown' if app_enabled(kit['x_read']) else 'off', 'CONFIG_ONLY')
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
            ('GATEWAY_LOG' if event else 'NO_CONNECTION_EVENT') if enabled else 'DISABLED', timestamp=event,
            verified_by='gateway_log' if event else 'config')
    return rows


def find_connection(root, profile, connection):
    """One configured connection without any network call (Google states are placeholders)."""
    root = Path(root)
    placeholder = {key: ('unknown', 'CHECK_FAILED') for key in ('personal', 'company')}
    for name, home, metadata, config in profile_contexts(root):
        if name != profile:
            continue
        rows = connection_rows(root, name, home, config, accounts=personal_accounts(root), google=placeholder,
                               events=channel_events(root), checked=now(), common_names=environment_names(root))
        row = next((r for r in rows if r['id'] == connection), None)
        return ConnectionContext(root, name, home, config, row) if row else None
    return None


def connection_ids(root, profile):
    """Ids of the profile's enabled connections, or None when the profile does not exist."""
    root = Path(root)
    placeholder = {key: ('unknown', 'CHECK_FAILED') for key in ('personal', 'company')}
    for name, home, metadata, config in profile_contexts(root):
        if name == profile:
            return [r['id'] for r in connection_rows(root, name, home, config, accounts=personal_accounts(root),
                                                      google=placeholder, events=channel_events(root),
                                                      checked=now(), common_names=environment_names(root))
                    if r['state'] != 'off']
    return None


def inventory(root, runner=subprocess.run, *, google=None):
    """`google` replaces the live Google checks for callers that never show Google rows."""
    from hermes_facility import connection_checks as checks
    root = Path(root)
    profiles = profile_contexts(root)
    accounts = personal_accounts(root)
    if google is None:
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = {key: pool.submit(google_status, root, key, runner) for key in accounts}
            google = {key: f.result() for key, f in futures.items()}
    events, checked, records = channel_events(root), now(), checks.load_checks(root)
    common_names = environment_names(root)
    agents = []
    for profile, home, metadata, config in profiles:
        rows = connection_rows(root, profile, home, config, accounts=accounts, google=google,
                               events=events, checked=checked, common_names=common_names)
        apply_checks(rows, profile, records, events)
        for row in rows:
            if row['service'] == 'instagram' and row['state'] != 'off' and 'expires_at' not in row \
                    and (expires := checks.instagram_expiry(home)):
                row['expires_at'] = expires
            row['actions'] = actions_for(row)
        from hermes_facility import app_registry
        if app_registry.explicit(root, profile):
            from hermes_packs.mac_apps.catalog import load_catalog
            grants = app_registry.grants(root, profile, config)
            drift = app_registry.config_drift(root, profile, config)
            catalog = load_catalog()
            for bundle in sorted(grants | drift):
                entry = catalog.get(bundle, {})
                rows.append(dict(id='app-' + bundle, group='mac', service=entry.get('service') or 'mac_app',
                    label=bundle, state='unknown' if bundle in grants else 'off',
                    reason='CONFIG_DRIFT' if bundle in drift else 'APP_CONNECTED',
                    checked_at=checked, scope=None, account=None, reconnect=None,
                    connect_kind=None, verified_by='team_registry', actions=[],
                    capabilities=[entry.get('can_do', '')], rules=entry.get('rules', [])))
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
        result['next'] = dict(kind='oauth_connect',url=url,resume_key=account)
    return result


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    status = sub.add_parser('status')
    status.add_argument('--json', action='store_true', required=True)
    login = sub.add_parser('reconnect')
    login.add_argument('action', choices=['start', 'status'])
    login.add_argument('--account', choices=['company', 'personal'], required=True)
    login.add_argument('--json', action='store_true', required=True)
    apps = sub.add_parser('apps')
    apps.add_argument('--self', dest='self_id')
    apps.add_argument('--json', action='store_true', required=True)
    app = sub.add_parser('app')
    app.add_argument('action', choices=['connect', 'disconnect', 'undo'])
    app.add_argument('--profile', required=True)
    app.add_argument('--app', dest='bundle', required=True)
    app.add_argument('--account', action='append')
    app.add_argument('--scope', dest='scopes', action='append')
    app.add_argument('--default')
    app.add_argument('--values-stdin', action='store_true')
    app.add_argument('--resume', choices=['gateway_restart', 'permission_request', 'internet_accounts'])
    app.add_argument('--json', action='store_true', required=True)
    checking = sub.add_parser('check')
    checking.add_argument('--profile', required=True)
    target = checking.add_mutually_exclusive_group(required=True)
    target.add_argument('--connection')
    target.add_argument('--all', action='store_true')
    checking.add_argument('--json', action='store_true', required=True)
    secret = sub.add_parser('secret')
    secret.add_argument('action', choices=['guide', 'set', 'undo'])
    secret.add_argument('--profile', required=True)
    secret.add_argument('--connection', required=True)
    secret.add_argument('--manifest-stdin', action='store_true')
    secret.add_argument('--json', action='store_true', required=True)
    permission = sub.add_parser('permission')
    permission.add_argument('action', choices=['request', 'settings'])
    permission.add_argument('--profile', required=True)
    permission.add_argument('--connection', required=True)
    permission.add_argument('--json', action='store_true', required=True)
    gateway = sub.add_parser('gateway')
    gateway.add_argument('action', choices=['restart'])
    gateway.add_argument('--json', action='store_true', required=True)
    return parser


def run_command(root, args):
    if args.command == 'app':
        from hermes_facility import app_connect
        values = None
        if args.values_stdin:
            from hermes_facility.connection_secrets import MAX_STDIN_BYTES
            raw = sys.stdin.read(MAX_STDIN_BYTES + 1)
            if len(raw) > MAX_STDIN_BYTES: raise ValueError('VALUES_INVALID')
            values = json.loads(raw)
            if not isinstance(values, dict) or set(values) - {'api_base', 'link_host', 'user', 'password', 'token', 'vault', 'sync_root'}:
                raise ValueError('VALUES_INVALID')
            if any(not isinstance(v, str) or not v or len(v) > 4096 or any(ord(c) < 32 for c in v) for v in values.values()):
                raise ValueError('VALUES_INVALID')
        return app_connect.run(root, args.action, args.profile, args.bundle, account=args.account,
            scopes=args.scopes, default=args.default, values=values, resume=args.resume)
    if args.command == 'status':
        return inventory(root)
    if args.command == 'reconnect':
        return reconnect(root, args.action, args.account)
    if args.command == 'apps':
        from hermes_packs.mac_apps import discovery as connection_apps
        return connection_apps.installed_apps(root, self_id=args.self_id)
    if args.command == 'secret':
        from hermes_facility import connection_secrets as secrets
        if args.action == 'guide':
            manifest = json.loads(sys.stdin.read(100000)) if args.manifest_stdin else None
            if manifest is not None and not isinstance(manifest, dict): raise ValueError('MANIFEST_INVALID')
            return secrets.guide(root, args.profile, args.connection, manifest)
        if args.action == 'set':
            return secrets.set_secret(root, args.profile, args.connection)
        return secrets.undo_secret(root, args.profile, args.connection)
    if args.command == 'permission':
        from hermes_facility import connection_checks as checks
        return (checks.permission_request if args.action == 'request' else checks.permission_settings)(
            root, args.profile, args.connection)
    if args.command == 'gateway':
        from hermes_facility import gateway_restart
        return gateway_restart.restart(root)
    from hermes_facility import connection_checks
    if args.all:
        return connection_checks.check_all(root, args.profile, manual=True)
    return connection_checks.check(root, args.profile, args.connection, manual=True)


def main(root, argv=None):
    args = build_parser().parse_args(argv)
    try:
        value = run_command(root, args)
    except Exception:
        # No exception text, config fragments, raw auth output or paths leave the CLI.
        print(json.dumps(dict(error='CONNECTIONS_READ_FAILED')))
        return 1
    print(json.dumps(value, ensure_ascii=False))
    return 0
