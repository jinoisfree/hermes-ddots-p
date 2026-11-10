"""Calendar transactions: prepare an inverse before dispatch, then verify the receipt.

The prepared context is private. Public tool arguments cannot supply a native
compare snapshot or turn an unverified recurring edit into a reversible write.
"""
from contextlib import nullcontext
from contextvars import ContextVar
import json
import subprocess
import time
import threading
from copy import deepcopy
import uuid
from hermes_facility import app_registry, app_scope
from hermes_governance import app_tools, app_undo, write_policy

_PREPARED = ContextVar('calendar_prepared_write', default=None)
_GATES={}
_GATE_LOCK=threading.RLock()
FIELDS = {'title':'title','start':'start','end':'end','all_day':'isAllDay',
          'calendar_id':'calendarIdentifier','location':'location','notes':'notes','url':'url'}


def prepared(): return _PREPARED.get()


def binding(home):
    return app_scope.bind(home) if app_registry.explicit(app_registry.root_of(home),app_registry.profile_of(home)) else nullcontext()


def google_backend(td):
    cfg=td.personal_scopes.config(td)
    return app_scope.current('calendars') is None and cfg and td.personal_scopes.OWNERS.get(td.personal_scopes.current(td))=='personal'


def checked(td,args,context):
    payload=dict(args)
    if error:=td._normalize_calendar_dates(payload,payload.get('action')):raise ValueError(error)
    if error:=td._calendar_alarm_error(payload,payload.get('action')):raise ValueError(error)
    if error:=td._calendar_identity_error(payload,payload.get('action')):raise ValueError(error)
    cfg=td.personal_scopes.config(td)
    if cfg is not None and td.personal_scopes.current(td) in td.personal_scopes.OWNERS:
        return td.personal_scopes.authorize_mutation(td,'calendar',payload,context)
    return app_scope.mutation(td,'calendar',payload,context) or payload


def snapshot(td,identifier,context):
    outcome=td._calendar_event_lookup(identifier,context.get('runner') or subprocess.run)
    if outcome.get('status') not in ('ok','unsupported'):
        raise ValueError('APP_CALENDAR_SNAPSHOT_UNAVAILABLE')
    row=outcome.get('row')
    if not isinstance(row,dict) or any(k not in row for k in ('calendarItemIdentifier','title','start','end','calendarIdentifier','alarmDetails')):
        raise ValueError('APP_CALENDAR_SNAPSHOT_UNVERIFIED')
    return row


def native_state(row): return {k:v for k,v in row.items() if k!='recurring'}


def values(row):
    # IDs can change when EventKit moves an event between calendars. Content,
    # selected calendar and all captured alarm details must still match exactly.
    return {k:v for k,v in row.items() if k not in ('eventIdentifier','calendarItemIdentifier','calendar','calendarSource','revision')}


ALARM_FIELDS=('alarms','alarmDetails','alarmRestorable')


def unchanged_since(entry,observed):
    # A synced calendar bumps the revision and may add its default reminders right
    # after a create; neither is an owner edit. Undoing a create deletes the event,
    # so its reminders are ignored there; an update undo still compares every value.
    now,then=values(observed),values(entry['after'])
    if entry['before'] is None:
        for field in ALARM_FIELDS:now.pop(field,None);then.pop(field,None)
    return now==then


def inverse(args,before,after):
    payload={'action':'delete' if before is None else 'update','event_id':after['calendarItemIdentifier'],
             'expected_title':after['title'],'expected_start':after['start'],'span':'this'}
    if before is None:return payload
    for key,field in FIELDS.items():
        if key not in args and not args.get('clear_'+key):continue
        if before.get(field) is None and key in ('location','notes','url'):payload['clear_'+key]=True
        else:payload[key]=before[field]
    if 'alarms' in args or args.get('clear_alarms'):
        if before.get('alarmRestorable') is not True:raise ValueError('APP_CALENDAR_ALARM_INVERSE_UNAVAILABLE')
        payload['_restore_alarms']=before['alarmDetails']
    return payload


def gate_key(args,context):
    clean={k:v for k,v in args.items() if k not in ('approved','request_plan')}
    return (app_tools.signature('calendar_direct_mutation',clean),str(context.get('tool_call_id') or ''),
        str(context.get('session_id') or ''),str(context.get('turn_id') or ''))


def remember_gate(args,context,kind,before):
    with _GATE_LOCK:
        now=time.monotonic()
        for key,row in list(_GATES.items()):
            if now-row['at']>3600:_GATES.pop(key,None)
        _GATES[gate_key(args,context)]={'kind':kind,'before':deepcopy(before),'at':now}


def dynamic_approved(args,context,before):
    if context.get('_calendar_plan_approved') is True:return True
    with _GATE_LOCK:shown=_GATES.pop(gate_key(args,context),None)
    return bool(shown and time.monotonic()-shown['at']<=3600 and shown['kind']==write_policy.EXTERNAL and shown['before']==before)


def gate(home,td,args,context):
    """Dynamic recurring classification uses the existing scoped read before approval."""
    if not write_policy.owner_chat(home,app_tools.env):
        return write_policy.gate('calendar_direct_mutation',args,owner=False,unattended=write_policy.background(app_tools.env))
    with binding(home):
        if google_backend(td) or write_policy.classify('calendar_direct_mutation',args)==write_policy.DELETE:
            payload=dict(args);before=None  # the account API retains its existing scoped preflight
        else:
            payload=checked(td,args,context)
            before=snapshot(td,payload['event_id'],context) if payload.get('action')=='update' else None
        kind=write_policy.classify('calendar_direct_mutation',payload,state=before)
        remember_gate(args,context,kind,before)
        decision=write_policy.gate('calendar_direct_mutation',payload,owner=write_policy.owner_chat(home,app_tools.env),
            unattended=write_policy.background(app_tools.env),state=before)
        if decision and decision['action']=='approve':
            decision['message']=td._one_button_plan('calendar_direct_mutation',payload.get('action'),payload)
            if payload.get('span')=='future' or (before or {}).get('recurring'):
                decision['message']+='\n반복 일정은 자동으로 되돌릴 수 없어 먼저 승인이 필요해요.'
            if (before or {}).get('externalNotifications'):
                decision['message']+='\n참석자가 있는 일정 변경은 알림이 나갈 수 있어 먼저 승인이 필요해요.'
        if decision and decision['action']=='approve' and before:
            import hashlib
            state_key=hashlib.sha256(json.dumps(before,sort_keys=True).encode()).hexdigest()[:16]
            decision['rule_key']+=':'+state_key
        return decision


def execute(home,td,args,next_call,context):
    if not write_policy.owner_chat(home,app_tools.env):return td._error('APP_OWNER_CHAT_REQUIRED',mutation_calls=0)
    attempted=False
    try:
        with binding(home):
            if write_policy.classify('calendar_direct_mutation',args)==write_policy.DELETE:
                if not app_tools.authorized('calendar_direct_mutation',args):raise ValueError('APP_APPROVAL_REQUIRED')
                return next_call(args)
            if google_backend(td):
                from hermes_governance import google_calendar_undo
                return google_calendar_undo.execute(home,td,args,next_call,context)
            payload=checked(td,args,context)
            before=snapshot(td,payload['event_id'],context) if payload.get('action')!='create' else None
            if '_bundle_before' in context and before!=context['_bundle_before']:raise ValueError('APP_CALENDAR_BEFORE_CHANGED')
            kind=write_policy.classify('calendar_direct_mutation',payload,state=before)
            if kind!=write_policy.REVERSIBLE:
                if not app_tools.authorized('calendar_direct_mutation',args):raise ValueError('APP_APPROVAL_REQUIRED')
                if kind==write_policy.EXTERNAL and payload.get('span','this')!='future' and not dynamic_approved(args,context,before):
                    raise ValueError('APP_CALENDAR_CHANGED_AFTER_APPROVAL: 일정 상태가 바뀌었어요. 다시 확인하고 승인해 주세요.')
                token=_PREPARED.set({'backend':'eventkit','before':before,'record_targets':lambda ids:None})
                try:return next_call(payload)
                finally:_PREPARED.reset(token)
            # Validate that the inverse can restore every requested mutable field
            # before publishing pending or allowing any effect.
            planned_inverse=inverse(payload,before,before) if before else {'action':'delete','event_id':None,'span':'this'}
            with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home)) as (data,save):
                entry=dict(key=uuid.uuid4().hex,created_at=time.time(),conversation=app_tools.conversation(),
                    journal_kind='calendar',backend='eventkit',arguments=payload,before=before,after=None,inverse=planned_inverse,status='pending',consumed=False)
                data['entries'].append(entry);save()
                def record_targets(ids):
                    if not isinstance(ids,list) or any(not isinstance(v,str) or not v for v in ids):raise ValueError('APP_CALENDAR_TARGET_UNVERIFIED')
                    entry['native_targets']=ids;save()
                token=_PREPARED.set({'backend':'eventkit','before':before,'record_targets':record_targets})
                try:
                    attempted=True;result=json.loads(next_call(payload))
                    if result.get('ok') is not True:
                        entry['status']='uncertain';save();return json.dumps(result,ensure_ascii=False)
                    receipt=result.get('result') or {};after=receipt.get('after')
                    if not isinstance(after,dict) or not after.get('calendarItemIdentifier'):raise ValueError('APP_CALENDAR_TARGET_UNVERIFIED')
                    identifier=after['calendarItemIdentifier'];entry['native_targets']=[identifier];save()
                    actual=snapshot(td,identifier,context)
                    if native_state(actual)!=after:raise ValueError('APP_CALENDAR_AFTER_CHANGED')
                    if before and receipt.get('before')!=native_state(before):raise ValueError('APP_CALENDAR_BEFORE_CHANGED')
                    entry.update(after=actual,inverse=inverse(payload,before,actual),status='done');save()
                except Exception:entry['status']='uncertain';save();raise
                finally:_PREPARED.reset(token)
            result.update(undo_key=entry['key'],message=write_policy.result_text('일정 변경을 저장했어요.',entry['key']))
            return json.dumps(result,ensure_ascii=False)
    except (ValueError,OSError,KeyError,TypeError) as error:
        return td._error(str(error) if isinstance(error,ValueError) else 'APP_CALENDAR_JOURNAL_FAILED',
            mutation_calls=None if attempted else 0,reflection_unknown=attempted)


def restore(home,td,entry,context=None):
    context=context or {}
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    if app_registry.tool_granted(home,'calendar_direct_mutation') is False:raise ValueError('APP_NOT_CONNECTED')
    if entry.get('status')!='done':raise ValueError('APP_CALENDAR_CHANGE_UNVERIFIED')
    def cleanup():
        from hermes_governance import app_results
        return app_results.unlink_created(td,'calendar',entry['inverse']['event_id'],context)
    if entry['before'] is None and entry.get('native_done'):return cleanup()
    with binding(home):
        payload=dict(entry['inverse'],_rollback=True,_skip_common_work=True)
        if entry['before'] is None:
            outcome=td._calendar_event_lookup(payload['event_id'],context.get('runner') or subprocess.run)
            if outcome.get('status')=='missing':
                app_undo.progress(home,entry,native_done=True)
                return cleanup()
        payload=checked(td,payload,context)
        observed=snapshot(td,payload['event_id'],context)
        if entry['before'] and values(observed)==values(entry['before']):return {'ok':True,'already':True}
        if not unchanged_since(entry,observed):return {'ok':False,'error':'UNDO_CONFLICT','skipped':True}
        token=_PREPARED.set({'backend':'eventkit','before':observed,'record_targets':lambda ids:None})
        try:result=json.loads(td._calendar_direct_mutation(payload,**context))
        finally:_PREPARED.reset(token)
        if result.get('ok') is not True:return result
        if entry['before']:
            after=(result.get('result') or {}).get('after') or {}
            if not after.get('calendarItemIdentifier'):raise ValueError('APP_CALENDAR_TARGET_UNVERIFIED')
            actual=snapshot(td,after['calendarItemIdentifier'],context)
            if values(actual)!=values(entry['before']):return {'ok':False,'error':'APP_CALENDAR_RESTORE_UNVERIFIED'}
        else:
            # Missing is proven by the typed reader; a denied/transient read is
            # never used as proof that the event was deleted.
            outcome=td._calendar_event_lookup(payload['event_id'],context.get('runner') or subprocess.run)
            if outcome.get('status')!='missing':return {'ok':False,'error':'APP_CALENDAR_DELETE_UNVERIFIED'}
            app_undo.progress(home,entry,native_done=True)
            return cleanup()
        return result


def register(ctx,home,td):
    from hermes_governance import app_results
    def undo(entry):
        with app_tools.host_source(home):return restore(home,td,entry)
    app_results.register(ctx,home,'calendar',undo)
    from hermes_governance import google_calendar_undo
    google_calendar_undo.register(ctx,home,td)
