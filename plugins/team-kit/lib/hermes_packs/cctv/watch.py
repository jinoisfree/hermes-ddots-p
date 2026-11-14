"""One wake-up of the check: decide if this is a slot, look at the live view, and propose what it shows.

Nothing here changes today's situation. A proposal is posted to the owner room through the facility, and only the
owner's button on that post makes the facility call the plugin that owns the situation record.

Nothing here reopens the remote session either: the Windows account is shared by several people, so a lost session
is only proposed for reconnecting (once a day) and `executor.run` reopens it after the owner approves.

`tick` takes everything it touches as arguments (clock, readers, screen, model, delivery) so tests drive it with
stand-ins; `run` wires the real ones."""
import json
from datetime import datetime, timedelta, time as clock

from . import executor, reference, schedule, state, vision
from .screen import CaptureFailed, FocusFailed, pick

ACTION = 'instagram-dm.situation_record'  # the executor the situation owner registers with the facility
PHOTOS_PER_LABEL = 3
PROPOSED = ('준비중', '진행중')
# How far each situation name is along: a proposal never replaces a later situation, nor a variant of its own.
PROGRESS = {'준비중': 1, '진행중': 2, '축소진행': 2}
ADT_EYE_LOST = 'ADT-EYE 화면 아님'
RELIVE_REASONS = ('LIVE 아님', '영상 멈춤', '다른 채널', '레이아웃 없음', '빈 화면', 'ADT-EYE 꺼짐')
LAYOUT_WAIT = 1
MENU_WAIT = 1
LIVE_WAIT = 10
LAUNCH_WAIT = 5
LAUNCH_POLLS = 6
EXPAND_LIMIT = 3
ITEM_WAIT = 5
ITEM_POLLS = 6


def covered(scene, current):
    """True when today's recorded situation is already this scene or further along."""
    return PROGRESS.get(current, 0) >= PROGRESS[scene]


def not_to_overwrite(scene):
    """Situations the executor must leave alone when it applies a proposal for `scene`."""
    return sorted(name for name, step in PROGRESS.items()
                  if step > PROGRESS[scene] or (step == PROGRESS[scene] and name != scene))


def _proposal_text(site, scene, reason, expires_at):
    return (f"*🔴 낙화 상황 기록 제안*\n*확인한 화면*\n  • {site['site_label']} {site['channel_label']} 라이브: {scene}\n"
            f"*판독 이유*\n  • {reason or '화면에서 확인했어요.'}\n*승인하면*\n"
            f"  • 오늘 상황을 '{scene}'(으)로 기록해 {expires_at}까지 고객 안내에 써요. 승인 전에는 아무것도 바뀌지 않아요.")


def _alert(data, say, kind, text):
    """Tell the owner room once per day per kind of trouble."""
    if kind not in data['alerts']:
        data['alerts'].append(kind)
        say(text)


def _reconnect_text(what, expires_at):
    return (f"*🔴 낙화 CCTV 원격 연결 끊김*\n*확인한 화면*\n  • {what}\n"
            f"  • 다른 사람이 같은 윈도우 계정으로 접속해 끊겼을 수 있어요.\n*승인하면*\n"
            f"  • Windows App에서 저장된 원격 장치를 다시 연결해요. 지금 그 사람이 쓰는 중이면 그 사람 연결이 끊겨요.\n"
            f"  • 인증서·로그인 확인 창이 뜨면 누르지 않고 닫아요.\n*승인하지 않으면*\n"
            f"  • 연결하지 않고, 이 제안은 {expires_at}까지만 유효해요. 오늘은 같은 제안을 다시 올리지 않아요.")


def _reconnect_ask(data, policy, site, now, window_end, what, capture, proposals, say):
    """The session is gone. Never reopen it here: ask the owner once a day, or only tell them when asking is off."""
    if policy['reconnect'] != 'ask':
        _alert(data, say, 'reconnect', f"*🟡 낙화 CCTV 원격 화면 연결 필요*\n  • {what}\n"
                                       "  • 자동 재연결은 꺼져 있어요. 직접 한 번 연결해 주세요. 오늘은 더 알리지 않아요.")
        data['reconnect'] = 'off'
        return
    rows = proposals.entries(day=now.date().isoformat(), action=executor.ACTION)
    if any(row['status'] != 'post_failed' for row in rows):
        data['reconnect'] = 'already_proposed'
        return
    expires = window_end.timestamp() + 60   # the window ends at minute precision: a wake-up in its last minute still fits
    try:
        proposals.post(action=executor.ACTION, args={}, channel=site['customer_room'], image=capture,
                       text=_reconnect_text(what, window_end.strftime('%H:%M')), expires_at=expires)
    except proposals.PostFailed:
        data['reconnect'] = 'post_failed'
    except proposals.PostUnconfirmed:
        data['reconnect'] = 'post_unconfirmed'
    else:
        data['reconnect'] = 'proposed'


def _close_reconnect_asks(proposals, now):
    """The view is back (someone connected it): an unanswered reconnect proposal must not take the session over later."""
    open_ones = [row['id'] for row in proposals.entries(day=now.date().isoformat(), action=executor.ACTION)
                 if row['status'] == 'pending']
    if open_ones:
        proposals.supersede(open_ones)


def _grab(policy, site, screen, path):
    window = pick(screen.windows(), site['rdp_device'], policy['min_window_width'], policy['min_window_height'])
    if window is None:
        raise CaptureFailed('WINDOW_MISSING')
    if window.get('onscreen') is False:
        window = screen.prepare(window)
    return window, screen.capture(window, path)



def _relive(home, data, policy, site, screen, ask, say, path, now, capture, identified, references, window, save=None):
    """At most one attempt in this wake-up, with its daily budget saved before any input (including a failed input)."""
    day, reason = now.date().isoformat(), identified['reason']
    record = data.setdefault('relive', {'date': day, 'count': 0, 'last_reason': reason, 'last_result': ''})
    if record['date'] != day:
        record.update(date=day, count=0)
    record['last_reason'] = reason

    def fail(why):
        record['last_result'] = why
        _alert(data, say, 'relive', f"*🟡 낙화 CCTV 9번 라이브를 다시 틀지 못했어요*\n  • {why}\n"
                                   "  • ADT-EYE에서 9번을 직접 눌러 주세요. 오늘은 더 알리지 않아요.")
        return capture, identified

    if policy.get('relive', 'auto') != 'auto':
        return fail((f"9번 영상이 {identified.get('osd_time') or '읽을 수 없는 시각'}에서 멈췄어요. " if reason == '영상 멈춤' else reason + '. ')
                    + '라이브 다시 틀기가 꺼져 있어요.')
    if record['count'] >= policy.get('relive_daily_limit', 10):
        return fail('라이브 다시 틀기 하루 한도에 도달했어요.')
    record['count'] += 1
    record['last_result'] = 'attempting'
    (save or (lambda value: state.save(home, value)))(data)
    menu_open = False
    elapsed = 0
    try:
        def locate(kind):
            return vision.control(ask, capture, kind, site_label=site['site_label'], channel_label=site['channel_label'], app_icon_label=site.get('app_icon_label'), channel_index=site.get('channel_index'))

        if identified['reason'] == 'ADT-EYE 꺼짐':
            found = locate('launch')
            if not found['ok']:
                return fail(found['reason'])
            screen.input(window, 'double', found['box'])
            for poll in range(LAUNCH_POLLS):
                screen.wait(LAUNCH_WAIT)
                elapsed += LAUNCH_WAIT
                capture = screen.capture(window, path.with_name(path.stem + f'-launch{poll + 1}.png'))
                checked = vision.identify(ask, capture, references, site_label=site['site_label'],
                                          channel_label=site['channel_label'], now=now + timedelta(seconds=elapsed))
                if checked.get('adt_eye') is True:
                    identified = checked
                    break
                if checked.get('windows_desktop') is not True:
                    return fail('ADT-EYE 시작 중 확인 창 또는 다른 화면이 보여 멈췄어요: ' + checked.get('reason', '식별 불가'))
            else:
                return fail('ADT-EYE 켜기 시간 초과')

        if type(identified.get('layout_tabs')) is int and identified['layout_tabs'] == 0:
            found = locate('plus')
            if not found['ok']:
                return fail(found['reason'])
            screen.input(window, 'left', found['box'])
            screen.wait(LAYOUT_WAIT)
            elapsed += LAYOUT_WAIT
            capture = screen.capture(window, path.with_name(path.stem + '-layout.png'))
            checked = vision.identify(ask, capture, references, site_label=site['site_label'],
                                      channel_label=site['channel_label'], now=now + timedelta(seconds=elapsed))
            if checked.get('layout_tabs') is None or type(checked['layout_tabs']) is not int or checked['layout_tabs'] < 1:
                return fail('+ 뒤 레이아웃 탭이 생긴 것을 확인하지 못했어요.')
            if checked.get('adt_eye') is not True:
                return fail('ADT-EYE 화면이 아니에요.')
        expanded = -1
        for attempt in range(EXPAND_LIMIT + 1):
            found = locate('item')
            if found['ok']:
                break
            if attempt == EXPAND_LIMIT:
                break  # No more disclosure inputs; wait for the channel rows to become readable.
            triangle = locate('expand')
            if not triangle['ok']:
                break  # Includes an already expanded path. Waiting never emits another input.
            level = ('server', 'sites', 'site').index(triangle['evidence']['node'])
            if level <= expanded:
                return fail('목록 펼치기 순서를 확인하지 못했어요.')
            expanded = level
            screen.input(window, 'left', triangle['box'])
            screen.wait(LAYOUT_WAIT)
            elapsed += LAYOUT_WAIT
            capture = screen.capture(window, path.with_name(path.stem + f'-expand{attempt + 1}.png'))
        if not found['ok']:
            for poll in range(ITEM_POLLS):
                screen.wait(ITEM_WAIT)
                elapsed += ITEM_WAIT
                capture = screen.capture(window, path.with_name(path.stem + f'-item{poll + 1}.png'))
                found = locate('item')
                if found['ok']:
                    break
            else:
                return fail('채널 항목을 30초 기다린 뒤에도 안전한 위치를 확인하지 못했어요.')
        screen.input(window, 'right', found['box'])
        menu_open = True
        screen.wait(MENU_WAIT)
        elapsed += MENU_WAIT
        capture = screen.capture(window, path.with_name(path.stem + '-menu.png'))
        found = locate('live')
        if not found['ok']:
            menu_open = False  # Escape itself is never retried, even if it fails.
            screen.input(window, 'escape')
            return fail(found['reason'])
        menu_open = False
        screen.input(window, 'left', found['box'])
        screen.wait(LIVE_WAIT)
        elapsed += LIVE_WAIT
        capture = screen.capture(window, path.with_name(path.stem + '-relive.png'))
        identified = vision.identify(ask, capture, references, site_label=site['site_label'],
                                     channel_label=site['channel_label'], now=now + timedelta(seconds=elapsed))
        if not identified['ok']:
            return fail(identified['reason'])
        record['last_result'] = 'ok'
        return capture, identified
    except FocusFailed as error:
        record['last_result'] = str(error)
        _focus_alert(data, say, error)
        return capture, identified
    except (CaptureFailed, OSError) as error:
        if menu_open:
            try:
                screen.input(window, 'escape')
            except (CaptureFailed, OSError) as close_error:
                return fail(str(error) + '; Escape 실패:' + str(close_error))
        return fail(str(error))

    except BaseException:
        # Cancellation/overall deadline must unwind the session, never leave its menu open.
        if menu_open:
            screen.input(window, 'escape')
        raise


def _focus_alert(data, say, error):
    data['last_error'] = {'reason': str(error)}
    _alert(data, say, 'focus', "*🟡 낙화 CCTV 원격 화면 확인 필요*\n"
           "  • 원격 화면을 앞으로 가져오거나 캡처하지 못했어요. 다른 화면 공간에 있으면 Windows App의 세션 창을 한 번 앞으로 가져와 주세요.\n"
           "  • 오늘은 더 알리지 않아요.")

def _look(home, data, policy, site, screen, ask, say, path, now, save):
    """Capture and identify only. The scheduled caller owns reconnect proposals."""
    references = reference.photos(home, '기준구도', PHOTOS_PER_LABEL)
    try:
        window, capture = _grab(policy, site, screen, path)
    except FocusFailed as error:
        _focus_alert(data, say, error)
        return None, None
    except CaptureFailed as error:
        if str(error) != 'WINDOW_MISSING':
            _focus_alert(data, say, error)
            return None, None
        data['last_error'] = {'reason': str(error)}
        return None, None
    identified = vision.identify(ask, capture, references, site_label=site['site_label'],
                                 channel_label=site['channel_label'], now=now)
    if not identified['ok'] and identified['reason'] in RELIVE_REASONS:
        capture, identified = _relive(home, data, policy, site, screen, ask, say, path, now, capture, identified, references, window, save)
    return capture, identified


def check(home, *, data, policy, site, now, screen, ask, say, path, region=None, region_note=None, save=None, result=None):
    """One shared screen inspection, including its focus lease, permitted relive and classification.

    The caller owns watch.lock, persistence and any proposals. This function never opens a connection or writes a situation.
    `save` persists the shared relive budget before input; an owner request persists only that field.
    """
    result = {} if result is None else result
    result.update(scene=vision.UNREADABLE, reason='', identified=False, capture=None,
                  osd_time=None, checked_at=now.isoformat(timespec='seconds'), relived=False)
    before = data.get('relive', {}).get('count', 0) if data.get('relive', {}).get('date') == now.date().isoformat() else 0
    with screen.session(data) as view:
        capture, identified = _look(home, data, policy, site, view, ask, say, path, now, save)
        result['capture'] = str(capture) if capture else None
        record = data.get('relive', {})
        result['relived'] = record.get('date') == now.date().isoformat() and record.get('count', 0) > before
        if capture is None:
            result['reason'] = data.get('last_error', {}).get('reason', 'CAPTURE_FAILED')
            return result
        result.update(identified=identified['ok'], osd_time=identified.get('osd_time'))
        if not identified['ok']:
            result['reason'] = identified['reason']
        else:
            result.update(vision.classify(ask, capture, {scene: reference.photos(home, scene, PHOTOS_PER_LABEL)
                                                       for scene in vision.SCENES},
                                          box=identified.get('video_box'), region=region))
        if region_note:
            result['region'] = region_note
    return result


def _propose(home, policy, site, now, scene, reason, capture, current, proposals):
    """Post one proposal when the conditions hold; returns what happened."""
    rows = proposals.entries(day=now.date().isoformat(), action=ACTION)
    if any(row['args'].get('situation') == scene and row['status'] != 'post_failed' for row in rows):
        return 'already_proposed'
    if covered(scene, current):
        return 'already_recorded'
    hour, minute = map(int, policy['expires_at'].split(':'))
    expires = datetime.combine(now.date(), clock(hour, minute)).timestamp()
    try:
        proposals.post(action=ACTION, args={'situation': scene, 'unless_current': not_to_overwrite(scene)},
                       channel=site['customer_room'], text=_proposal_text(site, scene, reason, policy['expires_at']),
                       expires_at=expires, image=capture)
    except proposals.PostFailed:
        return 'post_failed'
    except proposals.PostUnconfirmed:
        return 'post_unconfirmed'
    older = [row['id'] for row in rows if row['status'] == 'pending' and PROGRESS.get(row['args'].get('situation'), 0) < PROGRESS[scene]]
    if older:
        proposals.supersede(older)
    return 'proposed'


def tick(home, *, policy, site, now, time_range, situation, screen, ask, proposals, say, region=None, region_note=None):
    """Run one wake-up. `now` is a naive local datetime. Returns a short status word."""
    day = now.date().isoformat()
    with state.locked(home) as free:
        if not free:
            return 'busy'
        before = json.dumps(state.read(home), sort_keys=True)
        data = state.load(home, day)
        try:
            span = time_range(policy['range_name'])
            if span is None:
                data['last_error'] = {'reason': 'TIME_RANGE_UNREADABLE', 'at': now.isoformat(timespec='seconds')}
                return 'no_range'
            slot = schedule.slot_of(now, span, policy['before_minutes'], policy['after_minutes'], policy['interval_minutes'])
            if slot is None:
                return 'outside'
            if data['last_slot'] == slot:
                return 'done'
            data['last_slot'] = slot
            state.save(home, data)
            state.prune(home, policy['capture_retention_days'], now.date())
            path = state.captures(home, day) / (now.strftime('%H%M%S') + '.png')
            result = check(home, data=data, policy=policy, site=site, now=now, screen=screen, ask=ask,
                           say=say, path=path, region=region, region_note=region_note)
            capture = result['capture']
            if result['reason'] in ('WINDOW_MISSING', ADT_EYE_LOST):
                _reconnect_ask(data, policy, site, now, schedule.window(
                    now.date(), span, policy['before_minutes'], policy['after_minutes'])[1],
                    '원격 화면 창이 없어요.' if capture is None else '원격 화면 창은 있지만 ADT-EYE 화면이 아니에요.',
                    capture, proposals, say)
            elif result['identified']:
                _close_reconnect_asks(proposals, now)
            if capture is None:
                return 'no_view'
            outcome = {key: result[key] for key in ('scene', 'reason', 'crop', 'region') if key in result}
            data['last_run'] = {'slot': slot, 'identified': result['identified'], **outcome}
            if outcome['scene'] == vision.UNREADABLE:
                data['consecutive_unread'] += 1
                if data['consecutive_unread'] >= policy['alert_after_failures']:
                    _alert(data, say, 'unread', f"*🟡 낙화 CCTV 확인 불가*\n  • {data['consecutive_unread']}회 연속 화면을 읽지 못했어요.\n"
                                                f"  • 사유: {outcome['reason']}\n  • 오늘은 더 알리지 않아요.")
                return 'unreadable'
            data['consecutive_unread'] = 0
            if outcome['scene'] not in PROPOSED:
                return 'normal'
            status = _propose(home, policy, site, now, outcome['scene'], outcome['reason'], capture, situation(), proposals)
            data['last_run']['proposal'] = status
            return status
        except Exception as error:
            data['last_error'] = {'reason': type(error).__name__, 'at': now.isoformat(timespec='seconds')}
            raise
        finally:
            if json.dumps(data, sort_keys=True) != before:
                state.save(home, data)


def run(*, time_range, situation, now=None):
    """The scheduled entry: real clock, policy, vault, window, model and Slack delivery."""
    from functools import partial
    from hermes_constants import get_hermes_home
    from hermes_governance import proposal_decisions
    from hermes_team_services import load
    from pathlib import Path
    from types import SimpleNamespace
    from . import screen as screen_module, settings

    policy = settings.policy()
    if policy is None:
        return 'off'
    home = Path(get_hermes_home())
    site = settings.site()
    reports = load('learning_report', 'cctv_learning_report')
    slack = partial(reports.slack, home)

    def say(text):
        slack('chat.postMessage', {'channel': site['customer_room'], 'text': text, 'unfurl_links': False})

    def device_screen():
        return screen_module.Session(site, policy)

    proposals = SimpleNamespace(
        entries=lambda **kw: proposal_decisions.entries(home, **kw),
        post=lambda **kw: proposal_decisions.post(
            home, slack=slack, upload=lambda channel, ts, path: reports.upload_image(home, channel, ts, path, '낙화 CCTV 캡처'), **kw),
        supersede=lambda ids: proposal_decisions.supersede(home, ids),
        PostFailed=proposal_decisions.PostFailed, PostUnconfirmed=proposal_decisions.PostUnconfirmed)
    region, region_note = settings.scene_region()
    return tick(home, policy=policy, site=site, now=now or datetime.now(), time_range=time_range, situation=situation,
                screen=device_screen(), ask=vision.model_caller(), proposals=proposals, say=say,
                region=region, region_note=region_note)
