"""Owner-requested inspection, using the scheduled inspection under the same lock.

A dedicated process owns the alarm: gateway tool threads cannot install signal handlers. The alarm unwinds
all Python finally blocks, leaving 35 seconds within the 180-second outer limit for focus restoration and saving.
"""
import contextlib
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
from datetime import datetime

from . import reference, state, vision, watch

TIMEOUT = 180
CLEANUP_SECONDS = 35
BUSY = '방금 확인 중이에요, 잠시 뒤 다시 물어 주세요'
SCHEMA = {
    'name': 'cctv_now',
    'description': ('소유자가 지금 낙화를 하는지, 현장 화면이 어떤지 물으면 이 도구로 9번 CCTV를 확인한다. '
                    '소유자 Slack 고객 담당방·DM 전용. 결과의 장면·이유·영상 시각·확인 날짜(YYYY-MM-DD)와 시각·다시 틀기 여부를 소유자 보고 양식으로 답한다. relived는 시도 여부이며 relive_result가 ok일 때만 다시 틀기 성공이다. '
                    '준비중·진행중이면 상황으로 기록할까요?라고 묻고 소유자가 말해야 기존 상황 writer로 기록한다. '
                    '자동 상황 기록·원격 재연결은 하지 않는다. 캡처는 같은 스레드에 첨부한다. 전체 제한 180초.'),
    'parameters': {'type': 'object', 'properties': {}, 'additionalProperties': False},
}


class Expired(BaseException):
    """Escape model exception handling and unwind the focus lease on the overall deadline."""


@contextlib.contextmanager
def deadline(seconds, on_timeout=None):
    """Used only by the isolated worker's main thread, never by a gateway thread."""
    def expired(_signum, _frame):
        if on_timeout:
            on_timeout()
        raise Expired()
    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def inspect(home, *, policy, site, now, screen, ask, upload, channel, thread, region=None, region_note=None, on_timeout=None):
    """Own the shared lock and daily reset; within the day persist only last_ask and the shared budget."""
    with state.locked(home) as free:
        if not free:
            return {'ok': False, 'error': 'CCTV_BUSY', 'message': BUSY}
        original = state.load(home, now.date().isoformat())
        initial_count = original.get('relive', {}).get('count', 0) if original.get('relive', {}).get('date') == now.date().isoformat() else 0
        data = copy.deepcopy(original)
        data['alerts'] = []  # Local notices never consume the scheduled once-per-day markers.
        result = {'ok': False, 'scene': vision.UNREADABLE, 'reason': '', 'osd_time': None,
                  'checked_at': now.isoformat(timespec='seconds'), 'relived': False,
                  'capture': None, 'image_posted': False, 'chat': channel, 'thread': thread}
        path = state.captures(home, now.date().isoformat()) / ('ask-' + now.strftime('%H%M%S%f') + '.png')

        def save_budget(value):
            # Called before the first input too, so a failed or interrupted request still spends its attempt.
            original['relive'] = copy.deepcopy(value['relive'])
            state.save(home, original)

        try:
            with deadline(TIMEOUT - CLEANUP_SECONDS, on_timeout):
                if policy is None:
                    result['reason'] = 'CCTV 확인이 꺼져 있어요.'
                else:
                    watch.check(home, data=data, policy=policy, site=site, now=now, screen=screen,
                                              ask=ask, say=lambda _text: None, path=path, region=region,
                                              region_note=region_note, save=save_budget, result=result)
                    result['ok'] = result['scene'] != vision.UNREADABLE
                    if result['reason'] in ('WINDOW_MISSING', watch.ADT_EYE_LOST):
                        result['reason'] = '원격 연결이 끊겨 있어요'
                    if result['capture']:
                        try:
                            upload(channel, thread, Path(result['capture']))
                            result['image_posted'] = True
                        except Exception as error:
                            result['image_error'] = type(error).__name__ + ': ' + str(error)[:200]
        except Expired:
            result['timed_out'] = True
            record = data.get('relive', {})
            if record.get('date') == now.date().isoformat() and record.get('count', 0) > initial_count:
                record['last_result'] = 'CCTV_NOW_TIMEOUT'
            result['reason'] = '확인 제한 시간에 도달했어요. ' + result['reason']
            if not result['capture']:
                captures = sorted(path.parent.glob(path.stem + '*.png'), key=lambda p: p.stat().st_mtime)
                result['capture'] = str(captures[-1]) if captures else None
            if result['capture'] and not result['image_posted']:
                result['image_error'] = '시간 제한으로 이미지 첨부를 완료하지 못했어요.'
        except Exception as error:
            result['reason'] = type(error).__name__ + ': ' + str(error)[:200]
        finally:
            record = data.get('relive', {})
            # The pre-input save is authoritative; only copy a budget that this inspection actually touched.
            if record and record != original.get('relive', {}):
                save_budget(data)
            result['relived'] = result['relived'] or (record.get('date') == now.date().isoformat()
                and record.get('count', 0) > initial_count)
            result['relive_result'] = record.get('last_result') if result['relived'] or (
                not result.get('identified') and result['reason'] in watch.RELIVE_REASONS) else None
            result['focus'] = data.get('last_focus') if data.get('last_focus') != original.get('last_focus') else None
            original['last_ask'] = copy.deepcopy(result)
            state.save(home, original)
        return result


def worker(home, channel, thread):
    from hermes_team_services import load
    from . import screen, settings
    policy = settings.policy()
    site = settings.site()
    reports = load('learning_report', 'cctv_now_report')
    region, note = settings.scene_region()
    closing = []

    def commands(argv, **kwargs):
        if closing:
            restoring = len(argv) > 4 and argv[3] == str(screen.HERE / 'focus.js') and argv[4] == 'restore'
            # Escape needs a list and an input (5 s each); restoration gets 20 s. All fit the 35 s reserve.
            kwargs['timeout'] = min(kwargs.get('timeout', 30), 20 if restoring else 5)
        return subprocess.run(argv, **kwargs)

    return inspect(home, policy=policy, site=site, now=datetime.now(), screen=screen.Session(site, policy, run=commands),
                   ask=vision.model_caller(), channel=channel, thread=thread, region=region, region_note=note,
                   on_timeout=lambda: closing.append(True),
                   upload=lambda room, ts, path: reports.upload_image(home, room, ts, path, '낙화 CCTV 지금 화면'))


def handle(home, args, *, authority=None, run=subprocess.run, **_):
    """Authorize from the current gateway session, never from caller-supplied channel/thread arguments."""
    authority = authority or reference.Authority(home)
    refusal = authority.room_problem()
    if refusal:
        return json.dumps({'ok': False, 'error': refusal}, ensure_ascii=False)
    if args:
        return json.dumps({'ok': False, 'error': 'CCTV_NOW_ARGUMENTS_INVALID'})
    channel, thread = reference.conversation_key()
    if not channel or not thread:
        return json.dumps({'ok': False, 'error': 'CCTV_NOW_THREAD_REQUIRED'})
    env = {**os.environ, 'HERMES_HOME': str(home), 'HERMES_DISABLE_LAZY_INSTALLS': '1'}
    library = str(Path(__file__).resolve().parents[2])
    env['PYTHONPATH'] = library + os.pathsep + env.get('PYTHONPATH', '')
    try:
        done = run([sys.executable, '-m', __name__, str(home), channel, thread], env=env,
                   capture_output=True, text=True, timeout=TIMEOUT)
        if done.returncode != 0:
            raise RuntimeError('CCTV_NOW_WORKER_FAILED')
        result = json.loads(done.stdout)
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        result = {'ok': False, 'error': type(error).__name__, 'message': 'CCTV 확인을 마치지 못했어요.'}
    return json.dumps(result, ensure_ascii=False)


if __name__ == '__main__':
    print(json.dumps(worker(Path(sys.argv[1]), sys.argv[2], sys.argv[3]), ensure_ascii=False))
