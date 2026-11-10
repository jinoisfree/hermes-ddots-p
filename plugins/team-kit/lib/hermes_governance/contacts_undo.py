"""Private Contacts journals: field deltas through Contacts.app, new-ID deletion through native."""
from contextvars import ContextVar
import json
import time
import uuid
from hermes_facility import app_registry
from hermes_governance import app_tools,app_undo,write_policy

_CAPABILITY=object()
_PREPARED=ContextVar('contacts_prepared_write',default=None)


def private_request(context):
    return context.get('_contacts_private') if context.get('_contacts_capability') is _CAPABILITY else None


def prepared():return _PREPARED.get()


def private(td,request,context):
    method=td._contacts_direct_mutation if request['action']=='_delete_created' else td._contacts_direct_lookup
    reply=json.loads(method({'action':'access'},**dict(context,_contacts_capability=_CAPABILITY,_contacts_private=request)))
    if reply.get('ok') is not True:raise ValueError(reply.get('error','CONTACTS_SNAPSHOT_FAILED'))
    return reply


def snapshot(td,kind,identifier,context):
    value=private(td,{'action':'_snapshot','kind':kind,'id':identifier},context).get('snapshot')
    if not isinstance(value,dict) or value.get('id')!=identifier or value.get('kind')!=kind or not isinstance(value.get('state'),dict):
        raise ValueError('CONTACTS_SNAPSHOT_UNVERIFIED')
    return value


def note(td,identifier,context):
    value=td._contacts_note_get(identifier,runner=context.get('runner'))
    if value.get('note_available') is not True:raise ValueError('CONTACTS_NOTE_AUTOMATION_PERMISSION_REQUIRED')
    if len(value['note'].encode())>65536:raise ValueError('CONTACTS_NOTE_SNAPSHOT_LIMIT')
    return value['note']


def note_access(home):
    from hermes_facility import mac_permission
    root=app_registry.root_of(home)
    state,_=mac_permission.judge(root,'app:com.apple.AddressBook')
    if state!='connected':raise ValueError('CONTACTS_PERMISSION_REQUIRED')
    state,_=mac_permission.judge_automation(root,'com.apple.AddressBook')
    if state!='connected':raise ValueError('CONTACTS_NOTE_AUTOMATION_PERMISSION_REQUIRED')


def execute(home,td,args,next_call,context):
    if args.get('action') in ('update','group_rename','group_add','group_remove'):return next_call(args)  # the single app writer journals every update caller
    if write_policy.classify('contacts_direct_mutation',args)!=write_policy.REVERSIBLE:return next_call(args)
    if not write_policy.owner_chat(home,app_tools.env):return td._error('APP_OWNER_CHAT_REQUIRED',mutation_calls=0)
    attempted=False
    try:
        payload,error=td._contacts_arguments(args,mutation=True)
        if error:raise ValueError(error)
        action=payload['action'];kind='group' if action.startswith('group_') else 'contact'
        identifier=payload.get('group_id') if kind=='group' else payload.get('contact_id')
        before=snapshot(td,kind,identifier,context) if identifier and action!='import_vcf' else None
        changes_note='note' in payload or payload.get('clear_note') is True
        before_note=note(td,identifier,context) if changes_note and before else None
        if action in ('create','import_vcf'):note_access(home)  # inverse deletion must be able to check NOTE
        with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home)) as (data,save):
            entry=dict(key=uuid.uuid4().hex,created_at=time.time(),conversation=app_tools.conversation(),journal_kind='contacts',
                tool='contacts_direct_mutation',arguments=payload,before=before,note_before=before_note,after=[],inverse=[],status='pending',consumed=False)
            data['entries'].append(entry);save()
            def record_targets(ids):
                if not isinstance(ids,list) or any(not isinstance(v,str) or not v for v in ids):raise ValueError('CONTACTS_TARGET_UNVERIFIED')
                entry['native_targets']=ids;save()
            token=_PREPARED.set({'before':before,'note_before':'' if changes_note and before is None else before_note,'record_targets':record_targets})
            try:
                attempted=True;result=json.loads(next_call(args))
                proven=result.pop('_private_after',[])
                snapshot_error=result.pop('_private_after_error',None)
                # Preserve returned target ids even if a later read/NOTE verification fails.
                # Recovery must never rely on guessing a new contact by name.
                entry['native_result']=result;save()
                if result.get('ok') is not True:
                    entry['status']='uncertain';save();return json.dumps(result,ensure_ascii=False)
                if result.get('mutation_calls')==0 and not changes_note:
                    entry['status']='unchanged';save();return json.dumps(result,ensure_ascii=False)
                ids=([row['identifier'] for row in result.get('after',[])] if action=='import_vcf' else
                     [result.get('target_id') or identifier or (result.get('after') or {}).get('identifier')])
                if any(not isinstance(sid,str) or not sid for sid in ids):raise ValueError('CONTACTS_TARGET_UNVERIFIED')
                if snapshot_error or len(proven)!=len(ids):raise ValueError('CONTACTS_SNAPSHOT_UNVERIFIED')
                for sid in ids:
                    after=next((r for r in proven if r.get('id')==sid and r.get('kind')==kind),None)
                    if after is None or snapshot(td,kind,sid,context)['state']!=after['state']:
                        raise ValueError('CONTACTS_AFTER_CHANGED')
                    inverse=dict(kind=kind,id=sid,expected=after,desired=before)
                    if changes_note or (kind=='contact' and before is None):
                        inverse.update(note_before=before_note,note_after=note(td,sid,context))
                        if inverse['note_after']!=(result.get('note','') if changes_note else ''):
                            raise ValueError('CONTACTS_NOTE_AFTER_CHANGED')
                    entry['after'].append(after);entry['inverse'].append(inverse);save()
                if changes_note and result.get('note_applied') is not True:raise ValueError('CONTACTS_NOTE_WRITE_UNVERIFIED')
                entry['status']='done';save()
            except Exception:
                entry['status']='uncertain';save();raise
            finally:_PREPARED.reset(token)
        if ids:
            result.update(undo_key=entry['key'],message=write_policy.result_text('연락처 변경을 저장했어요.',entry['key']))
        return json.dumps(result,ensure_ascii=False)
    except (ValueError,OSError,KeyError,TypeError) as error:
        return td._error(str(error) if isinstance(error,ValueError) else 'CONTACTS_JOURNAL_FAILED',
                         mutation_calls=None if attempted else 0,applied=None if attempted else False,execution_uncertain=attempted)


def restore(home,td,entry,context=None):
    context=context or {}
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    if app_registry.tool_granted(home,'contacts_direct_mutation') is False:raise ValueError('APP_NOT_CONNECTED')
    if entry.get('status')!='done':raise ValueError('CONTACTS_CHANGE_UNVERIFIED')
    if entry.get('writer')=='contacts_app':return restore_fields(home,td,entry,context)
    results=[]
    for inverse in reversed(entry['inverse']):
        if inverse.get('desired') is not None:raise ValueError('CONTACTS_OLD_INVERSE_UNSUPPORTED')
        request={**inverse,'action':'_delete_created'}
        try:
            current=snapshot(td,inverse['kind'],inverse['id'],context)
            allowed=[inverse['expected']['state']]
            if inverse['desired']:allowed.append(inverse['desired']['state'])
            if current['state'] not in allowed:raise ValueError('UNDO_CONFLICT')
            if 'note_after' in inverse:
                actual_note=note(td,inverse['id'],context)
                if actual_note not in [inverse['note_after'],inverse.get('note_before')]:raise ValueError('UNDO_CONFLICT')
            private(td,request,context)
            if inverse.get('note_before') is not None and actual_note!=inverse['note_before']:
                checked=td._contacts_note_set(inverse['id'],inverse['note_before'],expected=inverse['note_after'],runner=context.get('runner'))
                if checked.get('note_applied') is not True:raise ValueError('CONTACTS_NOTE_RESTORE_UNVERIFIED')
            results.append({'id':inverse['id'],'status':'restored'})
        except ValueError as error:
            if str(error) in ('CONTACTS_NOT_FOUND','CONTACTS_GROUP_NOT_FOUND') and inverse['desired'] is None:
                results.append({'id':inverse['id'],'status':'restored','already':True})
            else:results.append({'id':inverse['id'],'status':'skipped','reason':str(error)})
    return {'ok':all(r['status']=='restored' for r in results),'results':results}


def register(ctx,home,td):
    from hermes_governance import app_results
    from hermes_governance.app_tools import host_source
    def inverse(entry):
        with host_source(home):return restore(home,td,entry)
    app_results.register(ctx,home,'contacts',inverse)


def equivalent(left,right):
    if left is None:left=''
    if right is None:right=''
    if isinstance(left,dict) and isinstance(right,dict):return left.keys()==right.keys() and all(equivalent(left[k],right[k]) for k in left)
    if isinstance(left,list) and isinstance(right,list):return len(left)==len(right) and all(equivalent(a,b) for a,b in zip(left,right))
    return left==right


def update(home,td,payload,context):
    from hermes_packs.native_tools import contacts_app as writer
    if not write_policy.owner_chat(home,app_tools.env):return td._error('APP_OWNER_CHAT_REQUIRED',mutation_calls=0)
    external=write_policy.classify('contacts_direct_mutation',payload)==write_policy.EXTERNAL
    if external and not app_tools.authorized('contacts_direct_mutation',payload):return td._error('APP_APPROVAL_REQUIRED',mutation_calls=0)
    attempted=False
    try:
        kind='group' if payload['action'].startswith('group_') else 'contact'
        identifier=payload['group_id'] if kind=='group' else payload['contact_id']
        if kind=='contact':
            native=json.loads(td._contacts_direct_lookup({'action':'get','contact_id':identifier},**context))
            if native.get('ok') is not True:raise ValueError(native.get('error','CONTACTS_NOT_FOUND'))
            if (native.get('before') or {}).get('display_name')!=payload['expected_name']:raise ValueError('CONTACTS_IDENTITY_MISMATCH')
        before_record=writer.read(home,identifier,kind=kind,contact_ids=payload.get('contact_ids',[]))
        if kind=='group':
            if payload['action']=='group_rename':
                if before_record['name']!=payload['expected_name']:raise ValueError('CONTACTS_IDENTITY_MISMATCH')
                changes={'name':payload['name']}
            else:
                old=set(before_record['member_ids']);ids=set(payload['contact_ids'])
                changes={'member_ids':sorted(old|ids if payload['action']=='group_add' else old-ids)}
        else:changes=writer.plan(before_record,payload)
        before=writer.selected(before_record,{k:v for k,v in changes.items() if k!='image_path'})
        changes={k:v for k,v in changes.items() if k=='image_path' or (k=='address' and
            (before[k] is None or any(not equivalent(before[k].get(f),v[f]) for f in v))) or (k!='address' and not equivalent(before[k],v))}
        before={k:v for k,v in before.items() if k in changes}
        if not changes:return json.dumps({'ok':True,'mutation_calls':0,'authority':'Contacts.app','target_id':identifier})
        # Build/validate the entire fixed writer before publishing the pending row.
        expected=dict(before,display_name=before_record['display_name']) if kind=='contact' else before
        writer.render(identifier,expected,changes,kind=kind)
        with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home)) as (data,save):
            entry=dict(key=uuid.uuid4().hex,created_at=time.time(),conversation=app_tools.conversation(),journal_kind='contacts',
                writer='contacts_app',kind=kind,id=identifier,before=before,after={},status='pending',consumed=False)
            data['entries'].append(entry);save();attempted=True
            try:
                after_record=writer.apply(home,entry['id'],expected,changes,kind=kind)
                after=writer.selected(after_record,{k:v for k,v in changes.items() if k!='image_path'})
                for key,desired in changes.items():
                    if key=='image_path':continue
                    actual=after[key]
                    if key=='address':
                        if actual is None or any(not equivalent(actual.get(f),v) for f,v in desired.items()):raise ValueError('CONTACTS_APP_READBACK_UNVERIFIED')
                    elif not equivalent(actual,desired):raise ValueError('CONTACTS_APP_READBACK_UNVERIFIED')
                if 'address' in before and before['address'] is None:
                    after['address']=after_record['addresses'][0]
                    entry['created_address_native']=snapshot(td,'contact',entry['id'],context)['state']['addresses'][0]
                entry.update(after=after,status='external' if external else 'done');save()
            except Exception:entry['status']='uncertain';save();raise
        result=dict(ok=True,authority='Contacts.app',action=payload['action'],target_id=entry['id'],before=before,after=after,mutation_calls=1,applied=True)
        if 'note' in after:result.update(note_applied=True,note=after['note'] or '',note_source='contacts_app')
        if external:result['message']='승인한 연락처 변경을 저장했어요. 사진은 자동으로 되돌릴 수 없어요.'
        else:result.update(undo_key=entry['key'],message=write_policy.result_text('연락처 변경을 저장했어요.',entry['key']))
        return json.dumps(result,ensure_ascii=False)
    except (ValueError,OSError,KeyError,TypeError) as error:
        return td._error(str(error) if isinstance(error,ValueError) else 'CONTACTS_APP_WRITE_FAILED',
                         mutation_calls=None if attempted else 0,applied=None if attempted else False,execution_uncertain=attempted)


def restore_fields(home,td,entry,context):
    from hermes_packs.native_tools import contacts_app as writer
    results=[]
    for key,before in entry['before'].items():
        try:
            current=writer.read(home,entry['id'],kind=entry.get('kind','contact'));fields={key:entry['after'][key]}
            now=writer.selected(current,fields)[key]
            if equivalent(now,before):results.append({'field':key,'status':'restored','already':True});continue
            if not equivalent(now,entry['after'][key]):raise ValueError('UNDO_CONFLICT')
            if key=='address' and before is None:
                native=snapshot(td,'contact',entry['id'],context)['state']['addresses']
                if not native or native[0]!=entry['created_address_native']:raise ValueError('UNDO_CONFLICT')
            after=writer.apply(home,entry['id'],fields,{key:before},kind=entry.get('kind','contact'))
            if not equivalent(writer.selected(after,fields)[key],before):raise ValueError('CONTACTS_APP_READBACK_UNVERIFIED')
            results.append({'field':key,'status':'restored'})
        except (ValueError,OSError) as error:results.append({'field':key,'status':'skipped','reason':str(error)})
    return {'ok':all(row['status']=='restored' for row in results),'results':results}
