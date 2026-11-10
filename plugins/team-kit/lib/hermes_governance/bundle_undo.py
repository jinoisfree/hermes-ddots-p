"""Bundle admission and child transactions share one personal journal record."""
from contextvars import ContextVar
from contextlib import contextmanager
from copy import deepcopy
import hashlib
import json
import threading
import time
from hermes_facility import app_scope,app_registry
from hermes_governance import app_tools,app_undo,app_results,calendar_undo,memo_undo,write_policy

_GATES={}
_LOCK=threading.RLock()
_SELECTED=ContextVar('personal_result_entry',default=None)
_DISPATCH=ContextVar('personal_bundle_dispatch',default=None)


def selected():return _SELECTED.get()


@contextmanager
def execution(args,context):
    token=_DISPATCH.set(context)
    try:
        with app_tools.native('personal_work_bundle',args):yield
    finally:_DISPATCH.reset(token)


def identity(home,args):
    return app_tools.signature('personal_work_bundle',{'home':str(home),'arguments':{k:v for k,v in args.items() if k not in ('approved','request_plan')}})


def prepare(home,td,operations,context):
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    prepared=[]
    for op in operations:
        args=dict(op['arguments'],action=op['action']);domain=op['domain'];before=None
        tool='calendar_direct_mutation' if domain=='calendar' else 'apple_notes_direct_mutation'
        if app_registry.tool_granted(home,tool) is False:raise ValueError('APP_NOT_CONNECTED')
        if domain=='calendar':
            with calendar_undo.binding(home):
                google=bool(calendar_undo.google_backend(td))
                if google:
                    from hermes_packs.calendar import google_calendar_accounts as g
                    _,_,before,args=g.preflight(td,args,context)
                    state=dict(before or {},externalNotifications=bool((before or {}).get('attendees')))
                else:
                    args=calendar_undo.checked(td,args,context)
                    if args['action']!='create':before=calendar_undo.snapshot(td,args['event_id'],context)
                    state=before
            tool='calendar_direct_mutation'
            kind=write_policy.classify(tool,args,state=state)
            if kind==write_policy.REVERSIBLE and before and not google:
                calendar_undo.inverse(args,before,before)
        else:
            with memo_undo.binding(home,args.get('source')):
                if td.personal_scopes.config(td) is not None:
                    args=td.personal_scopes.authorize_mutation(td,'notes',args,context)
                else:args=app_scope.mutation(td,'notes',args,context) or args
                if args['action']!='create':before=memo_undo.snapshot(td,args['note_id'],context)
                source='obsidian' if td.obsidian_notes.selected(td) else 'apple_notes'
                state={'source':source}
                if source=='apple_notes' and args['action']=='update':
                    import subprocess
                    verified=td._note_verification_snapshot(args['note_id'],context.get('runner') or subprocess.run)
                    names=(verified or {}).get('attachment_names')
                    state.update(inverse_ready=isinstance(names,list) and all(isinstance(n,str) for n in names) and not any(names))
            tool='apple_notes_direct_mutation';kind=write_policy.classify(tool,args,state=state)
        prepared.append(dict(domain=domain,tool=tool,arguments=args,before=before,kind=kind,
            **({'source':source} if domain=='notes' else {})))
    return prepared


def kind(rows):
    return next((value for value in (write_policy.EXTERNAL,write_policy.DELETE,write_policy.REVERSIBLE)
        if any(row['kind']==value for row in rows)),write_policy.READ)


def gate(home,td,args,context):
    if error:=td._personal_owner_error('personal_work_bundle'):
        raise ValueError(json.loads(error).get('error','APP_OWNER_CHAT_REQUIRED'))
    normalized=td._normalize_personal_bundle_args(args)
    operations,_,error=td._validate_bundle(normalized)
    if error:raise ValueError('승인 요청 전 개인업무 묶음 검증에 실패했습니다: '+error)
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    digest=td._bundle_digest(normalized)
    if td._common_work_store().bundle_receipt(bundle_key=td._bundle_key(digest),payload_digest=digest) is not None:return None
    rows=prepare(home,td,operations,context)
    needs=kind(rows) not in (write_policy.READ,write_policy.REVERSIBLE)
    digest=td._bundle_digest(normalized)[:16]
    with _LOCK:
        now=time.monotonic()
        for key,row in list(_GATES.items()):
            if now-row['at']>3600:_GATES.pop(key,None)
        previous=_GATES.get(identity(home,args))
        answered=needs and previous and previous['rows']==rows and td._approved_after_the_gate(digest,session_id=str(context.get('session_id') or ''))
        _GATES[identity(home,args)]={'at':now,'rows':deepcopy(rows),'kind':kind(rows)}
    if not needs or answered:return None
    td._note_gate_shown(digest)
    state_key=hashlib.sha256(json.dumps(rows,sort_keys=True,ensure_ascii=False).encode()).hexdigest()[:20]
    return {'action':'approve','rule_key':'app-bundle:'+identity(home,args)+':'+state_key,
        'message':'승인하면 묶음 전체를 한 번 실행합니다:\n'+td._bundle_plan_lines(operations)+
        '\n삭제·반복 일정·참석자 알림·정확한 복원이 어려운 변경은 먼저 승인받아요.'}


def admission(home,td,args,operations,context):
    context={**(_DISPATCH.get() or {}),**context}
    rows=prepare(home,td,operations,context)
    if kind(rows) not in (write_policy.READ,write_policy.REVERSIBLE):
        if not app_tools.authorized('personal_work_bundle',args):raise ValueError('APP_APPROVAL_REQUIRED')
        with _LOCK:shown=_GATES.pop(identity(home,args),None)
        if (not context.get('_bundle_plan_approved') and
            (not shown or shown['rows']!=rows or time.monotonic()-shown['at']>3600)):
            raise ValueError('APP_BUNDLE_CHANGED_AFTER_APPROVAL')
    return rows


def call(home,td,row,slot,publish,handler,context):
    args=dict(row['arguments'],approved=True,_skip_common_work=True)
    child_context=dict(context,_bundle_before=row['before'])
    with app_undo.component(app_undo.path_for(home),slot,publish),app_tools.native(row['tool'],args):
        native=lambda payload:handler(payload,**context)
        if row['domain']=='calendar':
            child_context['_calendar_plan_approved']=row['kind']==write_policy.EXTERNAL
            result=json.loads(calendar_undo.execute(home,td,args,native,child_context))
        elif row['kind']==write_policy.REVERSIBLE or args['action']=='update':
            result=json.loads(memo_undo.execute(home,td,args,native,child_context))
            if row['kind']!=write_policy.REVERSIBLE:
                for change in slot.get('changes',[]):
                    change['journal_kind']='memo_backup'
                    change['limitation']=memo_undo.LIMITATION
                publish()
        else:
            with memo_undo.binding(home,row['source']):result=json.loads(native(args))
    # A child key has no independent ledger row and must never escape as a button.
    if result.pop('undo_key',None):result.pop('message',None)
    return result


def restore_change(home,td,operation,entry,publish,context):
    context=dict(context,_bundle_component=True)
    slot=entry['components'][operation['component']];changes=slot.get('changes',[])
    if len(changes)!=1 or changes[0].get('status')!='done':raise ValueError('APP_BUNDLE_CHANGE_UNVERIFIED')
    row=changes[0]
    with app_undo.component(app_undo.path_for(home),slot,publish):
        if row['journal_kind']=='calendar':return calendar_undo.restore(home,td,row,context)
        if row['journal_kind']=='google_calendar':
            from hermes_governance import google_calendar_undo
            return google_calendar_undo.restore(home,td,row,context)
        if row['journal_kind'] in {'memo','memo_backup'}:return memo_undo.restore(home,td,row,context)
    raise ValueError('APP_BUNDLE_CHANGE_UNVERIFIED')


def result(entry,receipt):
    if entry.get('app_ready') and not entry.get('consumed'):
        receipt.update(undo_key=entry['key'],message=write_policy.result_text('묶음 변경을 저장했어요.',entry['key']))
    elif any(change.get('reference_only') for slot in entry.get('components',[]) for change in slot.get('changes',[])):
        receipt.update(message='묶음 변경을 저장했어요.\n'+memo_undo.LIMITATION,rollback_limitations=memo_undo.LIMITATION)
    return receipt


def register(ctx,home,td):
    def restore(entry):
        if not entry.get('app_ready'):raise ValueError('APP_BUNDLE_CHANGE_UNVERIFIED')
        token=_SELECTED.set(entry['key'])
        try:
            with app_tools.host_source(home):return json.loads(td._personal_work_rollback({}))
        finally:_SELECTED.reset(token)
    app_results.register(ctx,home,'personal',restore)
