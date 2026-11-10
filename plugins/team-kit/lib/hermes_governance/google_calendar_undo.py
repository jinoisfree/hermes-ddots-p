"""Account-bound Calendar event inverses; raw API state and etags stay private."""
from copy import deepcopy
import json
import time
import uuid
from hermes_governance import app_tools,app_undo,calendar_undo,write_policy
from hermes_facility import app_registry
from hermes_packs.calendar import google_calendar_accounts as g

MUTABLE={'title':'summary','notes':'description','location':'location','start':'start','end':'end'}


def verify(cid,before):
    pending=calendar_undo.prepared()
    if pending and pending.get('backend')=='google_event':
        if pending['calendar_id']!=cid or pending['before']!=before:raise ValueError('APP_CALENDAR_ORIGINAL_CHANGED')


def capture(row):
    pending=calendar_undo.prepared()
    if pending and pending.get('backend')=='google_event':
        if not isinstance(row,dict) or not row.get('id'):raise ValueError('APP_CALENDAR_TARGET_UNVERIFIED')
        pending['record_targets']([row['id']])


def body_for(args,before):
    if before is None:return None  # only the new event ID will be deleted
    body={target:deepcopy(before.get(target)) for key,target in MUTABLE.items() if key in args or args.get('clear_'+key)}
    if 'alarms' in args or args.get('clear_alarms'):body['reminders']=deepcopy(before.get('reminders'))
    return body


def content(row):return {k:v for k,v in row.items() if k not in ('etag','updated','sequence')}


def execute(home,td,args,next_call,context):
    attempted=False
    try:
        payload=dict(args);action=payload.get('action')
        if error:=td._normalize_calendar_dates(payload,action):raise ValueError(error)
        if error:=td._calendar_alarm_error(payload,action):raise ValueError(error)
        api,cid,before,checked=g.preflight(td,payload,context)
        if '_bundle_before' in context and before!=context['_bundle_before']:raise ValueError('APP_CALENDAR_BEFORE_CHANGED')
        inverse=body_for(checked,before)
        if before and not before.get('etag'):raise ValueError('GOOGLE_EVENT_ETAG_REQUIRED')
        with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home)) as (data,save):
            entry=dict(key=uuid.uuid4().hex,created_at=time.time(),conversation=app_tools.conversation(),journal_kind='google_calendar',
                calendar_id=cid,account=checked['account'],arguments=checked,before=before,after=None,inverse=inverse,status='pending',consumed=False)
            data['entries'].append(entry);save()
            def record_targets(ids):entry['native_targets']=ids;save()
            token=calendar_undo._PREPARED.set({'backend':'google_event','calendar_id':cid,'before':before,'record_targets':record_targets})
            try:
                attempted=True;result=json.loads(next_call(checked))
                if result.get('ok') is not True:
                    entry['status']='uncertain';save();return json.dumps(result,ensure_ascii=False)
                identifiers=entry.get('native_targets',[])
                if len(identifiers)!=1:raise ValueError('APP_CALENDAR_TARGET_UNVERIFIED')
                identifier=identifiers[0]
                after=api.events().get(calendarId=cid,eventId=identifier).execute()
                reported=(result.get('result') or {}).get('after') or {}
                if not after.get('etag') or reported!=g.event_row(after,cid):raise ValueError('APP_CALENDAR_AFTER_CHANGED')
                entry.update(id=identifier,after=after,status='done');save()
            except Exception:entry['status']='uncertain';save();raise
            finally:calendar_undo._PREPARED.reset(token)
        result.update(undo_key=entry['key'],message=write_policy.result_text('일정 변경을 저장했어요.',entry['key']))
        return json.dumps(result,ensure_ascii=False)
    except Exception as error:
        return td._error(str(error) if isinstance(error,ValueError) else 'APP_GOOGLE_CALENDAR_JOURNAL_FAILED',
            mutation_calls=None if attempted else 0,reflection_unknown=attempted)


def restore(home,td,entry,context=None):
    context=context or {}
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    if app_registry.tool_granted(home,'calendar_direct_mutation') is False:raise ValueError('APP_NOT_CONNECTED')
    if entry.get('status')!='done':raise ValueError('APP_CALENDAR_CHANGE_UNVERIFIED')
    def cleanup():
        from hermes_governance import app_results
        return app_results.unlink_created(td,'calendar','google:'+entry['id'],context)
    if entry['before'] is None and entry.get('native_done'):return cleanup()
    if problem:=td.personal_scopes.role_problem(td,'calendar_direct_mutation',entry['arguments']):raise ValueError(problem)
    api,account,_=g.service(td,{'account':entry['account']},write=True,factory=context.get('google_service_factory'))
    cid=g.calendar_id({'calendar_id':entry['calendar_id']},account)
    events=api.events();identifier=entry['id']
    try:current=events.get(calendarId=cid,eventId=identifier).execute()
    except Exception as error:
        if entry['before'] is None and getattr(getattr(error,'resp',None),'status',None)==404:
            app_undo.progress(home,entry,native_done=True)
            return cleanup()
        raise
    if entry['before'] and content(current)==content(entry['before']):return {'ok':True,'already':True}
    if current!=entry['after']:return {'ok':False,'error':'UNDO_CONFLICT','skipped':True}
    if not current.get('etag'):raise ValueError('GOOGLE_EVENT_ETAG_REQUIRED')
    if entry['before'] is None:request=events.delete(calendarId=cid,eventId=identifier,sendUpdates='none')
    else:request=events.patch(calendarId=cid,eventId=identifier,body=deepcopy(entry['inverse']),sendUpdates='none')
    request.headers['If-Match']=current['etag'];request.execute()
    if entry['before'] is None:
        try:events.get(calendarId=cid,eventId=identifier).execute()
        except Exception as error:
            if getattr(getattr(error,'resp',None),'status',None)==404:
                app_undo.progress(home,entry,native_done=True)
                return cleanup()
            raise
        return {'ok':False,'error':'APP_CALENDAR_DELETE_UNVERIFIED'}
    after=events.get(calendarId=cid,eventId=identifier).execute()
    return {'ok':content(after)==content(entry['before']),'error':'APP_CALENDAR_RESTORE_UNVERIFIED' if content(after)!=content(entry['before']) else None}


def register(ctx,home,td):
    from hermes_governance import app_results
    def undo(entry):
        with app_tools.host_source(home):return restore(home,td,entry)
    app_results.register(ctx,home,'google_calendar',undo)
