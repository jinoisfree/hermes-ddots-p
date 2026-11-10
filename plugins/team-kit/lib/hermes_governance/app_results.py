"""Bind confirm/undo clicks to one durable app change and its owner conversation."""
import asyncio
import re
import sqlite3
import time
from contextvars import copy_context
from pathlib import Path
from hermes_governance import app_tools, app_undo, write_policy

_RESTORERS = {}
KEY = re.compile(r'(?:^|\n)변경 번호: ([0-9a-f]{32})(?:\n|$)')


def unlink_created(td,domain,target,context):
    if context.get('_bundle_component'):return {'ok':True}
    try:td._common_work_store().rollback_unlink_source(domain=domain,source_id=target)
    except (ValueError,OSError,sqlite3.Error) as error:
        return {'ok':False,'error':'APP_COMMON_WORK_CLEANUP_FAILED:'+type(error).__name__}
    return {'ok':True}


def register(ctx, home, kind, restore):
    home = Path(home)
    _RESTORERS.setdefault(str(home), {})[kind] = restore
    if getattr(ctx, '_app_result_hook', False): return
    ctx._app_result_hook = True
    async def hook(event=None, gateway=None, **context):
        return await dispatch(home,event,gateway)
    ctx.register_hook('pre_gateway_dispatch',hook)


def source_values(source):
    platform = getattr(getattr(source,'platform',None),'value',getattr(source,'platform',''))
    return {'HERMES_SESSION_'+key:value for key,value in {
        'PLATFORM':str(platform), 'USER_ID':str(getattr(source,'user_id','') or ''),
        'CHAT_ID':str(getattr(source,'chat_id','') or ''), 'THREAD_ID':str(getattr(source,'thread_id','') or '')}.items()}


def decide(home, key, label, source, *, clock=None):
    """Only gateway-authenticated callers enter here; owner identity is checked again."""
    with app_tools.source(source):
        if not write_policy.owner_chat(home,app_tools.env): raise ValueError('APP_OWNER_CHAT_REQUIRED')
        with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home),clock=clock) as (data,save):
            entry = next((e for e in data['entries'] if e.get('key')==key),None)
            if entry is None: raise ValueError('UNDO_EXPIRED')
            recorded = entry.get('app_conversation',entry.get('conversation',{}))
            actual = app_tools.conversation()
            if any(recorded.get(k,'') != actual[k] for k in ('platform','user_id','chat_id','thread_id')):
                raise ValueError('OTHER_CONVERSATION')
            reason=app_undo.authorization(entry,recorded,approved=label=='승인' and entry.get('undo_pending') is True,clock=clock)
            if reason not in ('OK','UNDO_APPROVAL_REQUIRED'): raise ValueError(reason)
            if label=='확인':
                entry['confirmed']=True; save()
                return '*🟢 앱 쓰기 결과*\n변경 내용을 확인했어요.'
            if label=='거절' and entry.get('undo_pending'):
                entry.pop('undo_pending'); save()
                return '*🟢 앱 쓰기 결과*\n되돌리지 않고 그대로 두었어요.'
            if label not in ('되돌리기','승인'): raise ValueError('APP_BUTTON_INVALID')
            if reason=='UNDO_APPROVAL_REQUIRED':
                if label!='되돌리기': raise ValueError('APP_BUTTON_INVALID')
                entry['undo_pending']=True;save()
                return '*🔴 앱 되돌리기 승인*\n30분이 지났어요. 이 변경을 되돌릴까요?\n변경 번호: '+key+'\n[[버튼: 승인 | 거절]]'
            if label=='승인' and not entry.get('undo_pending'): raise ValueError('APP_BUTTON_INVALID')
            restore = _RESTORERS.get(str(Path(home)),{}).get(entry['journal_kind'])
            if restore is None: raise ValueError('APP_UNDO_UNAVAILABLE')
            # scope_id is gateway bookkeeping; the four authenticated conversation fields matched.
            env = dict(source,HERMES_SESSION_SCOPE_ID=recorded.get('scope_id',''))
            from hermes_constants import set_hermes_home_override,reset_hermes_home_override
            token=set_hermes_home_override(home)
            try:
                # Legacy native session setters clear their bindings rather than
                # restore outer tokens. Keep that compatibility bridge in a child
                # context so a button cannot erase the active gateway conversation.
                with app_tools.source(env): result=copy_context().run(restore,entry)
            finally: reset_hermes_home_override(token)
            # A pack may publish through a nested partition and replace row objects.
            entry=next(e for e in data['entries'] if e.get('key')==key)
            if result.get('ok'):

                entry['consumed']=True;entry.pop('undo_pending',None);save()
                return '*🟢 앱 쓰기 결과*\n변경을 되돌렸어요.'
            save()
            return '*🔴 앱 쓰기 결과*\n그 뒤 바뀌었거나 확인하지 못한 항목은 그대로 두었어요. 결과: '+str(result)


FIELDS=('platform','user_id','chat_id','thread_id')


def pending_in_thread(entries, conversation, label, home, *, clock=None):
    """Keys a bare owner word can only mean in this thread (ddots sends a lone post's button as the word).
    되돌리기 matches a delivered, live receipt; 승인/거절 match a waiting undo approval. 확인 is left to the agent."""
    now=(clock or time.time)()
    kinds=_RESTORERS.get(str(Path(home)),{})
    def mine(entry):
        recorded=entry.get('app_conversation',entry.get('conversation')) or {}
        return (entry.get('journal_kind') in kinds and not entry.get('consumed')
                and all(recorded.get(k,'')==conversation[k] for k in FIELDS)
                and 0<=now-entry.get('created_at',0)<app_undo.RETENTION)
    if label=='되돌리기':
        return [e['key'] for e in entries if mine(e) and e.get('notified') and not e.get('undo_pending')]
    if label in ('승인','거절'):
        return [e['key'] for e in entries if mine(e) and e.get('undo_pending') is True]
    return []


async def dispatch(home, event, gateway):
    if getattr(event,'_app_result_handled',False) or getattr(event,'internal',False): return None
    button = (getattr(event,'raw_message',None) or {}).get('_hermes_button')
    label=str(getattr(event,'text','')).strip()
    key=None
    if isinstance(button,dict):
        if label != button.get('label'): return None
        message = button.get('message_text','')
        if not isinstance(message,str) or not any(title in message for title in ('앱 쓰기 결과','앱 되돌리기 승인')): return None
        match=KEY.search(message)
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
        keys=pending_in_thread(existing.get('entries',[]),conversation,label,home)
        if not keys: return None
        if len(keys)>1:
            text='*🔴 앱 쓰기 결과*\n이 스레드에 되돌릴 수 있는 변경이 여러 개예요. 되돌릴 글의 버튼을 눌러 주세요.'
        else:key=keys[0]
    if key is not None:
        found=next((e for e in existing.get('entries',[]) if e.get('key')==key),None)
        if found is None or found.get('journal_kind') not in _RESTORERS.get(str(Path(home)),{}): return None
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
