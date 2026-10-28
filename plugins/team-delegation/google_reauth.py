"""Owner-operated company consent on this Mac. No browser or Gmail mutations."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

ACCOUNT = 'user(at)example.com'
GUIDANCE = ('Mac mini에서 실행 중인 브라우저로 링크를 연다. localhost 리다이렉트는 그 브라우저의 기기로 돌아오므로 '
            '다른 기기에서는 인증을 마칠 수 없다(별도 터널 구성 제외). 동의는 소유자가 직접 한다. '
            '900초 안에 동의 후 google_reauth(action=status)로 확인하고, 성공하면 원래 작업을 다시 묻는다.')
SCHEMA = {'name': 'google_reauth', 'description':
          'Company Google consent for work-assistant in owner Slack chat only. check: missing scopes; '
          'start: return URL without opening a browser; status: process exit and connection check. '
          'Owner must open the link in a browser on this Mac mini and consent personally. Never executes the original mail task.',
          'parameters': {'type': 'object', 'additionalProperties': False, 'required': ['action'],
                         'properties': {'action': {'type': 'string', 'enum': ['check', 'start', 'status']},
                                        'account': {'type': 'string', 'enum': ['company']}}}}


def problem(td, args):
    if td.personal_roles.profile(td) != 'work-assistant':
        return 'GOOGLE_REAUTH_PROFILE_REFUSED'
    if args.get('account', 'company') != 'company':
        return 'GOOGLE_REAUTH_COMPANY_ONLY'
    if not td.selected_skills.owner_chat(td):
        return 'GOOGLE_REAUTH_OWNER_SLACK_REQUIRED: 예약·배경·진단 턴에서는 거부한다.'
    if args.get('action') not in {'check', 'start', 'status'} or set(args) - {'action', 'account'}:
        return 'GOOGLE_REAUTH_INVALID_ARGUMENTS'
    return None


def login_url(text):
    for candidate in re.findall(r'https://[^\s<>"\']+', text):
        parts = urlsplit(candidate)
        if parts.netloc == 'accounts.google.com' and parts.path.startswith('/o/oauth2/'):
            return candidate
    return None


def check(script, runner=None):
    try:
        proc = (runner or subprocess.run)([sys.executable, str(script), '--account', 'company', '--check'],
            capture_output=True, text=True, timeout=60, check=False,
            env={**os.environ, 'HERMES_DISABLE_LAZY_INSTALLS': '1'})
        if proc.returncode == 0:
            data = json.loads(proc.stdout)
            if data.get('account') != ACCOUNT:
                return {'ok': False, 'exit_code': 0, 'error': 'GOOGLE_REAUTH_ACCOUNT_MISMATCH', 'missing_scopes': []}
            return {'ok': True, 'exit_code': 0, 'account': ACCOUNT, 'missing_scopes': []}
        # Whitelist codes/scopes, never return arbitrary subprocess output.
        missing = re.search(r'COMPANY_SCOPE_MISSING:\s*([^\n]+)', proc.stderr or '')
        scopes = re.findall(r'https://(?:www.googleapis.com/auth/[a-zA-Z0-9._/-]+|mail.google.com/)', missing[1]) if missing else []
        code = re.search(r'\b(?:COMPANY_[A-Z_]+|PERSONAL_[A-Z_]+|PersonalScopeMismatch|RefreshError|GatewayEnvironmentAmbiguous)\b', proc.stderr or '')
        return {'ok': False, 'exit_code': proc.returncode, 'missing_scopes': scopes,
                'error': code[0] if code else 'GOOGLE_REAUTH_CHECK_FAILED'}
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        return {'ok': False, 'error': 'GOOGLE_REAUTH_CHECK_' + type(exc).__name__, 'missing_scopes': []}


@contextmanager
def locked(folder):
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (folder / 'lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def read_state(folder):
    try:
        return json.loads((folder / 'login.json').read_text())
    except FileNotFoundError:
        return {}


def write_state(folder, data):
    fd, name = tempfile.mkstemp(dir=folder, prefix='.login-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream)
        os.replace(name, folder / 'login.json')
    finally:
        if os.path.exists(name):
            os.unlink(name)


def alive(state):
    if state.get('status') != 'running' or not state.get('pid'):
        return False
    try:
        os.kill(state['pid'], 0)
        return True
    except ProcessLookupError:
        return False


def worker(folder, script):
    """Detached supervisor persists only URL, process metadata and exit code, never raw output."""
    try:
        proc = subprocess.Popen([sys.executable, '-u', str(script), '--account', 'company', '--login'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            env={**os.environ, 'HERMES_DISABLE_LAZY_INSTALLS': '1'})
        for line in proc.stdout:
            if url := login_url(line):
                with locked(folder):
                    state = read_state(folder)
                    state['url'] = url
                    write_state(folder, state)
        code = proc.wait()
    except Exception:
        code = None  # Supervisor error is not a known auth-process exit code.
    with locked(folder):
        state = read_state(folder)
        state.update(status='finished', exit_code=code)
        state.pop('url', None)
        write_state(folder, state)


def run(td, args, runner=None, popen=None):
    if error := problem(td, args):
        return {'ok': False, 'error': error, 'mutation_calls': 0}
    root = td._gmail_root()
    script = root / 'bin/hermes-personal-google-auth'
    folder = root / 'profiles/work-assistant/state/google-reauth'
    result = {'account': ACCOUNT, 'action': args['action'], 'mutation_calls': 0,
              'owner_action': GUIDANCE, 'browser_opened': False}
    verified = check(script, runner)
    if args['action'] == 'check':
        return {**result, **verified}
    with locked(folder):
        state = read_state(folder)
        running = alive(state)
        if args['action'] == 'start' and not running and not verified['ok']:
            proc = (popen or subprocess.Popen)([sys.executable, '-u', str(Path(__file__).resolve()),
                '--worker', str(folder), str(script)], stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
                env={**os.environ, 'HERMES_DISABLE_LAZY_INSTALLS': '1'})
            state = {'status': 'running', 'pid': proc.pid, 'started_at': time.time()}
            write_state(folder, state)
            running = True
        elif state.get('status') == 'running' and not running:
            state.update(status='interrupted', exit_code=None)
            state.pop('url', None)
            write_state(folder, state)
    # Allow the local server to print its URL, without holding the cross-process lock.
    if args['action'] == 'start' and running:
        for _ in range(50):
            with locked(folder):
                state = read_state(folder)
            if state.get('url') or state.get('status') != 'running':
                break
            time.sleep(0.1)
        running = alive(state)
    result.update(ok=True, check=verified, connected=verified['ok'], running=running,
                  status='connected' if verified['ok'] else state.get('status', 'not_started'),
                  exit_code=state.get('exit_code'))
    if running and time.time() - state.get('started_at', 0) < 900 and (url := login_url(state.get('url', ''))):
        result['url'] = url
    return result


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--worker':
        worker(Path(sys.argv[2]), Path(sys.argv[3]))
