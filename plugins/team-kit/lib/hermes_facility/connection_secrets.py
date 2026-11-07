"""Owner-initiated secret entry for the secret-kind connections (REQ-03).

A new value is read from stdin only, verified in memory through the same call
as `check`, and only then written to the profile's .env — its named lines and
nothing else. The previous value is kept 10 minutes for `secret undo`.
No value, hash or response text appears in any output or log.
Spec: docs/changes/AGENT-CONNECTIONS-CHECK-20261107/handoff.md (CK-08~13).
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import time

UNDO_SECONDS = 600
MAX_STDIN_BYTES = 16384
MAX_VALUE_LENGTH = 4096
X_VALUE = re.compile(r'[A-Za-z0-9%._~-]+')
SAFE_BARE = re.compile(r'[A-Za-z0-9_@%+=:,./-]+')

# field id -> fixed env name, or a pattern the configured name must match (CK-10)
FIELDS = {
    'notion': [('token', 'Integration 비밀값', True, re.compile('NOTION_API_KEY'))],
    'synology': [('user', 'DSM 사용자 이름', False, re.compile(r'SYNOLOGY_[A-Z0-9_]+')),
                 ('password', 'DSM 비밀번호', True, re.compile(r'SYNOLOGY_[A-Z0-9_]+'))],
    'x': [('auth_token', 'auth_token 쿠키 값', True, re.compile('X_AUTH_TOKEN')),
          ('ct0', 'ct0 쿠키 값', True, re.compile('X_CT0'))],
    'instagram': [('token', '장기 액세스 토큰', True, re.compile('INSTAGRAM_ACCESS_TOKEN'))]}
GUIDES = {
    'notion': dict(steps=['Notion의 "내 통합"에서 내부 통합을 만들고 비밀값(ntn_…)을 복사해요.',
                          '에이전트가 읽을 페이지에서 "연결"을 눌러 그 통합을 공유해요.'],
                   link='https://www.notion.com/profile/integrations'),
    'synology': dict(steps=['DSM 계정의 사용자 이름과 비밀번호를 입력해요.',
                            '2단계 인증을 쓰는 계정은 쓸 수 없어요.',
                            '로그인에 실패하면 한동안 다시 시도하지 않아요.'], link=None),
    'x': dict(steps=['x.com에 로그인한 브라우저의 개발자 도구 > 쿠키에서 auth_token과 ct0 값을 복사해요.',
                     '쿠키가 없어도 공개 글 읽기는 돼요.'], link='https://x.com'),
    'instagram': dict(steps=['Meta 개발자 대시보드에서 Instagram 장기 액세스 토큰을 발급해 복사해요.',
                             '저장하면 에이전트를 다시 시작해야 새 토큰을 써요.'],
                      link='https://developers.facebook.com/apps/')}
# Instagram's plugin keeps the .env value it loaded at gateway start (instagram-dm/__init__.py _token).
RESTART_REQUIRED = {'instagram'}


def store(root, name):
    return Path(root) / 'state/connections' / name


def now_iso(clock):
    return datetime.fromtimestamp(clock(), timezone.utc).isoformat()


def names_for(context):
    """field id -> env name, or None when the configured name is outside the allowed list."""
    service, kit = context.row['service'], context.settings
    configured = {'notion': {'token': kit.get('notion', {}).get('token')},
                  'synology': {k: kit.get('files', {}).get('synology', {}).get(k) for k in ('user', 'password')},
                  'x': {'auth_token': 'X_AUTH_TOKEN', 'ct0': 'X_CT0'},
                  'instagram': {'token': 'INSTAGRAM_ACCESS_TOKEN'}}[service]
    names = {}
    for field, _, _, allowed in FIELDS[service]:
        name = configured.get(field)
        if not isinstance(name, str) or not allowed.fullmatch(name):
            return None
        names[field] = name
    return names


def guide(root, profile, connection):
    from hermes_facility import connections
    context = connections.find_connection(root, profile, connection)
    if context is None or context.row['service'] not in FIELDS:
        return dict(action='secret_guide', profile=profile, connection=connection, outcome='refused',
                    reason='UNKNOWN_CONNECTION')
    spec = GUIDES[context.row['service']]
    return dict(action='secret_guide', profile=profile, connection=connection, outcome='done', reason='OK',
                fields=[dict(id=f, label=label, secure=secure) for f, label, secure, _ in FIELDS[context.row['service']]],
                guide=dict(steps=spec['steps'], link=spec['link']),
                restart_required=context.row['service'] in RESTART_REQUIRED)


def read_values(stream, fields):
    raw = stream.read(MAX_STDIN_BYTES + 1)
    if len(raw) > MAX_STDIN_BYTES:
        return None
    try:
        value = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(value, dict) or set(value) != set(fields):
        return None
    for text in value.values():
        if (not isinstance(text, str) or not 0 < len(text) <= MAX_VALUE_LENGTH
                or any(ord(ch) < 32 or ord(ch) == 127 for ch in text)):
            return None
    return value


def format_ok(service, values):
    if service == 'x':
        return all(X_VALUE.fullmatch(v) for v in values.values())
    if service in ('notion', 'instagram'):
        return all(not re.search(r'\s', v) for v in values.values())
    return True


def env_line(name, value, exported=False):
    text = value if SAFE_BARE.fullmatch(value) else "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"
    return ('export ' if exported else '') + name + '=' + text + '\n'


def rewrite_env(path, changes):
    """Replace/append/remove (value None) exactly the named lines. Atomic, 0600, never through a link."""
    if path.is_symlink():
        raise OSError('ENV_UNSAFE')
    lines = path.read_text(encoding='utf-8').splitlines(keepends=True) if path.exists() else []
    seen = set()
    result = []
    for line in lines:
        match = re.match(r'^(\s*export\s+)?([A-Za-z_][A-Za-z_0-9]*)\s*=', line)
        name = match[2] if match else None
        if name in changes and name not in seen:
            seen.add(name)
            if changes[name] is not None:
                result.append(env_line(name, changes[name], bool(match[1])))
        elif name in changes:
            continue  # a later duplicate of a changed name would shadow the new value
        else:
            result.append(line)
    if result and not result[-1].endswith('\n'):
        result[-1] += '\n'
    for name, value in changes.items():
        if name not in seen and value is not None:
            result.append(env_line(name, value))
    temporary = path.with_name(path.name + '.connections.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        stream.write(''.join(result))
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def current_values(path, names):
    from dotenv import dotenv_values
    try:
        env = dotenv_values(path, interpolate=False)
    except OSError:
        env = {}
    return {name: env.get(name) for name in names}


def purge_undo(root, clock=time.time):
    folder = store(root, 'undo')
    if not folder.is_dir():
        return
    for path in folder.glob('*.json'):
        try:
            expired = clock() - json.loads(path.read_text(encoding='utf-8')).get('saved_at', 0) >= UNDO_SECONDS
        except (OSError, ValueError, AttributeError):
            expired = True
        if expired:
            path.unlink(missing_ok=True)


def write_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        stream.write(value)


def history(root, entry):
    path = store(root, 'secret-history.jsonl')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, 'a', encoding='utf-8') as stream:
        stream.write(json.dumps(entry, ensure_ascii=False) + '\n')


def refused(base, reason):
    return dict(base, outcome='refused', reason=reason)


def set_secret(root, profile, connection, stream=None, *, opener=None, clock=time.time):
    from hermes_facility import connection_checks as checks, connections
    base = dict(action='secret_set', profile=profile, connection=connection)
    purge_undo(root, clock)
    context = connections.find_connection(root, profile, connection)
    if context is None or context.row['service'] not in FIELDS:
        return refused(base, 'UNKNOWN_CONNECTION')
    if context.row['state'] == 'off':
        return refused(base, 'OFF')
    service = context.row['service']
    names = names_for(context)
    if names is None:
        return refused(base, 'NAME_NOT_ALLOWED')
    values = read_values(stream or sys.stdin, names)
    if values is None or not format_ok(service, values):
        return refused(base, 'FORMAT_INVALID')
    env = {names[field]: value for field, value in values.items()}
    with checks.candidate_values(env):
        answer = checks.run_check(root, context, opener=opener or checks.default_opener(), runner=None,
                                  clock=clock, record=None, permission_judge=None)
    state, reason, method = answer[:3]
    if state != 'connected' or reason == 'PUBLIC_ONLY':
        return refused(base, reason if state != 'unknown' else ('TIMEOUT' if reason == 'NETWORK' else reason))
    path = Path(context.home) / '.env'
    previous = current_values(path, env)
    undo = store(root, 'undo') / (profile + '__' + connection + '.json')
    try:
        write_private(undo, json.dumps(dict(saved_at=clock(), previous=previous)))
        rewrite_env(path, env)
        if current_values(path, env) != env:
            rewrite_env(path, previous)
            return refused(base, 'WRITE_FAILED')
    except OSError:
        undo.unlink(missing_ok=True)
        return refused(base, 'WRITE_FAILED')
    history(root, dict(at=now_iso(clock), profile=profile, connection=connection, action='set',
                       names=sorted(env), had_previous={n: v is not None for n, v in previous.items()}))
    record = dict(state=state, reason=reason, verified_by=method, checked_at=now_iso(clock), at=clock())
    if service == 'instagram' and (expires := checks.instagram_expiry(context.home)):
        record['expires_at'] = expires
    checks.save_check(root, profile, connection, record)
    return dict(base, outcome='done', reason='OK', saved_names=sorted(env),
                restart_required=service in RESTART_REQUIRED, check=checks.public(record),
                undo_until=datetime.fromtimestamp(clock() + UNDO_SECONDS, timezone.utc).isoformat())


def undo_secret(root, profile, connection, *, clock=time.time):
    from hermes_facility import connection_checks as checks, connections
    base = dict(action='secret_undo', profile=profile, connection=connection)
    context = connections.find_connection(root, profile, connection)
    if context is None or context.row['service'] not in FIELDS:
        return refused(base, 'UNKNOWN_CONNECTION')
    path = store(root, 'undo') / (profile + '__' + connection + '.json')
    try:
        saved = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        purge_undo(root, clock)
        return refused(base, 'NO_UNDO')
    if clock() - saved.get('saved_at', 0) >= UNDO_SECONDS:
        path.unlink(missing_ok=True)
        return refused(base, 'EXPIRED')
    previous = saved['previous']
    names = names_for(context)
    if names is None or set(previous) != set(names.values()):
        return refused(base, 'NAME_NOT_ALLOWED')
    try:
        rewrite_env(Path(context.home) / '.env', previous)
    except OSError:
        return refused(base, 'WRITE_FAILED')
    path.unlink(missing_ok=True)
    history(root, dict(at=now_iso(clock), profile=profile, connection=connection, action='undo', names=sorted(previous)))
    checks.forget_check(root, profile, connection)
    return dict(base, outcome='done', reason='OK', saved_names=sorted(previous),
                restart_required=context.row['service'] in RESTART_REQUIRED)
