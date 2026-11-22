"""Owner-only public-plugin decisions. Daily maintenance consumes durable Slack choices."""
from datetime import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import time
import uuid
from hermes_team_services import delivery as D


def module(name):
    spec = importlib.util.spec_from_file_location('starter_plugins_' + name, Path(__file__).with_name(name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


R = module('learning_report')
L = R.learning
# Owner decision 2026-10-31: the common buttons. 승인=공개, 거절=비공개, 확인=나중에(보류); 의견 asks what instead.
# The words of earlier reports still answer.
CHOICES = {'승인': 'public', '거절': 'private', '확인': 'later', '공개': 'public', '비공개': 'private', '나중에': 'later'}
DECIDE = '*결정 필요*\n승인=공개 · 거절=비공개 · 의견=다른 의견 · 확인=나중에(다음 날 다시 묻기)'
BUTTONS = '[[버튼: 승인 | 거절 | 의견 | 확인]]'


def today():
    return datetime.now(R.KST).date().isoformat()


def config(home):
    from ruamel.yaml import YAML
    raw = YAML(typ='safe').load((Path(home) / 'config.yaml').read_text()) or {}
    settings = raw.get('plugins', {}).get('entries', {}).get('team-kit', {}).get('settings', {})
    enabled = settings.get('starter_plugins', {}).get('enabled') is True
    channel = settings.get('report_channel', '')
    if enabled and D.platform(home) == 'hejo':
        channel = D.target(home, 'reports', slack=lambda: channel)
    elif enabled and not re.fullmatch(r'[CG][A-Z0-9]+', channel):
        raise ValueError('Missing report channel')
    return {'enabled': enabled, 'channel': channel}


def state_path(home):
    return Path(home) / 'starter_plugins/state.json'


def load(home):
    try:
        state = json.loads(state_path(home).read_text())
    except FileNotFoundError:
        return {'reports': {}, 'current': {}}
    if not isinstance(state, dict) or not isinstance(state.get('reports'), dict) or not isinstance(state.get('current'), dict):
        raise ValueError('Invalid starter plugin state; not replaced')
    return state


def quiet():
    """2026-10-28 사용자 결정: 04:30 정비의 질문·답글은 08:30 아침 보고 때 ``flush``가 올린다."""
    return module('morning_queue').quiet()


def send_hejo(home, state, report, part, key, thread):
    if quiet() and not part.get('delivery'):
        return
    if report.get('platform') != 'hejo':
        # A Slack receipt cannot identify either a native message or its thread.
        report.update(platform='hejo', channel=D.target(home, 'reports', slack=lambda: report['channel']), owner='owner')
        for field in ('thread_ts', 'thread', 'painted'):
            report.pop(field, None)
        for row in [report['root'], *report.get('processed', {}).values(), *report.get('results', {}).values()]:
            for field in ('ts', 'attempted_at'):
                row.pop(field, None)
        L.save(state_path(home), state)
    if thread and not report.get('thread'):
        root_key = next(k for k, r in state['reports'].items() if r is report)
        send_hejo(home, state, report, report['root'], root_key, False)
        if not report.get('thread'):
            return
    if part.get('message_id') or part.get('delivery_error'):
        return
    part.setdefault('client_id', 'starter-plugin:' + hashlib.sha256(key.encode()).hexdigest()[:40] + ':' + uuid.uuid4().hex)
    part.setdefault('delivery', {})
    save = lambda: L.save(state_path(home), state)
    save()
    try:
        receipt = D.post(home, report['channel'], client_id=part['client_id'], state=part['delivery'], save=save,
                         thread=report.get('thread') if thread else None, **D.presentation({'text': part['text']}))
    except D.Refused as exc:
        if not exc.permanent:
            raise
        part['delivery_error'] = exc.error
        save()
        return
    part.update(message_id=receipt['msg_id'], head_id=receipt['head_id'])
    if not thread:
        report['thread'] = receipt['thread']
    save()


def send(home, state, report, part, key, thread=False):
    if D.platform(home) == 'hejo':
        return send_hejo(home, state, report, part, key, thread)
    if report.get('platform') == 'hejo':
        return  # Native ids are never used in Slack calls.
    if part.get('ts'): return
    if quiet() and not part.get('attempted_at'): return
    if thread and not report.get('thread_ts'): return
    marker = 'starter_plugin_' + hashlib.sha256(key.encode()).hexdigest()[:40]
    recovery = report if thread else {k: v for k, v in report.items() if k != 'thread_ts'}
    ts = R.recover(home, recovery, part, marker) if part.get('attempted_at') else None
    if not ts:
        part['attempted_at'] = time.time()
        L.save(state_path(home), state)
        body = {'channel': report['channel'], 'text': part['text'], 'metadata': R.layout.metadata(marker),
                'parse': 'none', 'link_names': False, 'unfurl_links': False, 'unfurl_media': False}
        if thread: body['thread_ts'] = report['thread_ts']
        ts = str(R.slack(home, 'chat.postMessage', body)['ts'])
    part['ts'] = ts
    if not thread: report['thread_ts'] = ts
    L.save(state_path(home), state)


def paint(home, state, report, status, note):
    if D.platform(home) == 'hejo':
        if report.get('platform') != 'hejo' or not report.get('thread') or report.get('painted') == [status, note]:
            return
        requested = [status, note]
        report.setdefault('paint_pending', requested)
        status, note = report['paint_pending']
        L.save(state_path(home), state)
        root = report['root']
        final = status in ('done', 'declined')
        controls = D.presentation({'text': root['text']})
        controls['text'] += '\n\n' + note
        controls['reply_state'] = 'closed' if final else 'answered' if status == 'partial' else 'asked'
        if final:
            controls['buttons'] = []
        save = lambda: L.save(state_path(home), state)
        try:
            receipt = D.edit(home, report['channel'], state=root['delivery'], save=save, **controls)
        except D.Refused as exc:
            if not exc.permanent:
                raise
            root['edit_error'] = exc.error
            root['delivery'].pop('edit', None)
        else:
            root.update(message_id=receipt['msg_id'], head_id=receipt['head_id'])
        report['painted'] = [status, note]
        del report['paint_pending']
        save()
        if requested != [status, note]:
            paint(home, state, report, *requested)
        return
    if report.get('platform') == 'hejo':
        return
    if report.get('painted') == [status, note] or not report.get('thread_ts'): return
    L.extension('report_status').mark(lambda method, body: R.slack(home, method, body),
                                    report['channel'], report['thread_ts'], status, note)
    report['painted'] = [status, note]
    L.save(state_path(home), state)


def ask(home, pending):
    cfg = config(home)
    if not cfg['enabled']: return []
    owner = 'owner' if D.platform(home) == 'hejo' else R.owner(home)  # Native ownership comes from the authenticated ingress.
    posted = []
    with L.locked(state_path(home)):
        state = load(home)
        for item in pending:
            name = item['name']
            if not re.fullmatch(r'[a-z][a-z0-9-]*', name): raise ValueError('Invalid plugin name')
            key = state['current'].get(name)
            previous = state['reports'].get(key, {})
            if D.platform(home) == 'hejo' and previous.get('finished'):
                continue
            if previous and not (previous.get('decision') == 'later' and previous.get('decided_date', today()) < today()):
                if not previous.get('thread' if D.platform(home) == 'hejo' else 'thread_ts'):
                    send(home, state, previous, previous['root'], key)
                continue
            key = name + ':' + today()
            findings = item.get('findings', {})
            result = ', '.join(f'{kind} {count}건' for kind, count in sorted(findings.items())) if findings else '통과'
            text = (f'*🔴 새 플러그인 `{name}` 공개판 포함 여부*\n\n{DECIDE}\n\n*포함 후보*\n• 파일 {int(item["files"])}개\n'
                    f'\n*개인정보 검사*\n• {R.escape(result)}\n\n*반영 시점*\n• 소유자 결정은 다음 04:30 정비에서 반영한다. '
                    '공개 선택도 검사에 통과해야 게시한다. 나중에는 다음 날 다시 묻는다.\n' + BUTTONS)
            report = {'name': name, 'channel': cfg['channel'], 'owner': owner, 'day': today(),
                      'root': {'text': text}, 'processed': {}, 'button_replies': {}}
            state['reports'][key] = report
            state['current'][name] = key
            L.save(state_path(home), state)
            send(home, state, report, report['root'], key)
            posted.append(name)
    return posted


def messages(home, report):
    if D.platform(home) == 'hejo':
        if report.get('platform') != 'hejo' or not report.get('thread'):
            return []
        return D.read_thread(home, report['channel'], report['thread'])['messages']
    if report.get('platform') == 'hejo':
        return []
    body = {'channel': report['channel'], 'ts': report['thread_ts'], 'limit': 100}
    rows = []
    while True:
        data = R.slack(home, 'conversations.replies', body)
        rows.extend(data.get('messages', []))
        cursor = (data.get('response_metadata') or {}).get('next_cursor')
        if not cursor: return rows
        body['cursor'] = cursor


def skip_report_thread(home, event=None, **_):
    cfg = config(home)
    source = getattr(event, 'source', None)
    if not cfg['enabled'] or source is None: return None
    platform = str(getattr(getattr(source, 'platform', None), 'value', ''))
    if platform not in {'slack', 'hejo'} or platform != D.platform(home) or getattr(event, 'internal', False): return None
    native = platform == 'hejo'
    owner = 'owner' if native else R.owner(home)
    channel = D.target(home, 'reports', slack=None) if native else cfg['channel']
    if str(getattr(source, 'chat_id', '')) != channel or str(getattr(source, 'user_id', '')) != owner:
        return None
    thread = str(getattr(source, 'thread_id', '') or '')
    if not thread: return None
    with L.locked(state_path(home)):
        state = load(home)
        report = next((r for r in state['reports'].values() if r.get('platform', 'slack') == platform and r.get('thread' if native else 'thread_ts') == thread and r['channel'] == channel), None)
        if report is None: return None
        if not native and (getattr(event, 'raw_message', None) or {}).get('_hermes_button'):
            report['button_replies'][str(getattr(event, 'message_id', '') or time.time())] = {'text': str(getattr(event, 'text', '') or '')}
            L.save(state_path(home), state)
    return {'action': 'skip', 'reason': 'starter_plugins_thread'}


def collect(home):
    if not config(home)['enabled']: return []
    result = []
    native = D.platform(home) == 'hejo'
    owner = 'owner' if native else R.owner(home)
    with L.locked(state_path(home)):
        state = load(home)
        for key in state['current'].values():
            report = state['reports'][key]
            if report.get('platform', 'slack') != ('hejo' if native else 'slack'):
                continue
            if report.get('finished') or not report.get('thread' if native else 'thread_ts') or report['owner'] != owner: continue
            clicks = [] if native else [{'ts': ts, 'user': owner, **row} for ts, row in report['button_replies'].items()]
            for message in sorted(messages(home, report) + clicks, key=lambda row: row['seq'] if native else float(row['ts'])):
                ts = str(message['seq'] if native else message['ts'])
                is_owner = message.get('role') == 'owner' if native else message.get('user') == owner
                if not is_owner or message.get('subtype') or (not native and ts == report['thread_ts']) or ts in report['processed']:
                    continue
                choice = CHOICES.get(message.get('text', '').strip())
                if message.get('text', '').strip() == '의견':
                    # 의견 (owner, 2026-10-31): the owner writes the decision next; nothing is posted.
                    report['processed'][ts] = {'text': None}
                    L.save(state_path(home), state)
                    continue
                if choice:
                    report.update(decision=choice, decided_date=today())
                    text = '결정을 기록했어. 다음 정비에서 반영할게.' if choice != 'later' else '오늘은 미루고 다음 날 다시 물을게.'
                else:
                    text = '공개·비공개·나중에 중 하나로 다시 답해 줘.\n\n' + DECIDE + '\n' + BUTTONS
                report['processed'][ts] = {'text': text}
                L.save(state_path(home), state)
            for ts, part in report['processed'].items():
                if part.get('text') is None:
                    continue
                send(home, state, report, part, key + ':reply:' + ts, thread=True)
            if report.get('decision'):
                paint(home, state, report, 'partial', '소유자 결정 반영 중')
                if report['decision'] == 'later':
                    paint(home, state, report, 'done', '다음 날 다시 질문')
                    report['finished'] = True
                    L.save(state_path(home), state)
                else:
                    result.append({'name': report['name'], 'decision': report['decision'], 'date': report['decided_date']})
    return result


def finish(home, name, ok, note):
    if not config(home)['enabled']: return
    with L.locked(state_path(home)):
        state = load(home)
        key = state['current'].get(name)
        if not key: return
        report = state['reports'][key]
        if report.get('finished'): return
        if report.get('decision') not in {'public', 'private'}: raise ValueError('No owner decision')
        part_key = 'finish:' + str(bool(ok)) + ':' + note
        part = report.setdefault('results', {}).setdefault(part_key, {'text': ('*🟢 공개판 결정 반영 완료*' if ok else '*🔴 공개판 결정 반영 실패*') + '\n' + R.escape(note) + ('' if ok else '\n\n' + DECIDE + '\n' + BUTTONS)})
        send(home, state, report, part, key + ':' + part_key, thread=True)
        paint(home, state, report, 'done' if ok else 'failed', note)
        report['finished'] = bool(ok)
        L.save(state_path(home), state)


def flush(home):
    """08:30: post what the quiet hours held back (questions, decision replies, results) in order."""
    if not config(home)['enabled']: return 0
    count = 0
    with L.locked(state_path(home)):
        state = load(home)
        for key, report in sorted(state['reports'].items()):
            if not report['root'].get('ts'):
                send(home, state, report, report['root'], key); count += 1
            for ts, part in report.get('processed', {}).items():
                if not part.get('ts') and part.get('text') is not None:  # 의견 clicks post nothing
                    send(home, state, report, part, key + ':reply:' + ts, thread=True); count += 1
            for part_key, part in report.get('results', {}).items():
                if not part.get('ts'):
                    send(home, state, report, part, key + ':' + part_key, thread=True); count += 1
    return count
