"""One conditional Google color writer with private before/after and inverse."""
from copy import deepcopy
import json
import re
import time
import uuid
from hermes_facility import app_registry,app_scope
from hermes_governance import app_tools,app_undo,google_calendar_undo,write_policy
from . import google_calendar_accounts as accounts


def resolve(td,args,context,account_api):
    if account_api:
        api,account,primary=accounts.service(td,args,write=True,factory=context.get('google_service_factory'))
        cid=accounts.calendar_id(args,account)
        if args.get('target','event')=='calendar':return api,cid,'calendar',cid,primary,account
        eid=str(args.get('event_id') or '')
        if eid.startswith('google:'):eid=eid[7:]
        elif args.get('eventkit_id'):
            _,_,_,_,_,eid=td._google_calendar_color_target(args,{**context,'google_calendar_service':api})
        else:raise ValueError('GOOGLE_EVENT_ID_REQUIRED')
    else:
        api,cid,_,_,listed,eid=td._google_calendar_color_target(args,context)
        primary=api.calendarList().get(calendarId=cid).execute()
        # Bind legacy "primary" to an actual calendar identity before mutation.
        actual=primary.get('id')
        if not isinstance(actual,str) or not actual or primary.get('accessRole') not in ('owner','writer'):
            raise ValueError('GOOGLE_CALENDAR_SCOPE_UNVERIFIED')
        cid=actual;account=actual
    before=api.events().get(calendarId=cid,eventId=eid).execute()
    if before.get('id')!=eid:raise ValueError('GOOGLE_EVENT_ID_MISMATCH')
    if not account_api and (not listed.get('etag') or listed['etag']!=before.get('etag')):
        raise ValueError('GOOGLE_EVENT_ORIGINAL_CHANGED')
    return api,cid,'event',eid,before,account


def request(api,cid,kind,identifier,body,etag):
    if not etag:raise ValueError('GOOGLE_EVENT_ETAG_REQUIRED')
    if kind=='event':req=api.events().patch(calendarId=cid,eventId=identifier,body=body,sendUpdates='none')
    else:req=api.calendarList().patch(calendarId=cid,body=body,colorRgbFormat='backgroundColor' in body)
    req.headers['If-Match']=etag
    return req


def read(api,cid,kind,identifier):
    return (api.events().get(calendarId=cid,eventId=identifier) if kind=='event' else api.calendarList().get(calendarId=cid)).execute()


def colors(row,kind):
    return {key:row.get(key) for key in (('colorId',) if kind=='event' else ('colorId','backgroundColor','foregroundColor'))}


def perform(home,td,args,context,*,account_api=False):
    if not write_policy.owner_chat(home,app_tools.env):return td._error('APP_OWNER_CHAT_REQUIRED',mutation_calls=0)
    attempted=False
    try:
        api,cid,kind,identifier,before,account=resolve(td,args,context,account_api)
        if not before.get('etag'):raise ValueError('GOOGLE_EVENT_ETAG_REQUIRED')
        if kind=='event':
            color=str(args.get('color_id') or '')
            if not re.fullmatch(r'(?:[1-9]|1[01])',color):raise ValueError('GOOGLE_COLOR_ID_INVALID')
            body={'colorId':color};inverse={'colorId':before.get('colorId')}
        else:
            cfg,scope,_,_=accounts.selection(td,args,write=True)
            body={'backgroundColor':'#FFD60A' if scope=='personal' else '#007AFF','foregroundColor':'#000000'}
            if before.get('backgroundColor') and before.get('foregroundColor'):
                inverse={k:before[k] for k in ('backgroundColor','foregroundColor')}
            elif before.get('colorId'):inverse={'colorId':before['colorId']}
            else:raise ValueError('GOOGLE_CALENDAR_COLOR_INVERSE_UNAVAILABLE')
        # Construct the conditional request and exact inverse before publishing pending.
        patch=request(api,cid,kind,identifier,body,before['etag'])
        legacy=app_undo.legacy_paths(home)
        if account_api:
            _,_,_,original_home=accounts.selection(td,args,write=True)
            legacy.append(original_home/'state/google-calendar-original-colors.json')
        with app_undo.ledger(app_undo.path_for(home),legacy=legacy) as (data,save):
            if kind=='calendar':
                baseline=data['baselines'].setdefault('calendar_colors',{})
                if not isinstance(baseline,dict):raise ValueError('APP_UNDO_INVALID')
                baseline.setdefault(cid,dict(at=time.time(),**colors(before,kind)))
            entry=dict(key=uuid.uuid4().hex,created_at=time.time(),conversation=app_tools.conversation(),journal_kind='calendar_color',
                calendar_id=cid,id=identifier,kind=kind,account=account,account_api=account_api,arguments=deepcopy(args),
                before=before,after=None,inverse=inverse,status='pending',consumed=False)
            data['entries'].append(entry);save()
            try:
                attempted=True;response=patch.execute();after=read(api,cid,kind,identifier)
                if not isinstance(after,dict) or not after.get('etag') or after.get('id')!=identifier:
                    raise ValueError('GOOGLE_CALENDAR_COLOR_VERIFICATION_FAILED')
                if any(str(after.get(k,'')).casefold()!=str(v).casefold() for k,v in body.items()):
                    raise ValueError('GOOGLE_CALENDAR_COLOR_VERIFICATION_FAILED')
                if response.get('etag')!=after['etag']:raise ValueError('GOOGLE_CALENDAR_COLOR_AFTER_CHANGED')
                entry.update(after=after,status='done');save()
            except Exception:entry['status']='uncertain';save();raise
        result=dict(ok=True,authority='Google Calendar API',action='set_color',calendar_id=cid,account=account,
            before=colors(before,kind),after=colors(after,kind),undo_key=entry['key'],mutation_calls=1,
            message=write_policy.result_text('일정 색을 저장했어요.',entry['key']),fallback_used=False)
        if kind=='event':
            previous=str(before.get('colorId') or '');color=str(after.get('colorId') or '')
            result.update(event_id='google:'+identifier,google_event_id=identifier,eventkit_id=args.get('eventkit_id'),
                color_id=color,previous_color_id=previous,color_name=td.GOOGLE_CALENDAR_COLOR_NAMES.get(color,'알 수 없음'),
                previous_color_name=td.GOOGLE_CALENDAR_COLOR_NAMES.get(previous,'알 수 없음'),send_updates='none')
        return json.dumps(result,ensure_ascii=False)
    except Exception as error:
        return td._google_calendar_color_failure(error,mutation_calls=int(attempted))


def restore(home,td,entry,context=None):
    context=context or {}
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    if app_registry.tool_granted(home,'google_calendar_color_set') is False:raise ValueError('APP_NOT_CONNECTED')
    if entry.get('status')!='done':raise ValueError('APP_CALENDAR_CHANGE_UNVERIFIED')
    if problem:=td._personal_owner_error('google_calendar_color_set'):raise ValueError('APP_CALENDAR_OWNER_REQUIRED')
    args=dict(entry['arguments'])
    if entry['account_api']:args['account']=entry['account']
    with app_scope.bind(home):
        # Re-run existing container/ownership checks before reading the API event.
        if not entry['account_api']:
            cfg=td.personal_scopes.config(td)
            if cfg is not None and td.personal_scopes.current(td) in td.personal_scopes.OWNERS:
                td.personal_scopes.authorize_mutation(td,'calendar',args,context)
            else:app_scope.mutation(td,'calendar',args,context)
        api,cid,kind,identifier,current,account=resolve(td,args,context,entry['account_api'])
        if (cid,kind,identifier,account)!=(entry['calendar_id'],entry['kind'],entry['id'],entry['account']):
            raise ValueError('GOOGLE_CALENDAR_SCOPE_CHANGED')
        def content(row):return {k:v for k,v in row.items() if k not in ('etag','updated','sequence')}
        if content(current)==content(entry['before']):return {'ok':True,'already':True}
        if current!=entry['after']:return {'ok':False,'error':'UNDO_CONFLICT','skipped':True}
        request(api,cid,kind,identifier,deepcopy(entry['inverse']),current['etag']).execute()
        after=read(api,cid,kind,identifier)
        return {'ok':content(after)==content(entry['before']),'error':None if content(after)==content(entry['before']) else 'GOOGLE_CALENDAR_COLOR_RESTORE_UNVERIFIED'}


def target(entry):
    """An event colored through the account API is the same target as the event the calendar writer made."""
    if entry.get('kind')!='event' or entry.get('account_api') is not True:return None
    return google_calendar_undo.target(entry)


def line(td,entry):
    color=str((entry.get('arguments') or {}).get('color_id') or '')
    return '일정 색 지정',getattr(td,'GOOGLE_CALENDAR_COLOR_NAMES',{}).get(color) or ('색 '+color if color else '')


def register(ctx,home,td):
    from hermes_governance import app_results
    def undo(entry):
        with app_tools.host_source(home):return restore(home,td,entry)
    app_results.register(ctx,home,'calendar_color',undo,target=target,line=lambda entry:line(td,entry))
