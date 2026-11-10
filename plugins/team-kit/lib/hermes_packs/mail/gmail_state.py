"""Private reversible Gmail state; transport identity is checked before reads/writes."""
from copy import deepcopy
from .gmail_rules import RuleError

READY=frozenset({'modify','untrash','label_rename','label_apply','inbox_restore','label_create','draft_create'})


def account(service,request):
    expected=request.get('account')
    actual=service.users().getProfile(userId='me').execute().get('emailAddress')
    if not isinstance(expected,str) or not isinstance(actual,str) or actual.casefold()!=expected.casefold():
        raise RuleError('GMAIL_ACCOUNT_MISMATCH')


def snapshot(service,action,preview,request):
    if action=='label_rename':
        row=service.users().labels().get(userId='me',id=request['label_id']).execute()
        if row.get('id')!=request['label_id']:raise RuleError('GMAIL_LABEL_ID_MISMATCH')
        return {'kind':'label','value':deepcopy(row)}
    rows={}
    for mid in preview.get('ids',[]):
        row=service.users().messages().get(userId='me',id=mid,format='minimal').execute()
        if row.get('id')!=mid or not isinstance(row.get('labelIds',[]),list):raise RuleError('GMAIL_MESSAGE_STATE_UNVERIFIED')
        rows[mid]={'id':mid,'labelIds':sorted(set(row.get('labelIds',[])))}
    return {'kind':'messages','values':rows}


def prepare(service,request,result):
    if request['action']=='draft_create':
        return dict(result,inverse_ready=True,has_new_ids=True,_undo_before={'kind':'draft_create'})
    if request['action']=='label_create':
        from . import gmail_extra as extra
        wanted=request['label_name'].strip().casefold()
        rows=service.users().labels().list(userId='me').execute().get('labels',[])
        matches=[row for row in rows if row.get('name','').casefold()==wanted]
        if len(matches)>1:raise RuleError('GMAIL_LABEL_NAME_CONFLICT')
        if matches and matches[0].get('type')!='user':raise RuleError('GMAIL_USER_LABEL_REQUIRED')
        existing=service.users().labels().get(userId='me',id=matches[0]['id']).execute() if matches else None
        scopes=extra.token_scopes(request)
        ready=extra.FILTER_SCOPE in scopes and bool(scopes & {'https://mail.google.com/','https://www.googleapis.com/auth/gmail.modify'})
        if ready:service.users().settings().filters().list(userId='me').execute()
        return dict(result,inverse_ready=ready,journal_required=True,has_new_ids=existing is None,
            limitation=None if ready else '되돌릴 때 라벨을 사용하는 메일·필터를 확인할 권한이 없어 먼저 승인받아요.',
            _undo_before={'kind':'label_create','name':existing['name'] if existing else request['label_name'].strip(),'existing':deepcopy(existing)})
    if request['action'] not in READY:return result
    before=snapshot(service,request['action'],result,request)
    return dict(result,inverse_ready=True,_undo_before=before)


def check(service,request,preview):
    if request['action']=='draft_create':return
    if request['action']=='label_create':
        before=preview['_undo_before'];wanted=before['name'].casefold()
        matches=[row for row in service.users().labels().list(userId='me').execute().get('labels',[]) if row.get('name','').casefold()==wanted]
        if before['existing'] is None and matches or before['existing'] is not None and [row.get('id') for row in matches]!=[before['existing']['id']]:
            raise RuleError('GMAIL_ORIGINAL_CHANGED')
        return
    if preview.get('inverse_ready') is not True:return
    if snapshot(service,request['action'],preview,request)!=preview['_undo_before']:
        raise RuleError('GMAIL_ORIGINAL_CHANGED')


def inverse(request,before,after):
    if before['kind']=='draft_create':
        return {'kind':'draft_create','draft':deepcopy(after['draft']) if after else None}
    if before['kind']=='label_create':
        label=after.get('label') if after else before['existing']
        if label and (not isinstance(label.get('id'),str) or label.get('type')!='user' or label.get('name')!=before['name']):raise RuleError('GMAIL_LABEL_ID_MISMATCH')
        return {'kind':'label_create','created':before['existing'] is None,'id':label['id'] if label else None,'after':deepcopy(label)}
    if before['kind']=='label':
        if before['value']['id']!=after['value']['id']:raise RuleError('GMAIL_LABEL_ID_MISMATCH')
        return {'kind':'label','id':before['value']['id'],'before':before['value']['name'],'after':after['value']['name']}
    changes=request.get('_snapshot',{}).get('changes') if request['action'] in {'modify','label_apply','inbox_restore'} else {'addLabelIds':[],'removeLabelIds':['TRASH']}
    if not isinstance(changes,dict):raise RuleError('GMAIL_INVERSE_UNVERIFIED')
    touched=set(changes['addLabelIds'])|set(changes['removeLabelIds']);rows={}
    for mid,old in before['values'].items():
        observed=after['values'][mid];delta={}
        for label in touched:
            first=label in old['labelIds'];last=label in observed['labelIds']
            desired=label in changes['addLabelIds']
            if last!=desired:raise RuleError('GMAIL_AFTER_UNVERIFIED')
            if first!=last:delta[label]={'before':first,'after':last}
        if delta:rows[mid]=delta
    return {'kind':'messages','values':rows}


def restore(service,request):
    """Only changed label membership/name is restored; unrelated owner edits survive."""
    from .gmail_extra import user_label,safe_error
    account(service,request)
    change=request['_app_inverse'];results=[]
    if change['kind']=='draft_create':
        draft=change['draft'];identifier=draft['id']
        try:current=draft_state(service,identifier)
        except Exception as error:
            if getattr(getattr(error,'resp',None),'status',None)==404:return {'ok':True,'already':True}
            if isinstance(error,RuleError):return {'ok':False,'error':str(error)}
            raise
        if current!=draft:return {'ok':False,'error':'UNDO_CONFLICT'}
        service.users().drafts().delete(userId='me',id=identifier).execute()
        try:draft_state(service,identifier)
        except Exception as error:
            if getattr(getattr(error,'resp',None),'status',None)==404:return {'ok':True}
            raise
        return {'ok':False,'error':'GMAIL_RESTORE_UNVERIFIED'}
    if change['kind']=='label_create':
        if change['created'] is not True:return {'ok':True,'already':True}
        try:row=service.users().labels().get(userId='me',id=change['id']).execute()
        except Exception as error:
            if getattr(getattr(error,'resp',None),'status',None)==404:return {'ok':True,'already':True}
            raise
        if row!=change['after']:return {'ok':False,'error':'UNDO_CONFLICT'}
        if service.users().messages().list(userId='me',labelIds=[change['id']],includeSpamTrash=True,maxResults=1).execute().get('messages'):
            return {'ok':False,'error':'GMAIL_LABEL_IN_USE'}
        filters=service.users().settings().filters().list(userId='me').execute().get('filter',[])
        if any(change['id'] in values for f in filters for key,values in f.get('action',{}).items() if key in ('addLabelIds','removeLabelIds')):
            return {'ok':False,'error':'GMAIL_LABEL_IN_USE'}
        service.users().labels().delete(userId='me',id=change['id']).execute()
        rows=service.users().labels().list(userId='me').execute().get('labels',[])
        return {'ok':not any(row.get('id')==change['id'] for row in rows)}
    if change['kind']=='label':
        sid=user_label(service,change['id']);row=service.users().labels().get(userId='me',id=sid).execute()
        if row.get('name')==change['before']:return {'ok':True,'already':True}
        if row.get('name')!=change['after']:return {'ok':False,'error':'UNDO_CONFLICT'}
        known=service.users().labels().list(userId='me').execute().get('labels',[])
        if any(v.get('id')!=sid and str(v.get('name','')).casefold()==change['before'].casefold() for v in known):
            return {'ok':False,'error':'GMAIL_LABEL_NAME_CONFLICT'}
        service.users().labels().patch(userId='me',id=sid,body={'name':change['before']}).execute()
        after=service.users().labels().get(userId='me',id=sid).execute()
        return {'ok':after.get('name')==change['before'],'error':None if after.get('name')==change['before'] else 'GMAIL_RESTORE_UNVERIFIED'}
    for mid,delta in change['values'].items():
        try:
            message=service.users().messages().get(userId='me',id=mid,format='minimal').execute()
            if message.get('id')!=mid:raise RuleError('GMAIL_MESSAGE_ID_MISMATCH')
            labels=set(message.get('labelIds',[]));add=[];remove=[]
            for label,values in delta.items():
                if (label in labels)==values['before']:continue
                if (label in labels)!=values['after']:raise RuleError('UNDO_CONFLICT')
                if not label.isupper():user_label(service,label)
                (add if values['before'] else remove).append(label)
            if add or remove:
                service.users().messages().modify(userId='me',id=mid,body={'addLabelIds':add,'removeLabelIds':remove}).execute()
            after=set(service.users().messages().get(userId='me',id=mid,format='minimal').execute().get('labelIds',[]))
            results.append({'id':mid,'status':'restored' if all((k in after)==v['before'] for k,v in delta.items()) else 'skipped'})
        except Exception as error:results.append({'id':mid,'status':'skipped','reason':safe_error(error,'restore')})
    return {'ok':all(v['status']=='restored' for v in results),'results':results}


def draft_state(service,identifier):
    """Keep complete draft bytes and stable message identity, never a mailbox guess."""
    draft=service.users().drafts().get(userId='me',id=identifier,format='raw').execute()
    message=draft.get('message',{})
    if (draft.get('id')!=identifier or not isinstance(message.get('id'),str) or not message['id']
            or not isinstance(message.get('raw'),str) or not message['raw']
            or not isinstance(message.get('labelIds'),list) or 'DRAFT' not in message['labelIds']
            or 'SENT' in message['labelIds']):raise RuleError('GMAIL_DRAFT_UNVERIFIED')
    return {'id':identifier,'message':{**{k:message[k] for k in ('id','raw')},
        'threadId':message.get('threadId'),'labelIds':sorted(message['labelIds'])}}
