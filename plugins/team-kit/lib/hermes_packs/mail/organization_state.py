"""Bounded, frozen Gmail organization plans; future-delivery rules stay preapproved."""
from copy import deepcopy
from . import gmail_extra as api,gmail_rules,gmail_state

ACTIONS=frozenset({'filter_create','filter_delete','mail_organize'})


def resources(service):
    labels=service.users().labels().list(userId='me').execute().get('labels',[])
    filters=service.users().settings().filters().list(userId='me').execute().get('filter',[])
    return {'labels':sorted(deepcopy(labels),key=lambda v:v['id']),
            'filters':sorted(deepcopy(filters),key=lambda v:v['id'])}


def prepare(service,request):
    action=request['action'];gmail_rules.validate_operation(action,request)
    needs_resources=bool(request.get('rules') or request.get('delete_filter_ids')) or action in ('filter_create','filter_delete')
    before=resources(service) if needs_resources else {'labels':[],'filters':[]};names={row['name'].casefold():row['id'] for row in before['labels'] if row.get('type')=='user'}
    systems={row['name'].casefold() for row in before['labels'] if row.get('type')=='system'}
    rules=request.get('rules',[]) if action=='mail_organize' else []
    deletes=list(dict.fromkeys(request.get('delete_filter_ids',[]))) if action=='mail_organize' else [request['filter_id']] if action=='filter_delete' else []
    known={row['id']:row for row in before['filters']}
    if any(key not in known for key in deletes):raise gmail_rules.RuleError('GMAIL_FILTER_NOT_FOUND')
    if action=='filter_create':api.user_label(service,request['label_id'])
    queries=request.get('restore_inbox_queries',[]) if action=='mail_organize' else []
    rule_ids=[];restore_ids=[];changes={};new_rule=False
    existing={api._filter_key(row.get('criteria',{}),row.get('action',{})) for row in before['filters'] if row['id'] not in deletes}
    for index,rule in enumerate(rules,1):
        name=rule['label_name'].strip().casefold()
        if name in systems:raise gmail_rules.RuleError('GMAIL_USER_LABEL_REQUIRED',index)
        ids=api.message_ids(service,gmail_rules.criteria_query(rule['criteria'])) if rule.get('apply_existing',True) else []
        rule_ids.append(ids);label=names.get(name)
        if label is None or api._filter_key(rule['criteria'],api.filter_action(label,rule)) not in existing:new_rule=True
        if label:
            for mid in ids:
                change=changes.setdefault(mid,{'addLabelIds':[],'removeLabelIds':[]})
                change['addLabelIds'].append(label)
                if rule.get('skip_inbox'):change['removeLabelIds'].append('INBOX')
    for query in queries:
        ids=api.message_ids(service,'-in:trash -in:spam ('+query+')');restore_ids.append(ids)
        # Restore runs after classification, so its INBOX operation wins.
        for mid in ids:
            change=changes.setdefault(mid,{'addLabelIds':[],'removeLabelIds':[]})
            change['removeLabelIds']=[v for v in change['removeLabelIds'] if v!='INBOX']
            change['addLabelIds'].append('INBOX')
    if (new_rule or deletes or action=='filter_create') and api.FILTER_SCOPE not in api.token_scopes(request):
        raise gmail_rules.RuleError('GMAIL_SCOPE_MISSING:gmail.settings.basic')
    all_ids=sorted({mid for ids in rule_ids+restore_ids for mid in ids})
    messages=gmail_state.snapshot(service,'modify',{'ids':all_ids},{})['values']
    for value in changes.values():
        value['addLabelIds']=sorted(set(value['addLabelIds']));value['removeLabelIds']=sorted(set(value['removeLabelIds']))
    ready=action=='mail_organize' and not deletes and not new_rule
    return dict(ok=True,ids=all_ids,matched_count=len(all_ids),inverse_ready=ready,journal_required=True,
        has_new_ids=action=='filter_create' or new_rule,
        resources_required=needs_resources,
        _undo_before={'kind':'organization','resources':before,'values':messages},
        plan={'rule_ids':rule_ids,'restore_ids':restore_ids,'changes':changes},
        limitation=None if ready else '자동 규칙은 새로 들어온 메일에도 작용하며, 삭제한 필터는 같은 ID로 복원할 수 없어 먼저 승인받아요.')


def check(service,preview):
    old=preview['_undo_before']
    if preview.get('resources_required') and resources(service)!=old['resources']:raise gmail_rules.RuleError('GMAIL_ORIGINAL_CHANGED')
    current=gmail_state.snapshot(service,'modify',{'ids':preview['ids']},{})['values']
    if current!=old['values']:raise gmail_rules.RuleError('GMAIL_ORIGINAL_CHANGED')


def after(service,preview):
    return {'kind':'organization','resources':resources(service) if preview.get('resources_required') else {'labels':[],'filters':[]},
        'values':gmail_state.snapshot(service,'modify',{'ids':preview['ids']},{})['values']}


def expected(preview):
    value=deepcopy(preview['_undo_before'])
    for mid,change in preview['plan']['changes'].items():
        labels=set(value['values'][mid]['labelIds'])
        value['values'][mid]['labelIds']=sorted((labels|set(change['addLabelIds']))-set(change['removeLabelIds']))
    return value


def inverse(preview,observed):
    planned=expected(preview)
    if planned!=observed:raise gmail_rules.RuleError('GMAIL_LABEL_STATE_CHANGED')
    values={}
    for mid,change in preview['plan']['changes'].items():
        before={'kind':'messages','values':{mid:preview['_undo_before']['values'][mid]}}
        after_value={'kind':'messages','values':{mid:observed['values'][mid]}}
        delta=gmail_state.inverse({'action':'modify','_snapshot':{'changes':change}},before,after_value)
        values.update(delta['values'])
    return {'kind':'messages','values':values}


def write(service,request,report):
    preview=request['_snapshot'];check(service,preview);action=request['action']
    try:
        if action=='mail_organize':
            args={k:request[k] for k in ('rules','delete_filter_ids','restore_inbox_queries','root','token_home') if k in request}
            result=api.organize(service,args,prepared=preview,report=report)
            if result.get('ok') is not True:return result
        elif action=='filter_create':
            args={k:request[k] for k in ('criteria','label_id','skip_inbox','mark_read','root','token_home') if k in request}
            result=api.filter_create(service,args)
            if report:report({'_event':'gmail_effect','kind':'filter_create','id':result['id']})
            result.update(ok=True,mutation_calls=1)
        else:
            result=api.filter_delete(service,request['filter_id']);result.update(ok=True,mutation_calls=1)
        observed=after(service,preview)
        if preview['inverse_ready']:
            inverse(preview,observed)
        elif action=='filter_create':
            row=next((r for r in observed['resources']['filters'] if r['id']==result['id']),None)
            if row is None or api._filter_key(row.get('criteria',{}),row.get('action',{}))!=api._filter_key(request['criteria'],api.filter_action(request['label_id'],request)):
                raise gmail_rules.RuleError('GMAIL_AFTER_UNVERIFIED')
        elif action=='filter_delete':
            if any(row['id']==request['filter_id'] for row in observed['resources']['filters']):raise gmail_rules.RuleError('GMAIL_AFTER_UNVERIFIED')
        else:
            labels={row['id']:row for row in observed['resources']['labels']};filters={row['id']:row for row in observed['resources']['filters']}
            for rule,row in zip(request.get('rules',[]),result.get('results',[])):
                label=labels.get(row['label_id']);saved=filters.get(row['filter_id'])
                if label is None or label['name'].casefold()!=rule['label_name'].strip().casefold() or saved is None:
                    raise gmail_rules.RuleError('GMAIL_AFTER_UNVERIFIED')
                if api._filter_key(saved.get('criteria',{}),saved.get('action',{}))!=api._filter_key(rule['criteria'],api.filter_action(row['label_id'],rule)):
                    raise gmail_rules.RuleError('GMAIL_AFTER_UNVERIFIED')
                for mid in preview['plan']['rule_ids'][row['rule_index']-1]:
                    values=observed['values'][mid]['labelIds']
                    if row['label_id'] not in values or rule.get('skip_inbox') and 'INBOX' in values and mid not in {v for ids in preview['plan']['restore_ids'] for v in ids}:
                        raise gmail_rules.RuleError('GMAIL_AFTER_UNVERIFIED')
            if any('INBOX' not in observed['values'][mid]['labelIds'] for ids in preview['plan']['restore_ids'] for mid in ids):
                raise gmail_rules.RuleError('GMAIL_AFTER_UNVERIFIED')
        return dict(result,ok=True,verified=True,_undo_after=observed)
    except Exception as error:
        return {'ok':False,'status':'unknown','mutation_calls':None,'modified_count':None,'verified':None,'automatic_retry':False,'error':api.safe_error(error,action)}
