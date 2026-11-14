"""Owner-button decisions for changes that a background job may only propose.

A background job posts one proposal to a Slack room and records it in the staff locker
(`state/proposals.json`). Nothing changes until the owner presses a button on that post: this module
checks who pressed it, in which thread, and whether the proposal is still open, then calls the
executor a plugin registered for the proposal's action. The job never calls an executor itself.
"""
import asyncio
import contextlib
import fcntl
import json
import os
import re
import tempfile
import time
import uuid
from pathlib import Path

from hermes_governance import app_results, app_tools, write_policy

LABELS = ('승인', '거절', '의견', '확인')
BUTTONS = '[[버튼: 승인 | 거절 | 의견 | 확인]]'
MARKER = re.compile(r'(?:^|\n)제안 번호: ([0-9a-f]{32})(?:\n|$)')
APPLYING_STALE_SECONDS = 300
OPEN = ('posting', 'pending')

_EXECUTORS = {}


class PostFailed(Exception):
    """Slack refused the post: nothing was posted, so the caller may try again."""


class PostUnconfirmed(Exception):
    """The post may or may not have reached Slack: never post it again."""


def ledger_path(home):
    return Path(home) / 'state' / 'proposals.json'


def _read(path):
    if not path.exists():
        return {'version': 1, 'entries': []}
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('entries'), list):
        raise ValueError('PROPOSALS_LEDGER_INVALID')
    return data


@contextlib.contextmanager
def ledger(home):
    """Locked read-modify-write of the ledger; an unreadable ledger is never replaced."""
    path = ledger_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = _read(path)

        def save():
            fd, temporary = tempfile.mkstemp(prefix='.proposals-', dir=path.parent)
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                    json.dump(data, stream, ensure_ascii=False, indent=1)
                    stream.write('\n')
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        yield data['entries'], save


def register_executor(home, action, run, verify, manual_hint=''):
    """`run(args, entry)` returns {'status': 'applied'|'refused', 'message': str} or raises.
    `verify(entry)` says whether an interrupted run left its result behind. `manual_hint` tells the
    owner what to do by hand when the outcome is unknown."""
    _EXECUTORS.setdefault(str(Path(home)), {})[action] = (run, verify, manual_hint)


def _executor(home, action):
    return _EXECUTORS.get(str(Path(home)), {}).get(action)


def _scoped(home, call, *arguments):
    """Run an executor under the staff member's home, as a gateway thread would not carry it."""
    from hermes_constants import set_hermes_home_override, reset_hermes_home_override
    token = set_hermes_home_override(home)
    try:
        return call(*arguments)
    finally:
        reset_hermes_home_override(token)


def entries(home, *, day=None, action=None):
    with ledger(home) as (rows, _):
        return [dict(row) for row in rows
                if (day is None or row.get('day') == day) and (action is None or row.get('action') == action)]


def supersede(home, ids):
    """Close open proposals that a newer one replaces; their buttons then answer that they were replaced."""
    with ledger(home) as (rows, save):
        changed = False
        for row in rows:
            if row['id'] in ids and row['status'] == 'pending':
                row['status'] = 'superseded'
                changed = True
        if changed:
            save()


def day_of(moment):
    return time.strftime('%Y-%m-%d', time.localtime(moment))


def post(home, *, action, args, channel, text, expires_at, slack, upload=None, image=None, clock=None):
    """Post a proposal with the fixed button set and record it as pending.

    `slack(method, body)` and `upload(channel, thread_ts, path)` are the caller's Slack delivery path.
    The ledger row is written before the post so that an unconfirmed post is never repeated; a
    refused post is marked and may be tried again. A failed image upload does not undo the proposal."""
    now = (clock or time.time)()
    recover(home, clock=clock)
    key = uuid.uuid4().hex
    with ledger(home) as (rows, save):
        rows.append({'id': key, 'action': action, 'args': args, 'channel': channel, 'message_ts': None,
                     'posted_at': now, 'day': day_of(now), 'expires_at': expires_at, 'status': 'posting'})
        save()
    body = {'channel': channel, 'text': f'{text}\n제안 번호: {key}\n{BUTTONS}', 'unfurl_links': False, 'unfurl_media': False}
    try:
        reply = slack('chat.postMessage', body)
        ts = str(reply['ts'])
    except RuntimeError as error:
        if str(error).startswith('Slack refused'):
            _settle(home, key, 'post_failed')
            raise PostFailed(str(error)) from error
        raise PostUnconfirmed(type(error).__name__) from error
    except Exception as error:
        raise PostUnconfirmed(type(error).__name__) from error
    with ledger(home) as (rows, save):
        row = next(item for item in rows if item['id'] == key)
        row.update(message_ts=ts, status='pending')
        save()
    uploaded = None
    if image is not None and upload is not None:
        try:
            upload(channel, ts, image)
            uploaded = True
        except Exception:
            uploaded = False
    return {'id': key, 'message_ts': ts, 'image_posted': uploaded}


def _settle(home, key, status, **extra):
    with ledger(home) as (rows, save):
        row = next(item for item in rows if item['id'] == key)
        row.update(status=status, **extra)
        save()


def recover(home, *, clock=None):
    """A run that stopped halfway (`applying` for over five minutes) is settled by asking its executor
    whether the result is there. `failed` is final: it is never reopened for another press."""
    now = (clock or time.time)()
    with ledger(home) as (rows, save):
        changed = False
        for row in rows:
            if row['status'] != 'applying' or now - row.get('applying_at', 0) < APPLYING_STALE_SECONDS:
                continue
            found = _executor(home, row['action'])
            row['status'] = 'applied' if found and _scoped(home, found[1], row) else 'failed'
            row['settled_at'] = now
            changed = True
        if changed:
            save()


def _title(done, heading):
    # These replies go out through the gateway's adapter.send, which converts standard markdown:
    # "**x**" is the bold title Slack shows, while "*x*" would come out italic.
    return f"**{'🟢' if done else '🔴'} {heading}**\n"


def decide(home, entry_id, label, source, *, clock=None):
    """Validate one press and carry it out. Returns (reply text or None, whether the press was handled).

    Only gateway-authenticated callers get here. The owner is proven again from the pressing identity."""
    now = (clock or time.time)()
    with app_tools.source(source):
        owner = write_policy.owner_chat(home, app_tools.env)
        chat, thread_id = app_tools.env('HERMES_SESSION_CHAT_ID'), app_tools.env('HERMES_SESSION_THREAD_ID')
    recover(home, clock=clock)
    with ledger(home) as (rows, save):
        row = next((item for item in rows if item['id'] == entry_id), None)
        if row is None:
            raise ValueError('PROPOSAL_UNKNOWN')
        refusal = None
        if not owner:
            refusal = '소유자만 누를 수 있는 버튼이에요.'
        elif chat != row['channel'] or thread_id != row['message_ts']:
            refusal = '이 제안 글의 스레드에서 누른 버튼만 처리해요.'
        if refusal:
            return _title(False, '제안 처리 안 됨') + refusal + ' 아무것도 바꾸지 않았어요.'
        if label == '의견':
            return None
        status = row['status']
        if status != 'pending':
            reasons = {'applying': '이미 처리 중이에요.', 'applied': '이미 반영했어요.',
                       'rejected': '이미 거절했어요.', 'held': '이미 확인만 하고 두었어요.',
                       'superseded': '더 새로운 제안으로 대체됐어요.', 'refused': '이미 반영하지 않기로 했어요.',
                       'failed': '이 제안은 반영 여부를 확인하지 못해 닫았어요.'}
            return _title(False, '제안 처리 안 됨') + reasons.get(status, '열려 있는 제안이 아니에요.') + ' 아무것도 바꾸지 않았어요.'
        if now >= row['expires_at']:
            row['status'] = 'expired'
            save()
            return _title(False, '제안 처리 안 됨') + '유효 시간이 지났어요. 아무것도 바꾸지 않았어요.'
        if label == '거절':
            row.update(status='rejected', settled_at=now)
            save()
            return _title(True, '제안 처리') + '거절했어요. 아무것도 바꾸지 않았고 같은 제안은 오늘 다시 올리지 않아요.'
        if label == '확인':
            row.update(status='held', settled_at=now)
            save()
            return _title(True, '제안 처리') + '확인만 했어요. 아무것도 바꾸지 않았고 같은 제안은 오늘 다시 올리지 않아요.'
        found = _executor(home, row['action'])
        if found is None:
            return _title(False, '제안 처리 안 됨') + '이 제안을 처리할 기능이 꺼져 있어요. 아무것도 바꾸지 않았어요.'
        row.update(status='applying', applying_at=now)
        save()
        args = dict(row['args'])
        snapshot = dict(row)
    try:
        result = _scoped(home, found[0], args, snapshot)
        outcome = result['status']
        if outcome not in ('applied', 'refused'):
            raise ValueError('PROPOSAL_EXECUTOR_RESULT')
    except Exception as error:
        _settle(home, entry_id, 'failed', settled_at=now, error=type(error).__name__)
        hint = found[2]
        return _title(False, '제안 처리 안 됨') + '기록 여부를 확인하지 못했어요.' + (' ' + hint if hint else '')
    _settle(home, entry_id, outcome, settled_at=now)
    return _title(outcome == 'applied', '제안 처리') + str(result.get('message', ''))


def _event_parts(event):
    button = (getattr(event, 'raw_message', None) or {}).get('_hermes_button')
    label = str(getattr(event, 'text', '')).strip()
    return (button if isinstance(button, dict) else None), label


def thread_parent_text(home, chat, thread):
    """Text of the post that opened a Slack thread (the post's own text keeps its proposal marker)."""
    from hermes_team_services import load
    reply = load('learning_report', 'proposal_learning_report').slack(
        home, 'conversations.replies', {'channel': chat, 'ts': thread, 'limit': 1})
    return str(reply['messages'][0].get('text', ''))


def _owner_room():
    from hermes_facility import owner_vault
    return owner_vault.text('channels.customer_room')


def _unreadable_means_ours(home, button, label, source, fetch_parent):
    """The ledger cannot be read: is this press one of ours (so it must fail closed)?
    A button is ours when its post carries the proposal marker. A word typed in a thread is ours when the
    thread's first post carries the marker; when that post cannot be looked up, a typed approval in the
    owner room is treated as ours rather than let a model record it."""
    if button is not None:
        message = button.get('message_text', '')
        return isinstance(message, str) and bool(MARKER.search(message))
    thread, chat = str(getattr(source, 'thread_id', '') or ''), str(getattr(source, 'chat_id', '') or '')
    if not thread:
        return False
    try:
        return bool(MARKER.search(fetch_parent(home, chat, thread)))
    except Exception:
        try:
            return label == '승인' and bool(chat) and chat == _owner_room()
        except Exception:
            return False


def _locate(home, button, label, source, fetch_parent):
    """The ledger row a press belongs to: its button's post, or the one open proposal of a thread
    that a bare label was typed in. An unreadable ledger fails closed for presses that are ours."""
    thread = str(getattr(source, 'thread_id', '') or '')
    try:
        with ledger(home) as (rows, _):
            if button is not None:
                return next((dict(row) for row in rows if row.get('message_ts') == button.get('message_ts')), None), False
            found = [dict(row) for row in rows if thread and row.get('message_ts') == thread]
            return (found[0] if len(found) == 1 else None), False
    except Exception:
        return None, _unreadable_means_ours(home, button, label, source, fetch_parent)


def _claim(home, event, fetch_parent):
    """What the facility makes of an event: None when it is not a proposal press, else (row, unreadable) where
    `row` is the proposal it belongs to and `unreadable` means the ledger could not be read for a press that is ours."""
    button, label = _event_parts(event)
    if label not in LABELS or (button is not None and label != button.get('label')):
        return None
    source = getattr(event, 'source', None)
    if source is None:
        return None
    row, unreadable = _locate(home, button, label, source, fetch_parent)
    return None if row is None and not unreadable else (row, unreadable)


def owns(home, event, *, fetch_parent=thread_parent_text):
    """True when the facility's own `pre_gateway_dispatch` hook takes this event: a press of a proposal's button or
    a bare label typed in a proposal's thread (same test as `dispatch`, so an unreadable ledger counts as ours;
    who pressed is not asked here, the facility's hook answers that).

    The core applies only the first `rewrite` of a message and lets it hide a later `skip`. Any other hook that can
    rewrite a message must therefore return nothing for an event this says is ours, or the press reaches the model.
    Blocking: it reads the ledger (and, for a typed word with an unreadable ledger, Slack)."""
    if getattr(event, '_proposal_handled', False):
        return True
    if getattr(event, 'internal', False):
        return False
    return _claim(home, event, fetch_parent) is not None


async def dispatch(home, event, gateway, *, clock=None, fetch_parent=thread_parent_text):
    if getattr(event, '_proposal_handled', False) or getattr(event, 'internal', False):
        return None
    source = getattr(event, 'source', None)
    if gateway is None or source is None or not gateway._is_user_authorized_for_source(source):
        return None
    claim = await asyncio.to_thread(_claim, home, event, fetch_parent)
    if claim is None:
        return None
    row, unreadable = claim
    _, label = _event_parts(event)
    event._proposal_handled = True
    if unreadable:
        text = _title(False, '제안 처리 안 됨') + '제안 장부를 읽지 못했어요. 아무것도 바꾸지 않았어요.'
    else:
        try:
            text = await asyncio.to_thread(decide, home, row['id'], label, app_results.source_values(source), clock=clock)
        except Exception as error:
            text = _title(False, '제안 처리 안 됨') + type(error).__name__ + ' 아무것도 바꾸지 않았어요.'
    if text is not None:
        adapter = gateway._delivery_adapter_for(source)
        if adapter is None:
            raise ValueError('PROPOSAL_DELIVERY_UNAVAILABLE')
        await adapter.send(str(source.chat_id), text, metadata=gateway._thread_metadata_for_source(source))
    return {'action': 'skip', 'reason': 'proposal decision handled'}


def register(ctx, home):
    home = Path(home)
    if getattr(ctx, '_proposal_hook', False):
        return

    async def hook(event=None, gateway=None, **context):
        return await dispatch(home, event, gateway)
    ctx._proposal_hook = True
    ctx.register_hook('pre_gateway_dispatch', hook)
