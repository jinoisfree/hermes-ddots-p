"""Deliver app journal receipts through the one final-answer output pipeline.

Turn boundaries and native approval responses are runtime context. Delivery
state belongs to each existing undo entry, never to a second journal.
"""
import json
from pathlib import Path
import threading
import time
from hermes_governance import app_group, app_tools, app_undo, app_results, write_policy

APPROVED='소유자가 승인 화면에서 승인한 뒤 실행했어요.'
DENIED='소유자가 승인 화면에서 거절해 실행하지 않았어요.'
_LOCK=threading.RLock()
_TURNS={}
_DECISIONS={}


def home():
    from hermes_constants import get_hermes_home
    return Path(get_hermes_home())


def identity(session_id,turn_id):return (str(home()),session_id,turn_id)


def begin(*,session_id='',turn_id='',**_):
    if not session_id or not turn_id or not write_policy.owner_chat(home(),app_tools.env):return
    with _LOCK:
        _TURNS.setdefault(identity(session_id,turn_id),dict(at=time.time(),conversation=app_tools.conversation()))


def ended(*,session_id='',turn_id='',**_):
    key=identity(session_id,turn_id)
    with _LOCK:
        _TURNS.pop(key,None)
        for call in list(_DECISIONS):
            if call[:3]==key:_DECISIONS.pop(call,None)


def ready(entry):
    if 'app_ready' in entry:return entry['app_ready'] is True
    status=entry.get('status');kind=entry.get('journal_kind')
    if status=='done':return True
    if kind=='mac_app' and status=='applied':return bool(entry.get('inverse') and entry.get('after'))
    return kind=='files' and status=='partial' and bool(entry.get('after'))


def output(*,response_text='',session_id='',turn_id='',**_):
    """One post for the whole request: every new reversible change of this turn, each target on one line."""
    if not isinstance(response_text,str) or not write_policy.owner_chat(home(),app_tools.env):return
    with _LOCK:started=_TURNS.get(identity(session_id,turn_id))
    who=app_tools.conversation()
    if not started or any(started['conversation'].get(k,'')!=who[k] for k in app_group.FIELDS):return
    path=app_undo.path_for(home())
    if not path.is_file():return
    with app_undo.ledger(path) as (data,save):
        fresh=[]
        for entry in data['entries']:
            if (entry.get('created_at',0)<started['at'] or entry.get('notified')
                    or entry.get('consumed') or entry.get('reference_only')
                    or not ready(entry)
                    or any(app_group.recorded(entry).get(k,'')!=who[k] for k in app_group.FIELDS)):
                continue
            if isinstance(entry.get('key'),str) and entry['key']:fresh.append(entry)
        if not fresh:return
        group=app_group.make(fresh)
        for entry in fresh:entry['receipt_group']=group;entry['notified']=True
        save()
        kinds=app_results.declared(home())
        post=app_group.receipt(group['id'],[app_group.line(chain,kinds) for chain in app_group.chains(fresh,kinds)])
    text=app_group.without_single_receipts(response_text,group['keys'])
    return text+'\n\n[[글 나누기]]\n\n'+post if text else post


def approval_response(*,session_id='',turn_id='',tool_call_id='',choice='',**_):
    # Timeout, cancellation and automatic decisions are not human approval.
    if (not session_id or not turn_id or not tool_call_id
            or choice not in ('once','session','always','deny')):return
    with _LOCK:_DECISIONS[(*identity(session_id,turn_id),tool_call_id)]=choice


def execution(tool_name,args,next_call,*,session_id='',turn_id='',tool_call_id='',**_):
    result=next_call(args)
    if not write_policy.governed(tool_name) or not write_policy.owner_chat(home(),app_tools.env):return result
    with _LOCK:choice=_DECISIONS.pop((*identity(session_id,turn_id),tool_call_id),None)
    if choice is None:return result
    try:value=json.loads(result) if isinstance(result,str) else dict(result)
    except (TypeError,ValueError):return result
    if not isinstance(value,dict):return result
    if choice=='deny' and value.get('error'):
        value['approval_message']=DENIED
    elif choice in ('once','session','always') and value.get('ok') is True:
        value['approval_message']=APPROVED
    else:return result
    return json.dumps(value,ensure_ascii=False) if isinstance(result,str) else value


def register(ctx):
    from hermes_facility import output_steps
    # Require the execution boundary before publishing any related hook.
    # This middleware surrounds the native gate, including a denied call.
    ctx.register_middleware('tool_execution',execution)
    output_steps.add('app_receipts',output)
    ctx.register_hook('post_llm_call',ended)
    ctx.register_hook('post_approval_response',approval_response)
