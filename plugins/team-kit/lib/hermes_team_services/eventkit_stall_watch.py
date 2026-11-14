"""EventKit 교착 5분 감시: 두 번 표본 → 증거 수집 → 현재 사용자 데몬 재시작 → 진단담당 DM(no-agent 예약 진입).

교착 표식은 현재 사용자 ``syncdefaultsd`` 표본의 ``isUbiquityEnabledForAuditToken`` 프레임이다(교착 때 표본 대부분,
정상 때 0). 이 감시가 시스템에 하는 쓰기는 현재 사용자의 ``syncdefaultsd``·``remindd`` 두 이름에 보내는
종료 신호 하나뿐이며 하루 한도는 사장 지시서 ``eventkit_stall_watch``가 정한다. 증거는 삭제하지 않는다.
설계: docs/changes/CALENDAR-REMINDD-ROOT-20261111/handoff.md (v6).
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

_library = str(Path(__file__).resolve().parents[1])
if _library not in sys.path:
    sys.path.insert(0, _library)
from hermes_facility import atomic, owner_vault, team_registry
from hermes_schedule.catalog import read as read_policy
from hermes_team_services import load

KST = ZoneInfo('Asia/Seoul')
STALL_MARKER = 'isUbiquityEnabledForAuditToken'
RESTART_NAMES = ('syncdefaultsd', 'remindd')
SAMPLE_PROGRAM, PS_PROGRAM, PGREP_PROGRAM = '/usr/bin/sample', '/bin/ps', '/usr/bin/pgrep'
LOG_PROGRAM, SUDO_PROGRAM, SPINDUMP_PROGRAM = '/usr/bin/log', '/usr/bin/sudo', '/usr/sbin/spindump'
# 소유자가 tools/4-install-spindump-permission.sh로 한 번 허용하는 인자 고정 한 명령(출력 폴더는 root 소유).
SPINDUMP_FILE = '/private/var/db/hermes-spindump/latest.txt'
SPINDUMP_ARGS = ('-notarget', '10', '-file', SPINDUMP_FILE)
EVIDENCE_PROCESS_PATTERN = re.compile(r'tccd|syncdefaultsd|remindd|calaccessd|eventkit_calendar_')
LOG_PREDICATE = 'process == "tccd" OR process == "syncdefaultsd" OR process == "remindd" OR process == "calaccessd"'

SAMPLE_SECONDS = 1            # 감지용 표본 길이
SAMPLE_TIMEOUT = 10           # 감지용 표본 한 번의 시간 제한
SECOND_SAMPLE_DELAY = 20      # 첫 표본에 표식이 있을 때 두 번째 표본까지 기다리는 시간
RECHECK_DELAY = 60            # 재시작 뒤 확인까지 기다리는 시간
COLLECT_BUDGET = 90           # 증거 수집 전체 한도
EVIDENCE_SAMPLE_SECONDS = 2
EVIDENCE_SAMPLE_TIMEOUT = 15
EVIDENCE_PS_TIMEOUT = 10
EVIDENCE_LOG_TIMEOUT = 60
EVIDENCE_SPINDUMP_TIMEOUT = 45
EVIDENCE_FULL_LIMIT = 10      # 증거 폴더가 이 수 이상이면 큰 파일(spindump·로그)은 남기지 않는다
MIN_STALL_MARKERS = 5         # 표본 하나의 표식이 이 수 이상이어야 교착이다(2026-11-11 실측: 교착 67~123건, 정상 0건)
MAX_PROCESS_SAMPLES = 4       # 이름마다 표본을 뜨는 프로세스 수 상한
MAX_LIMIT_PER_DAY = 10
STATE_VERSION = 1
FOLDER_NAME = re.compile(r'^\d{8}-\d{6}$')
STATE_KEEP_DAYS = 14

CHANNEL = owner_vault.text('dms.doctor')  # 금고에 없으면 보내지 않는다


class WatchError(ValueError):
    pass


# ---- 시스템 접점(시험에서 대체한다) ----

def run_command(args, timeout, *, stdout_path=None):
    """(returncode, stdout, stderr, timed_out). 없는 프로그램·시간 초과·권한 오류로 예외를 내지 않는다."""
    out_fd = None
    try:
        if stdout_path is not None:
            out_fd = os.open(stdout_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        done = subprocess.run(list(args), stdin=subprocess.DEVNULL, stdout=out_fd if out_fd is not None else subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, timeout=timeout, errors='replace')
        return done.returncode, done.stdout or '', done.stderr or '', False
    except subprocess.TimeoutExpired:
        return None, '', '', True
    except FileNotFoundError:
        return 127, '', 'program not found', False
    except OSError as exc:  # 시간 초과 뒤 종료 신호를 보낼 수 없는 경우(상승 권한 자식) 포함
        return None, '', type(exc).__name__, True
    finally:
        if out_fd is not None:
            os.close(out_fd)


def pause(seconds):
    time.sleep(seconds)


def monotonic():
    return time.monotonic()


def signal_process(pid, number):
    try:
        os.kill(pid, number)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def uid():
    return os.getuid()


def deliver(home, text):
    report = load('learning_report', 'eventkit_stall_report')
    return report.slack(home, 'chat.postMessage', {'channel': CHANNEL, 'text': text,
                                                    'unfurl_links': False, 'unfurl_media': False})


def quiet(now):
    return load('morning_queue', 'eventkit_stall_queue').quiet(now)


def hold(home, text, now):
    load('morning_queue', 'eventkit_stall_queue').hold(home, CHANNEL, text, at=datetime.fromtimestamp(now, KST).isoformat())


# ---- 지시서 ----

def policy(root):
    """켜져 있으면 {'max_restarts_per_day': n}, 꺼짐·키 없음이면 None. 값이 잘못되면 WatchError."""
    path = Path(root) / 'owner/policy.yaml'
    block = read_policy(path).get('eventkit_stall_watch') if path.exists() else None
    if not isinstance(block, dict) or block.get('enabled') is not True:
        return None
    limit = block.get('max_restarts_per_day')
    if type(limit) is not int or not 1 <= limit <= MAX_LIMIT_PER_DAY:
        raise WatchError('EVENTKIT_STALL_POLICY_INVALID:max_restarts_per_day')
    return {'max_restarts_per_day': limit}


# ---- 감지 ----

def pids_of(name, owner_uid):
    code, out, _, _ = run_command([PGREP_PROGRAM, '-x', '-u', str(owner_uid), name], SAMPLE_TIMEOUT)
    return [int(token) for token in out.split() if token.isdigit()] if code == 0 else []


def marker_count(pid):
    """표본의 표식 수. 표본을 뜨지 못하면 None."""
    code, out, _, timed_out = run_command([SAMPLE_PROGRAM, str(pid), str(SAMPLE_SECONDS)], SAMPLE_TIMEOUT)
    if timed_out or code != 0 or not out.strip():
        return None
    return out.count(STALL_MARKER)


def check(owner_uid):
    """한 번 확인한다: {'state': 'stalled'|'ok'|'unknown', 'markers': 표식 수 또는 None, 'reason': ...}."""
    pids = pids_of('syncdefaultsd', owner_uid)
    if not pids:
        return {'state': 'unknown', 'markers': None, 'reason': 'no_process'}
    counts = [marker_count(pid) for pid in pids[:MAX_PROCESS_SAMPLES]]
    found = sum(count for count in counts if count)
    if any(count is not None and count >= MIN_STALL_MARKERS for count in counts):
        return {'state': 'stalled', 'markers': found, 'reason': None}
    if all(count is not None for count in counts):
        return {'state': 'ok', 'markers': found, 'reason': None}  # 1~MIN-1건은 우연한 표식이라 교착으로 보지 않는다
    return {'state': 'unknown', 'markers': None, 'reason': 'sample_failed'}


def detect(owner_uid):
    """두 번 모두 표식이 있어야 교착이다. 첫 표본이 정상·확인 불가면 두 번째 표본을 뜨지 않는다."""
    first = check(owner_uid)
    if first['state'] != 'stalled':
        return {**first, 'first': first, 'second': None}
    pause(SECOND_SAMPLE_DELAY)
    second = check(owner_uid)
    state = 'stalled' if second['state'] == 'stalled' else second['state']
    return {'state': state, 'markers': second['markers'], 'reason': second['reason'], 'first': first, 'second': second}


# ---- 상태·잠금 ----

def state_dir(home):
    home = Path(home)
    directory = home / 'state/eventkit-stall'
    for part in (home / 'state', directory):
        if part.is_symlink():
            raise WatchError('EVENTKIT_STALL_STATE_SYMLINK')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    return directory


@contextmanager
def exclusive(home):
    """비대기 배타 잠금. 다른 실행이 잡고 있으면 False를 내고 아무것도 하지 않는다."""
    lock_fd = os.open(state_dir(home) / 'state.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        os.close(lock_fd)


def load_state(home):
    path = state_dir(home) / 'state.json'
    if path.is_symlink():
        raise WatchError('EVENTKIT_STALL_STATE_SYMLINK')
    if not path.exists():
        return {'version': STATE_VERSION, 'days': {}}
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict) or data.get('version') != STATE_VERSION or not isinstance(data.get('days'), dict):
        raise WatchError('EVENTKIT_STALL_STATE_INVALID')
    return data


def save_state(home, data):
    days = dict(sorted(data['days'].items())[-STATE_KEEP_DAYS:])
    atomic.write_json(state_dir(home) / 'state.json', {**data, 'days': days}, indent=1, mode=0o600, prefix='.eventkit-stall-')


# ---- 증거 ----

def new_file(folder, name, text=''):
    fd = os.open(Path(folder) / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        stream.write(text)


def evidence_folders(root):
    return sorted(entry.name for entry in Path(root).iterdir() if entry.is_dir() and FOLDER_NAME.match(entry.name))


def copy_new(source, folder, name):
    fd = os.open(Path(folder) / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as target, open(source, 'rb') as stream:
        while chunk := stream.read(1 << 20):
            target.write(chunk)


def collect_spindump(folder, started, timeout):
    code, _, err, timed_out = run_command([SUDO_PROGRAM, '-n', SPINDUMP_PROGRAM, *SPINDUMP_ARGS], timeout)
    reason = None
    if timed_out:
        reason = f'시간 초과({timeout:.0f}초)'
    elif code != 0:
        needs_password = 'password' in err.lower()
        reason = ('무암호 허용이 설치되지 않았다(tools/4-install-spindump-permission.sh)' if needs_password
                  else f'종료 코드 {code}: {err.strip()[:300]}')
    else:
        try:
            info = os.stat(SPINDUMP_FILE)
            if info.st_mtime < started - 2 or info.st_size == 0:
                reason = '결과 파일이 새로 만들어지지 않았다'
            else:
                copy_new(SPINDUMP_FILE, folder, 'spindump.txt')
        except OSError as exc:
            reason = f'결과 파일을 읽지 못했다({type(exc).__name__})'
    if reason:
        new_file(folder, 'spindump-unavailable.txt', reason + '\n')
        return {'saved': False, 'reason': reason}
    return {'saved': True, 'reason': None}


def collect_evidence(home, owner_uid, detection, now):
    """재시작 전에 증거를 남긴다. 어떤 실패도 호출자의 재시작 판단을 막지 않는다(예외 없이 결과 dict)."""
    home = Path(home)
    stamp = datetime.fromtimestamp(now, KST).strftime('%Y%m%d-%H%M%S')
    result = {'folder': None, 'spindump': None, 'note': None, 'items': {}}
    try:
        root = state_dir(home) / 'evidence'
        if root.is_symlink():
            result['note'] = '증거 폴더 경로가 심볼릭 링크라 수집하지 않았다'
            return result
        root.mkdir(mode=0o700, exist_ok=True)
        os.chmod(root, 0o700)
        full = len(evidence_folders(root)) < EVIDENCE_FULL_LIMIT
        folder = root / stamp
        try:
            os.mkdir(folder, 0o700)
        except FileExistsError:
            result['note'] = '같은 이름의 증거 폴더가 있어 수집하지 않았다'
            return result
        result['folder'] = stamp
        started, started_clock = now, monotonic()

        def remaining():
            return COLLECT_BUDGET - (monotonic() - started_clock)

        def step(label, action):
            if remaining() <= 0:
                result['items'][label] = '시간 한도로 건너뜀'
                return
            try:
                result['items'][label] = action()
            except Exception as exc:  # 한 항목의 실패가 다음 항목을 막지 않는다
                result['items'][label] = f'실패({type(exc).__name__})'

        def listing():
            code, out, _, timed_out = run_command([PS_PROGRAM, '-axo', 'pid,uid,user,lstart,command'],
                                                  min(EVIDENCE_PS_TIMEOUT, max(remaining(), 1)))
            lines = out.splitlines()
            kept = lines[:1] + [line for line in lines[1:] if EVIDENCE_PROCESS_PATTERN.search(line)]
            new_file(folder, 'ps.txt', '\n'.join(kept) + '\n')
            return '저장' if code == 0 and not timed_out else '불완전'

        def samples():
            saved = []
            targets = [(name, pid) for name in RESTART_NAMES for pid in pids_of(name, owner_uid)[:MAX_PROCESS_SAMPLES]]
            code, out, _, _ = run_command([PGREP_PROGRAM, '-f', '-u', str(owner_uid), 'eventkit_calendar_'], SAMPLE_TIMEOUT)
            targets += [('eventkit', int(token)) for token in out.split()[:MAX_PROCESS_SAMPLES] if code == 0 and token.isdigit()]
            for name, pid in targets:
                if remaining() <= 0:
                    break
                code, out, _, timed_out = run_command([SAMPLE_PROGRAM, str(pid), str(EVIDENCE_SAMPLE_SECONDS)],
                                                      min(EVIDENCE_SAMPLE_TIMEOUT, max(remaining(), 1)))
                if code == 0 and out.strip():
                    new_file(folder, f'sample-{name}-{pid}.txt', out)
                    saved.append(f'{name}-{pid}')
            return f'{len(saved)}개 저장'

        def spindump():
            if not full:
                return '폴더가 많아 생략'
            outcome = collect_spindump(folder, started, min(EVIDENCE_SPINDUMP_TIMEOUT, max(remaining(), 1)))
            result['spindump'] = outcome
            return '저장' if outcome['saved'] else '불가: ' + outcome['reason']

        def history():
            if not full:
                return '폴더가 많아 생략'
            code, _, _, timed_out = run_command([LOG_PROGRAM, 'show', '--info', '--debug', '--last', '15m', '--style', 'compact',
                                                 '--predicate', LOG_PREDICATE],
                                                min(EVIDENCE_LOG_TIMEOUT, max(remaining(), 1)), stdout_path=folder / 'log-15m.txt')
            return '저장' if code == 0 and not timed_out else '불완전'

        step('ps', listing)
        step('sample', samples)
        step('spindump', spindump)
        step('log', history)
        lines = [f'detected_at {datetime.fromtimestamp(now, KST).isoformat()}',
                 f'first_markers {detection["first"]["markers"]}', f'second_markers {(detection["second"] or {}).get("markers")}']
        lines += [f'{label}: {value}' for label, value in result['items'].items()]
        new_file(folder, 'manifest.txt', '\n'.join(lines) + '\n')
    except Exception as exc:  # 수집 실패는 재시작을 막지 않는다
        result['note'] = f'수집 실패({type(exc).__name__})'
    return result


# ---- 재시작 ----

def restart_daemons(owner_uid):
    """현재 사용자의 정확한 두 이름 프로세스에만 종료 신호를 보낸다. {이름: [pid...]}를 돌려준다."""
    sent = {}
    for name in RESTART_NAMES:
        sent[name] = [pid for pid in pids_of(name, owner_uid) if signal_process(pid, signal.SIGKILL)]
    return sent


# ---- 알림 ----

OUTCOME_TEXT = {'ok': '풀림', 'stalled': '계속 막힘', 'unknown': '확인 불가'}


def message(kind, detection, evidence, outcome, count, limit, now, sent=None):
    when = datetime.fromtimestamp(now, KST).strftime('%H:%M')
    if kind == 'limit':
        title = f'*🔴 일정 앱 응답 멈춤: 오늘 재시작 한도({limit}회) 도달 — 맥 재부팅 필요*'
    elif sent is not None and not any(sent.values()):
        title = '*🟡 일정 앱 응답 멈춤: 재시작할 프로세스를 찾지 못함*'
    elif outcome == 'ok':
        title = '*🟢 일정 앱 응답 멈춤: 데몬 재시작으로 풀림*'
    elif outcome == 'stalled':
        title = '*🔴 일정 앱 응답 멈춤: 재시작 뒤에도 막힘 — 맥 재부팅 필요*'
    else:
        title = '*🟡 일정 앱 응답 멈춤: 데몬 재시작함, 풀렸는지 확인하지 못함*'
    lines = [title, f'- *감지*: {when}(한국시간), 현재 사용자 `syncdefaultsd` 표본 두 번 모두 `{STALL_MARKER}` 표식'
             f'(첫 표본 {detection["first"]["markers"]}건, 두 번째 {detection["second"]["markers"]}건)']
    if evidence['folder']:
        dump = evidence['spindump']
        dump_text = ('spindump 있음' if dump and dump['saved']
                     else f'spindump 없음({dump["reason"]})' if dump else 'spindump 생략')
        lines.append(f'- *증거*: `state/eventkit-stall/evidence/{evidence["folder"]}` ({dump_text})')
    else:
        lines.append(f'- *증거*: 남기지 못했다({evidence["note"]})')
    if kind == 'limit':
        lines.append(f'- *조치*: 오늘 재시작 {count}/{limit}회를 모두 써서 이번에는 재시작하지 않았다.')
    else:
        done = [name for name in RESTART_NAMES if sent is None or sent.get(name)]
        missing = [name for name in RESTART_NAMES if name not in done]
        if not done:
            action = '재시작할 현재 사용자 `syncdefaultsd`·`remindd` 프로세스를 찾지 못해 종료 신호를 보내지 않았고'
        elif missing:
            action = (f'현재 사용자 {"·".join(f"`{name}`" for name in done)}만 재시작했고'
                      f'({"·".join(f"`{name}`" for name in missing)}는 찾지 못함)')
        else:
            action = '현재 사용자 `syncdefaultsd`·`remindd`를 재시작했고'
        lines.append(f'- *조치*: {action} {RECHECK_DELAY}초 뒤 확인 결과는 '
                     f'*{OUTCOME_TEXT[outcome]}*이다. 오늘 {count}/{limit}회 사용(남은 {limit - count}회).')
    if kind == 'limit' or outcome == 'stalled':
        lines.append('- *부탁*: 맥을 재부팅해 주세요. 재부팅은 자동으로 하지 않는다.')
    return '\n'.join(lines)


def notify(home, text, now):
    """진단담당 DM. 00:00~08:29는 보류 줄로 넘긴다. 실패는 알림 실패 기록만 남기고 감시 결과를 바꾸지 않는다."""
    try:
        if not CHANNEL:
            raise WatchError("owner vault value 'dms.doctor' is not set")
        if quiet(now):
            hold(home, text, now)
        else:
            deliver(home, text)
    except Exception as exc:
        print(f'eventkit_stall_watch: 알림 실패({type(exc).__name__})', file=sys.stderr)


# ---- 진입 ----

def handle_stall(home, owner_uid, detection, limit, state, now):
    day = datetime.fromtimestamp(now, KST).strftime('%Y-%m-%d')
    record = state['days'].setdefault(day, {'restarts': 0, 'limit_notified': False})
    if record['restarts'] >= limit:
        # 한도에 닿은 뒤에는 그날 한도 알림 한 번에만 증거를 남긴다(5분마다 쌓이지 않게).
        if record['limit_notified']:
            save_state(home, state)
            return
        record['limit_notified'] = True
        save_state(home, state)
        evidence = collect_evidence(home, owner_uid, detection, now)
        state['last_event'] = {'at': datetime.fromtimestamp(now, KST).isoformat(), 'kind': 'limit', 'evidence': evidence['folder']}
        save_state(home, state)
        notify(home, message('limit', detection, evidence, None, record['restarts'], limit, now), now)
        return
    evidence = collect_evidence(home, owner_uid, detection, now)
    record['restarts'] += 1  # 종료 신호를 보내기 전에 횟수를 먼저 기록한다
    state['last_event'] = {'at': datetime.fromtimestamp(now, KST).isoformat(), 'kind': 'restart', 'evidence': evidence['folder'],
                           'outcome': 'pending'}
    save_state(home, state)
    sent = restart_daemons(owner_uid)
    pause(RECHECK_DELAY)
    outcome = check(owner_uid)['state']
    state['last_event'].update(outcome=outcome, restarted={name: len(pids) for name, pids in sent.items()})
    save_state(home, state)
    notify(home, message('restart', detection, evidence, outcome, record['restarts'], limit, now, sent), now)


def run(root, home, *, dry_run=False, now=None):
    values = policy(root)
    if values is None:
        if dry_run:
            print('eventkit_stall_watch dry-run: 지시서 eventkit_stall_watch가 꺼져 있다(아무것도 하지 않는다)')
        return 0
    owner_uid = uid()
    if dry_run:
        detection = detect(owner_uid)
        print(f'eventkit_stall_watch dry-run: {detection["state"]} (표식 {detection["markers"]}, 사유 {detection["reason"]})')
        return 0
    with exclusive(home) as acquired:
        if not acquired:
            return 0
        now = time.time() if now is None else now
        state = load_state(home)
        state['last_check'] = datetime.fromtimestamp(now, KST).isoformat()
        detection = detect(owner_uid)
        state['last_result'] = detection['state']
        if detection['state'] != 'stalled':
            save_state(home, state)
            return 0
        handle_stall(home, owner_uid, detection, values['max_restarts_per_day'], state, now)
    return 0


def main(argv=None, *, root=None, home=None, now=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true', help='표본으로 감지만 확인한다(증거·재시작·알림·상태 쓰기 없음)')
    args = parser.parse_args(argv)
    root = Path(root) if root is not None else team_registry.root_home()
    home = Path(home) if home is not None else team_registry.home_of_role('doctor', root)
    try:
        return run(root, home, dry_run=args.dry_run, now=now)
    except (OSError, ValueError, TypeError, RuntimeError) as exc:
        print(f'eventkit_stall_watch 실패: {type(exc).__name__}: {exc}', file=sys.stderr)
        return 1
