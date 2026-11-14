"""Bind confirm/undo clicks to one durable app change and its owner conversation."""
import asyncio
import sqlite3
import time
from contextvars import copy_context
from pathlib import Path
from hermes_governance import app_group, app_tools, app_undo, write_policy

_RESTORERS = {}
_DECLARED = {}


def unlink_created(td,domain,target,context):
    if context.get('_bundle_component'):return {'ok':True}
    try:td._common_work_store().rollback_unlink_source(domain=domain,source_id=target)
    except (ValueError,OSError,sqlite3.Error) as error:
        return {'ok':False,'error':'APP_COMMON_WORK_CLEANUP_FAILED:'+type(error).__name__}
    return {'ok':True}


def register(ctx, home, kind, restore, *, target=None, line=None):
    """`target(entry)` names what a change touched (None when it cannot be named) and `line(entry)` words it
    as (action, subject); together they let several changes of one request fold into one receipt line."""
    home = Path(home)
    _RESTORERS.setdefault(str(home), {})[kind] = restore
    _DECLARED.setdefault(str(home), {})[kind] = dict(target=target, line=line)
    if getattr(ctx, '_app_result_hook', False): return
    ctx._app_result_hook = True
    async def hook(event=None, gateway=None, **context):
        return await dispatch(home,event,gateway)
    ctx.register_hook('pre_gateway_dispatch',hook)


def declared(home):
    return _DECLARED.get(str(Path(home)), {})


def source_values(source):
    platform = getattr(getattr(source,'platform',None),'value',getattr(source,'platform',''))
    return {'HERMES_SESSION_'+key:value for key,value in {
        'PLATFORM':str(platform), 'USER_ID':str(getattr(source,'user_id','') or ''),
        'CHAT_ID':str(getattr(source,'chat_id','') or ''), 'THREAD_ID':str(getattr(source,'thread_id','') or '')}.items()}


def _title(done, text):
    return ('*🟢 ' if done else '*🔴 ') + '앱 쓰기 결과*\n' + text


def _reason(result):
    error = result.get('error')
    return '그 뒤 바뀌었어요' if error == 'UNDO_CONFLICT' else str(error or result)


def _restore(home, source, restorers, chain):
    """Run the restore function of a chain's creation (or of its single entry) the way a button click does."""
    subject = app_group.folded(chain)
    # scope_id is gateway bookkeeping; the four authenticated conversation fields matched.
    env = dict(source, HERMES_SESSION_SCOPE_ID=app_group.recorded(chain[0]).get('scope_id', ''))
    from hermes_constants import set_hermes_home_override, reset_hermes_home_override
    token = set_hermes_home_override(home)
    try:
        # Legacy native session setters clear their bindings rather than restore outer tokens. Keep that
        # compatibility bridge in a child context so a button cannot erase the active gateway conversation.
        with app_tools.source(env): return copy_context().run(restorers[chain[0]['journal_kind']], subject)
    finally: reset_hermes_home_override(token)


def decide(home, ref, label, source, *, clock=None):
    """Only gateway-authenticated callers enter here; owner identity is checked again.
    `ref` is a group id, or the key of one entry (a receipt posted before groups existed).
    Everything that can refuse the group is judged before the first restore."""
    now = (clock or time.time)()
    with app_tools.source(source):
        if not write_policy.owner_chat(home,app_tools.env): raise ValueError('APP_OWNER_CHAT_REQUIRED')
        with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home),clock=clock) as (data,save):
            group, members = app_group.find(data['entries'], ref)
            actual = app_tools.conversation()
            if any(app_group.recorded(e).get(k,'') != actual[k] for e in members for k in app_group.FIELDS):
                raise ValueError('OTHER_CONVERSATION')
            if not 0 <= now - group['oldest_at'] < app_undo.RETENTION: raise ValueError(app_group.EXPIRED)
            live = [e for e in members if not e.get('consumed')]
            if not live:
                if group['id'] is None: raise ValueError(app_group.EXPIRED)  # a receipt from before groups: as it always answered
                return _title(True, '이미 되돌렸어요.')
            if label == '확인':
                for e in live: e['confirmed'] = True
                save()
                return _title(True, '변경 내용을 확인했어요.')
            if label == '거절' and any(e.get('undo_pending') for e in live):
                for e in live: e.pop('undo_pending', None)
                save()
                return _title(True, '되돌리지 않고 그대로 두었어요.')
            if label not in ('되돌리기','승인'): raise ValueError('APP_BUTTON_INVALID')
            if label == '승인' and not all(e.get('undo_pending') is True for e in live): raise ValueError('APP_BUTTON_INVALID')
            if app_group.missing(group, members):
                return _title(False, '일부 기록이 정리돼 묶음을 되돌릴 수 없어요. 아무것도 되돌리지 않았어요.')
            restorers = _RESTORERS.get(str(Path(home)),{})
            if any(e['journal_kind'] not in restorers for e in live): raise ValueError('APP_UNDO_UNAVAILABLE')
            kinds = declared(home)
            try: plan = app_group.plan(live, kinds)
            except app_group.Refused as refusal: return _title(False, str(refusal))
            reasons = {app_undo.authorization(e, app_group.recorded(e), approved=label == '승인', clock=clock) for e in live}
            if 'UNDO_EXPIRED' in reasons: raise ValueError(app_group.EXPIRED)
            if 'UNDO_APPROVAL_REQUIRED' in reasons:
                for e in live: e['undo_pending'] = True
                save()
                where = ('묶음 번호: ' + group['id']) if group['id'] else '변경 번호: ' + live[0]['key']
                items = ''.join('• ' + app_group.line(chain, kinds) + '\n' for chain in app_group.chains(live, kinds))
                return '*🔴 앱 되돌리기 승인*\n30분이 지났어요. 이 변경을 되돌릴까요?\n' + items + where + '\n[[버튼: 승인 | 거절]]'
            kept, restored = [], []
            for chain in plan:
                try: result = _restore(home, source, restorers, chain)
                except Exception as error:
                    # A lone change keeps raising as it always did. Among several, one target failing must not
                    # stop the others; its reason is reported with the ones left as they were.
                    if len(plan) == 1: raise
                    result = {'ok': False, 'error': str(error) if isinstance(error, ValueError) else type(error).__name__}
                # A pack may publish through a nested partition and replace row objects.
                rows = [next(e for e in data['entries'] if e.get('key') == c['key']) for c in chain]
                if result.get('ok'):
                    for row in rows: row['consumed'] = True; row.pop('undo_pending', None)
                    restored.append(chain)
                else: kept.append((chain, result))
                save()
            for chain, _ in kept:
                for c in chain:
                    next(e for e in data['entries'] if e.get('key') == c['key']).pop('undo_pending', None)
            save()
            if not kept: return _title(True, '변경을 되돌렸어요.\n' + ''.join('• ' + app_group.line(chain, kinds) + '\n' for chain in restored))
            text = ('일부만 되돌렸어요. ' if restored else '') + '그 뒤 바뀌었거나 확인하지 못한 항목은 그대로 두었어요.\n'
            text += ''.join('• 되돌림 · ' + app_group.line(chain, kinds) + '\n' for chain in restored)
            text += ''.join('• 그대로 둠 · ' + app_group.line(chain, kinds) + ' — ' + _reason(result) + '\n' for chain, result in kept)
            return _title(False, text.rstrip('\n'))


def pending_in_thread(entries, conversation, label, home, *, clock=None):
    """Group ids (or keys of single entries) a bare owner word can only mean in this thread (ddots sends a
    lone post's button as the word). 되돌리기 matches a delivered, live receipt; 승인/거절 match a waiting
    undo approval. 확인 is left to the agent."""
    now=(clock or time.time)()
    kinds=_RESTORERS.get(str(Path(home)),{})
    def mine(entry):
        recorded=entry.get('app_conversation',entry.get('conversation')) or {}
        return (entry.get('journal_kind') in kinds and not entry.get('consumed')
                and all(recorded.get(k,'')==conversation[k] for k in app_group.FIELDS)
                and 0<=now-entry.get('created_at',0)<app_undo.RETENTION)
    if label=='되돌리기': found=[e for e in entries if mine(e) and e.get('notified') and not e.get('undo_pending')]
    elif label in ('승인','거절'): found=[e for e in entries if mine(e) and e.get('undo_pending') is True]
    else: return []
    return list(dict.fromkeys((e.get('receipt_group') or {}).get('id') or e['key'] for e in found))


async def dispatch(home, event, gateway):
    if getattr(event,'_app_result_handled',False) or getattr(event,'internal',False): return None
    button = (getattr(event,'raw_message',None) or {}).get('_hermes_button')
    label=str(getattr(event,'text','')).strip()
    key=None
    if isinstance(button,dict):
        if label != button.get('label'): return None
        message = button.get('message_text','')
        if not isinstance(message,str) or not any(title in message for title in ('앱 쓰기 결과','앱 되돌리기 승인')): return None
        match=app_group.GROUP.search(message) or app_group.SINGLE.search(message)
        if not match: return None
        key=match[1]
    elif label not in ('되돌리기','승인','거절'):
        return None
    source=getattr(event,'source',None)
    if gateway is None or source is None: return None
    if key is None and not str(getattr(source,'thread_id','') or ''): return None
    # This hook precedes the gateway's ordinary admission: invoke the same auth check first.
    if not gateway._is_user_authorized_for_source(source): return None
    values=source_values(source)
    with app_tools.source(values):
        if not write_policy.owner_chat(home,app_tools.env): return None
        conversation=app_tools.conversation()
    path=app_undo.path_for(home)
    if not path.is_file(): return None
    existing=app_undo._read(path)
    text=None
    if key is None:
        refs=pending_in_thread(existing.get('entries',[]),conversation,label,home)
        if not refs: return None
        if len(refs)>1:
            text='*🔴 앱 쓰기 결과*\n이 스레드에 되돌릴 수 있는 변경이 여러 개예요. 되돌릴 글의 버튼을 눌러 주세요.'
        else:key=refs[0]
    if key is not None:
        try:members=app_group.find(existing.get('entries',[]),key)[1]
        except ValueError:return None
        if not any(e.get('journal_kind') in _RESTORERS.get(str(Path(home)),{}) for e in members): return None
    event._app_result_handled=True
    if text is None:
        try:
            text=await asyncio.to_thread(decide,home,key,label,values)
        except (ValueError,OSError,KeyError) as error:
            text='*🔴 앱 쓰기 결과*\n되돌리지 않았어요. '+str(error)
    adapter=gateway._delivery_adapter_for(source)
    if adapter is None: raise ValueError('APP_RESULT_DELIVERY_UNAVAILABLE')
    await adapter.send(str(source.chat_id),text,metadata=gateway._thread_metadata_for_source(source))
    return {'action':'skip','reason':'app result decision handled'}
