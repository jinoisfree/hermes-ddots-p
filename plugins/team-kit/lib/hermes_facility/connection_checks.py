"""Explicit one-shot connection checks and their last-result store.

Spec: docs/changes/AGENT-CONNECTIONS-CHECK-20261107/handoff.md (REQ-01).
Each check makes one real read-only call through the module the agents already
use, keeps only a state and a reason code, and writes only checks.json.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request

THROTTLE_SECONDS = 30
CHECK_SECONDS = 15
PARALLEL_CHECKS = 4
SYNOLOGY_AUTH_CODES = range(400, 411)
SYNOLOGY_AUTH_COOLDOWN = 1800
SYNOLOGY_TRANSPORT_COOLDOWN = 60
X_PROBE_URL = 'https://syndication.twitter.com/srv/timeline-profile/screen-name/X'
SLACK_AUTH_URL = 'https://slack.com/api/auth.test'

VERIFIED_BY = {'notion': 'notion_users_me', 'synology': 'synology_login', 'instagram': 'instagram_me',
               'slack': 'slack_auth_test', 'photon': 'gateway_log', 'mail_read': 'mac_permission',
               'notes_read': 'mac_permission', 'calendar_read': 'mac_permission', 'google': 'google_check'}


def store_folder(root):
    return Path(root) / 'state/connections'


def checks_path(root):
    return store_folder(root) / 'checks.json'


def _private_folder(path):
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


@contextmanager
def _locked(path, blocking=True):
    _private_folder(path.parent)
    stream = open(path, 'a+')
    try:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        stream.close()


def load_checks(root):
    try:
        value = json.loads(checks_path(root).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}
    return value.get('records', {}) if isinstance(value, dict) and isinstance(value.get('records'), dict) else {}


def write_records(path, records):
    temporary = path.with_name('checks.json.tmp')
    temporary.write_text(json.dumps(dict(schema='hermes-connection-checks/1', records=records),
                                    ensure_ascii=False), encoding='utf-8')
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def save_check(root, profile, connection, record):
    """Last result only; the single file this module writes. Atomic and 0600."""
    path = checks_path(root)
    with _locked(path.with_name('checks.lock')):
        records = load_checks(root)
        records[profile + '/' + connection] = record
        write_records(path, records)


def stamp(clock):
    moment = datetime.fromtimestamp(clock(), timezone.utc)
    return moment.isoformat()


def forget_check(root, profile, connection):
    path = checks_path(root)
    with _locked(path.with_name('checks.lock')):
        records = load_checks(root)
        if records.pop(profile + '/' + connection, None) is not None:
            write_records(path, records)


@contextmanager
def candidate_values(values):
    """Judge a not-yet-saved value through the very readers the agents use, without writing it anywhere.
    Process-wide patch of the three readers; only the one-shot CLI process uses it."""
    import dotenv
    from hermes_packs.notion import api
    from hermes_packs.sns import x_read
    real = dotenv.dotenv_values, api.token, x_read.profile_cookie
    dotenv.dotenv_values = lambda *a, **k: {**real[0](*a, **k), **values}
    api.token = lambda home: values.get('NOTION_API_KEY') or real[1](home)
    x_read.profile_cookie = lambda home: (('auth_token=%s; ct0=%s' % (values['X_AUTH_TOKEN'], values['X_CT0']))
                                          if 'X_AUTH_TOKEN' in values else real[2](home))
    try:
        yield
    finally:
        dotenv.dotenv_values, api.token, x_read.profile_cookie = real


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # A credential is never forwarded to a redirect target.


def default_opener():
    return urllib.request.build_opener(NoRedirect()).open


def json_call(opener, request, timeout=CHECK_SECONDS):
    """(status, parsed body or None). Transport failure raises OSError; no body text escapes."""
    try:
        with opener(request, timeout=timeout) as response:
            status, raw = getattr(response, 'status', 200), response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise OSError(type(error).__name__) from None
    try:
        body = json.loads(raw.decode('utf-8'))
    except (ValueError, UnicodeError, AttributeError):
        body = None
    return status, body if isinstance(body, dict) else None


def env_value(home, name):
    from dotenv import dotenv_values
    try:
        return dotenv_values(Path(home) / '.env', interpolate=False).get(name) or ''
    except OSError:
        return ''


# ---- one function per connection: (state, reason, verified_by[, extra]) ----

def check_google(root, scope, runner):
    from hermes_facility.connections import google_status
    return (*google_status(root, scope, runner), 'google_check')


def check_notion(home, opener):
    from hermes_packs.notion import api
    if not api.token(home):
        return 'not_connected', 'NO_TOKEN', 'notion_users_me'
    try:
        api.request(home, 'GET', 'users/me', opener=opener, timeout=CHECK_SECONDS)
    except api.UnknownChange:
        return 'unknown', 'NETWORK', 'notion_users_me'
    except api.NotionError as error:
        code = getattr(error, 'code', None)
        if code == 401:
            return 'needs_reconnect', 'TOKEN_INVALID', 'notion_users_me'
        reason = 'RATE_LIMITED' if code == 429 else 'SERVER_ERROR' if isinstance(code, int) and code >= 500 else 'CHECK_FAILED'
        return 'unknown', reason, 'notion_users_me'
    return 'connected', 'NOTION_VERIFIED', 'notion_users_me'


def check_x(home, opener):
    from hermes_packs.sns import x_read
    try:
        cookie = x_read.profile_cookie(home)
    except x_read.ReadError:
        return 'needs_reconnect', 'FORMAT_INVALID', 'x_cookie'
    method = 'x_cookie' if cookie else 'x_public'
    try:
        x_read.request(X_PROBE_URL, opener=opener, cookie=cookie)
    except x_read.ReadError as error:
        if error.code == 'login_required':
            return 'needs_reconnect', 'COOKIE_EXPIRED', method
        reason = {'rate_limited': 'RATE_LIMITED', 'network_error': 'NETWORK'}.get(error.code, 'CHECK_FAILED')
        return 'unknown', reason, method
    return 'connected', 'X_COOKIE_VERIFIED' if cookie else 'PUBLIC_ONLY', method


def instagram_module(home, profile):
    """The profile's own plugin file supplies GRAPH_BASE and the token name; nothing is copied here."""
    import importlib.util
    import sys
    path = Path(home) / 'plugins/instagram-dm/__init__.py'
    name = 'hermes_connections_instagram_' + re.sub(r'\W', '_', str(profile))
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path, submodule_search_locations=[str(path.parent)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def instagram_expiry(home):
    try:
        value = json.loads((Path(home) / 'state/instagram-dm-token.json').read_text(encoding='utf-8')).get('expires_at')
    except (OSError, ValueError, AttributeError):
        return None
    return datetime.fromtimestamp(value, timezone.utc).isoformat() if type(value) in (int, float) else None


def instagram_probe(plugin, token, opener):
    """GET /me?fields=id with the bearer header (same call shape as the plugin's own account lookup)."""
    request = urllib.request.Request(plugin.GRAPH_BASE + '/me?fields=id', method='GET',
                                     headers={'Authorization': 'Bearer ' + token})
    return json_call(opener, request, CHECK_SECONDS)


def check_instagram(home, plugin, opener):
    token = env_value(home, plugin.TOKEN_ENV)
    if not token:
        return 'not_connected', 'NO_TOKEN', 'instagram_me'
    try:
        status, body = instagram_probe(plugin, token, opener)
    except OSError:
        return 'unknown', 'NETWORK', 'instagram_me'
    if status == 200:
        return 'connected', 'INSTAGRAM_VERIFIED', 'instagram_me'
    if isinstance((body or {}).get('error'), dict) and body['error'].get('code') == 190:
        return 'needs_reconnect', 'TOKEN_INVALID', 'instagram_me'
    return 'unknown', 'RATE_LIMITED' if status == 429 else 'CHECK_FAILED', 'instagram_me'


def check_slack(home, opener):
    token = env_value(home, 'SLACK_BOT_TOKEN')
    if not token:
        return 'not_connected', 'NO_TOKEN', 'slack_auth_test'
    request = urllib.request.Request(SLACK_AUTH_URL, data=b'', method='POST',
                                     headers={'Authorization': 'Bearer ' + token})
    try:
        _, body = json_call(opener, request, CHECK_SECONDS)
    except OSError:
        return 'unknown', 'NETWORK', 'slack_auth_test'
    if (body or {}).get('ok') is True:
        return 'connected', 'SLACK_VERIFIED', 'slack_auth_test'
    if (body or {}).get('error') in ('invalid_auth', 'token_revoked'):
        return 'needs_reconnect', 'TOKEN_INVALID', 'slack_auth_test'
    return 'unknown', 'CHECK_FAILED', 'slack_auth_test'


def check_photon(root, profile):
    from hermes_facility.connections import channel_events
    return (('connected', 'GATEWAY_LOG', 'gateway_log') if channel_events(Path(root)).get((profile, 'photon'))
            else ('unknown', 'NO_CONNECTION_EVENT', 'gateway_log'))


def synology_credential_digest(home, settings):
    """Compare credential pairs without storing either value or ambiguous joins."""
    values = [env_value(home, settings.get(key)) if settings.get(key) else '' for key in ('user', 'password')]
    if not all(values):
        return None
    return hashlib.sha256(json.dumps(values, ensure_ascii=True).encode('utf-8')).hexdigest()


def synology_cooldown(record, credential_digest, now):
    # Old failures have no credential identity. Keep their original deadline.
    return bool(record and record.get('retry_after', 0) > now and
                (not record.get('credential_digest') or record['credential_digest'] == credential_digest))


def synology_error_category(code):
    # SYNO.API.Auth codes: DSM Login Web API Guide, API Error Codes.
    if code == 400: return 'CREDENTIALS'
    if code in (403, 404, 406): return 'TWO_FACTOR'
    if code in (401, 407): return 'BLOCKED'
    if code in SYNOLOGY_AUTH_CODES: return 'AUTH_OTHER'
    return 'CONNECTION'


def synology_failure_hint(category):
    message = {'CREDENTIALS': '아이디나 비밀번호가 맞지 않아요.',
               'TWO_FACTOR': 'NAS에서 2단계 인증이 필요해요. NAS의 로그인 설정을 확인해 주세요.',
               'BLOCKED': 'NAS 계정 또는 접속 IP가 차단됐어요. NAS의 차단 상태를 확인해 주세요.',
               'CONNECTION': 'NAS 주소나 연결 상태를 확인해 주세요.',
               'AUTH_OTHER': 'NAS 계정의 로그인 조건이나 비밀번호 변경 필요 여부를 확인해 주세요.'
               }.get(category, '이전 NAS 로그인 확인에 실패했어요.')
    return message


def check_synology(home, settings, opener, clock, record, *, manual=False):
    """Login then logout once. A recorded failure keeps its wait (files.py cooldown rules)."""
    from hermes_packs.files_docs import files
    credential_digest = synology_credential_digest(home, settings)
    if credential_digest is None:
        return 'not_connected', 'NO_TOKEN', 'synology_login'
    if not manual and synology_cooldown(record, credential_digest, clock()):
        return record['state'], record['reason'], 'synology_login', dict(note='COOLDOWN', retry_after=record['retry_after'],
            error_category=record.get('error_category', 'UNKNOWN'),
            **({'credential_digest': record['credential_digest']} if record.get('credential_digest') else {}))
    import time
    deadline = time.monotonic() + CHECK_SECONDS
    session = {'sid': None, 'cooldown': 0}
    base = str(settings.get('api_base', '')).rstrip('/')
    try:
        files._nas_api(base, {'api': 'SYNO.API.Info', 'version': 1, 'method': 'query',
                              'query': 'SYNO.API.Auth'}, opener, deadline)
        files._nas_login(base, settings, Path(home), session, opener, deadline)
    except files._NasError as error:
        if error.code in SYNOLOGY_AUTH_CODES:
            return ('needs_reconnect', 'AUTH_FAILED', 'synology_login',
                    dict(retry_after=clock() + SYNOLOGY_AUTH_COOLDOWN, credential_digest=credential_digest,
                         error_category=synology_error_category(error.code)))
        return 'unknown', 'CHECK_FAILED', 'synology_login', dict(error_category='CONNECTION', credential_digest=credential_digest)
    except (OSError, ValueError, TypeError, KeyError):
        return 'unknown', 'NETWORK', 'synology_login', dict(retry_after=clock() + SYNOLOGY_TRANSPORT_COOLDOWN,
            credential_digest=credential_digest, error_category='CONNECTION')
    try:
        files._nas_api(base, {'api': 'SYNO.API.Auth', 'version': 6, 'method': 'logout',
                              'session': 'SynologyDrive', '_sid': session['sid']}, opener, deadline)
    except (OSError, ValueError, TypeError):
        pass  # The login itself already proved the credential.
    return 'connected', 'SYNOLOGY_VERIFIED', 'synology_login'


# ---- dispatch ----------------------------------------------------------

def run_check(root, context, *, opener, runner, clock, record, permission_judge, manual=False):
    """context: connections.ConnectionContext for one existing, enabled connection."""
    service, home = context.row['service'], context.home
    if service == 'google':
        return check_google(root, context.row['scope'], runner)
    if service == 'notion':
        return check_notion(home, opener)
    if service == 'synology':
        return check_synology(home, context.settings.get('files', {}).get('synology', {}), opener, clock, record, manual=manual)
    if service == 'x':
        return check_x(home, opener)
    if service == 'instagram':
        return check_instagram(home, instagram_module(home, context.profile), opener)
    if service == 'slack':
        return check_slack(home, opener)
    if service == 'photon':
        return check_photon(root, context.profile)
    if service in ('mail_read', 'notes_read', 'calendar_read'):
        return (*permission_judge(root, service), 'mac_permission')
    return 'unknown', 'CHECK_FAILED', 'unknown'


def check(root, profile, connection, *, opener=None, runner=None, clock=None, permission_judge=None, manual=False):
    """One connection. Returns the action envelope (see connections.main)."""
    import subprocess
    import time
    from hermes_facility import connection_secrets, connections, mac_permission
    clock = clock or time.time
    connection_secrets.purge_undo(root, clock)
    context = connections.find_connection(root, profile, connection)
    base = dict(action='check', profile=profile, connection=connection)
    if context is None:
        return dict(base, outcome='refused', reason='UNKNOWN_CONNECTION')
    if context.row['state'] == 'off':
        return dict(base, outcome='refused', reason='OFF')
    key = profile + '/' + connection
    with _locked(store_folder(root) / 'locks' / (profile + '__' + connection + '.lock'), blocking=False) as free:
        if not free:
            return dict(base, outcome='refused', reason='BUSY')
        record = load_checks(root).get(key)
        if not manual and record and clock() - record.get('at', 0) < THROTTLE_SECONDS:
            return dict(base, outcome='done', reason='RECENTLY_CHECKED', check=public(record))
        answer = run_check(root, context, opener=opener or default_opener(), runner=runner or subprocess.run,
                           clock=clock, record=record,
                           permission_judge=permission_judge or mac_permission.judge, manual=manual)
        state, reason, method = answer[:3]
        extra = answer[3] if len(answer) > 3 else {}
        if extra.get('note') == 'COOLDOWN':
            return dict(base, outcome='done', reason='COOLDOWN', check=public(record))
        fresh = dict(state=state, reason=reason, verified_by=method, checked_at=stamp(clock), at=clock())
        if 'retry_after' in extra:
            fresh['retry_after'] = extra['retry_after']
        for key in ('credential_digest', 'error_category'):
            if key in extra:
                fresh[key] = extra[key]
        if context.row['service'] == 'instagram' and (expires := instagram_expiry(context.home)):
            fresh['expires_at'] = expires
        save_check(root, profile, connection, fresh)
        return dict(base, outcome='done', reason=extra.get('note', 'OK'), check=public(fresh))


def public(record):
    return {key: record[key] for key in ('state', 'reason', 'verified_by', 'checked_at', 'expires_at')
            if key in record}


def check_all(root, profile, **kwargs):
    from hermes_facility import connections
    rows = connections.connection_ids(root, profile)
    if rows is None:
        return dict(action='check', profile=profile, outcome='refused', reason='UNKNOWN_PROFILE')
    with ThreadPoolExecutor(max_workers=PARALLEL_CHECKS) as pool:
        futures = [pool.submit(check, root, profile, name, **kwargs) for name in rows]
        results = [future.result() for future in futures]
    return dict(action='check', profile=profile, outcome='done', reason='OK', results=results)


def permission_request(root, profile, connection, *, clock=None, requester=None):
    """Owner pressed 권한 요청: the OS dialog appears on this Mac; the answer becomes the stored check."""
    import time
    from hermes_facility import connections, mac_permission
    clock = clock or time.time
    context = connections.find_connection(root, profile, connection)
    base = dict(action='permission_request', profile=profile, connection=connection)
    if context is None or context.row['service'] not in mac_permission.TARGETS:
        return dict(base, outcome='refused', reason='UNKNOWN_CONNECTION')
    if context.row['state'] == 'off':
        return dict(base, outcome='refused', reason='OFF')
    state, reason = (requester or mac_permission.request)(root, context.row['service'])
    if reason in ('TIMEOUT', 'LAUNCH_FAILED', 'CHECK_FAILED'):
        return dict(base, outcome='failed', reason=reason)
    fresh = dict(state=state, reason=reason, verified_by='mac_permission', checked_at=stamp(clock), at=clock())
    save_check(root, profile, connection, fresh)
    return dict(base, outcome='done', reason='OK', check=public(fresh))


def permission_settings(root, profile, connection):
    from hermes_facility import connections, mac_permission
    context = connections.find_connection(root, profile, connection)
    base = dict(action='open_settings', profile=profile, connection=connection)
    if context is None or context.row['service'] not in mac_permission.TARGETS:
        return dict(base, outcome='refused', reason='UNKNOWN_CONNECTION')
    return dict(base, outcome='done', reason='OK', **mac_permission.settings_guide(context.row['service']))
