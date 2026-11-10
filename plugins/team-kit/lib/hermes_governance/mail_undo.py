"""Mail pack transaction boundary: frozen identity, pending state, field-local undo."""
from copy import deepcopy
import re
import time
import uuid
from hermes_facility import app_registry,app_scope
from hermes_governance import app_tools,app_undo,write_policy
from hermes_packs.mail import full_mail_tools as full,gmail_state


def invoke(td,request,mail,runner=None,mail_runner=None,restore=False,on_progress=None):
    if mail:return td.mail_app.full_tools(request,runner=mail_runner)
    result,error=full.api(td,{'op':'full_restore' if restore else 'full_write',**request},runner,**({'on_progress':on_progress} if on_progress is not None else {}))
    if error:raise ValueError(error)
    if not isinstance(result,dict):raise ValueError('MAIL_INVALID_RESPONSE')
    return result


def inverse(request,before,after,mail):
    if not mail:
        if before['kind']=='organization':
            from hermes_packs.mail import organization_state
            return organization_state.inverse(request['_snapshot'],after)
        return gmail_state.inverse(request,before,after)
    if before['account_id']!=after['account_id']:raise ValueError('MAIL_APP_ACCOUNT_CHANGED')
    if request['action'] in {'mail_move','mail_app_organize'}:
        if before.get('resources')!=after.get('resources'):raise ValueError('MAIL_APP_ORIGINAL_CHANGED')
        rows={}
        for mid,old in before['values'].items():
            row=after['values'][mid]
            if any(old[k]!=row[k] for k in ('rfc','from','subject')) or row['mailbox']!=request['mailbox']:
                raise ValueError('MAIL_APP_MESSAGE_CHANGED')
            fields={}
            if request.get('mark_read'):
                if row['read'] is not True:raise ValueError('MAIL_APP_AFTER_UNVERIFIED')
                if old['read'] is not True:fields['read']={'before':old['read'],'after':True}
            rows[mid]={'identity':{k:old[k] for k in ('rfc','from','subject')},
                'id':row['id'],'before':old['mailbox'],'after':row['mailbox'],'fields':fields}
        return {'kind':'mail_move','account_id':before['account_id'],'values':rows}
    rows={}
    for mid,old in before['values'].items():
        observed=after['values'][mid]
        if any(old[k]!=observed[k] for k in ('id','rfc','from','subject','mailbox')):
            raise ValueError('MAIL_APP_MESSAGE_CHANGED')
        delta={}
        for field in ('read','flagged'):
            if field not in request:continue
            if observed[field] is not request[field]:raise ValueError('MAIL_APP_AFTER_UNVERIFIED')
            if old[field]!=observed[field]:delta[field]={'before':old[field],'after':observed[field]}
        if delta:rows[mid]={'identity':{k:old[k] for k in ('id','rfc','from','subject','mailbox')},'fields':delta}
    return {'account_id':before['account_id'],'values':rows}


def expected(request,before,mail):
    """The proposed after-state makes the complete inverse available before any effect."""
    after=deepcopy(before)
    if mail:
        for row in after['values'].values():
            if request['action'] in {'mail_move','mail_app_organize'}:
                row.update(id=None,mailbox=request['mailbox'])
                if request.get('mark_read'):row['read']=True
            for field in ('read','flagged'):
                if field in request:row[field]=request[field]
    elif before['kind']=='organization':
        from hermes_packs.mail import organization_state
        return organization_state.expected(request['_snapshot'])
    elif before['kind'] in {'label_create','draft_create'}:return None
    elif before['kind']=='label':after['value']['name']=request['label_name'].strip()
    else:
        changes=request['_snapshot'].get('changes') if request['action'] in {'modify','label_apply','inbox_restore'} else {'addLabelIds':[],'removeLabelIds':['TRASH']}
        for row in after['values'].values():
            row['labelIds']=sorted((set(row['labelIds'])|set(changes['addLabelIds']))-set(changes['removeLabelIds']))
    return after


def execute(td,request,runner=None,mail_runner=None):
    from hermes_constants import get_hermes_home
    home=get_hermes_home();mail=full.is_mail(td,request)
    preview=request['_snapshot']
    if preview.get('inverse_ready') is not True and preview.get('journal_required') is not True:
        # An unprepared operation retains the native preapproval path, with no false undo promise.
        return invoke(td,request,mail,runner,mail_runner)
    if not write_policy.owner_chat(home,td.get_session_env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    before=deepcopy(preview['_undo_before'])
    planned_after=expected(request,before,mail)
    reversible=preview.get('inverse_ready') is True
    prepared_inverse=inverse(request,before,planned_after,mail) if reversible else None
    with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home)) as (data,save):
        entry=dict(key=uuid.uuid4().hex,created_at=time.time(),journal_kind='mail',
            conversation={k.lower():td.get_session_env('HERMES_SESSION_'+k,'') for k in ('PLATFORM','USER_ID','CHAT_ID','THREAD_ID','SCOPE_ID')},
            arguments={k:deepcopy(v) for k,v in request.items() if not k.startswith('_')},
            backend='mail_app' if mail else 'gmail',before=before,
            after=None,inverse=prepared_inverse,status='pending',consumed=False)
        if 'plan' in preview:entry['plan']=deepcopy(preview['plan'])
        data['entries'].append(entry);save()
        def effect(row):
            if row.get('kind') not in ('label_create','filter_create','draft_create') or not isinstance(row.get('id'),str) or not 1<=len(row['id'])<=256:raise ValueError('GMAIL_RESOURCE_ID_MISMATCH')
            entry.setdefault('effects',[]).append(deepcopy(row));save()
        try:
            result=invoke(td,request,mail,runner,mail_runner,on_progress=effect if preview.get('has_new_ids') else None)
            after=result.pop('_undo_after',None)
            if result.get('ok') is not True or result.get('verified') is not True or after is None:
                entry['status']='uncertain';save();return result
            if not reversible:
                entry.update(after=after,status='done',limitations=preview.get('limitation'));save()
                return dict(result,undo_available=False,limitation=preview.get('limitation'))
            if not mail and before['kind']=='messages' and after!=planned_after:
                raise ValueError('GMAIL_LABEL_STATE_CHANGED')
            actual_inverse=inverse(request,entry['before'],after,mail)
            if not mail and before['kind'] in {'label_create','draft_create'}:
                owned=actual_inverse['draft']['id'] if before['kind']=='draft_create' else actual_inverse['id'] if actual_inverse['created'] else None
                if owned and not any(row.get('id')==owned and row.get('kind')==before['kind'] for row in entry.get('effects',[])):
                    raise ValueError('GMAIL_RESOURCE_ID_MISMATCH')
                entry['inverse']=actual_inverse
            elif mail and actual_inverse.get('kind')=='mail_move':
                template=deepcopy(actual_inverse)
                for row in template['values'].values():
                    if not re.fullmatch(r'm[0-9]{1,18}',str(row['id'])):raise ValueError('MAIL_APP_MOVE_UNVERIFIED')
                    row['id']=None
                if template!=prepared_inverse:raise ValueError('MAIL_INVERSE_CHANGED')
                entry['inverse']=actual_inverse
            elif actual_inverse!=prepared_inverse:raise ValueError('MAIL_INVERSE_CHANGED')
            entry.update(after=after,status='done');save()
        except Exception:
            entry['status']='uncertain';save();raise
    result.update(undo_key=entry['key'],message=write_policy.result_text('메일 변경을 저장했어요.',entry['key']))
    return result


def restore(home,td,entry,runner=None,mail_runner=None):
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    if entry.get('status')!='done' or not entry.get('inverse'):raise ValueError('MAIL_CHANGE_UNVERIFIED')
    if app_registry.tool_granted(home,'gmail_direct') is False:raise ValueError('APP_NOT_CONNECTED')
    args=entry['arguments']
    if full.account(td,args)!=args['account']:raise ValueError('MAIL_ACCOUNT_CHANGED')
    if p:=full.problem(td,args):raise ValueError(p)
    if td._personal_owner_error('gmail_direct'):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    mail=entry['backend']=='mail_app'
    if full.is_mail(td,args)!=mail:raise ValueError('MAIL_BACKEND_CHANGED')
    if app_registry.explicit(app_registry.root_of(home),app_registry.profile_of(home)) and mail:
        if app_scope.mail_allowed(home,args) is not True:raise ValueError('APP_ACCOUNT_OUT_OF_SCOPE')
    return invoke(td,{**args,'_app_inverse':deepcopy(entry['inverse'])},mail,runner,mail_runner,restore=True)


def register(ctx,home,td):
    from hermes_governance import app_results
    def undo(entry):
        with app_tools.host_source(home):return restore(home,td,entry)
    app_results.register(ctx,home,'mail',undo)
