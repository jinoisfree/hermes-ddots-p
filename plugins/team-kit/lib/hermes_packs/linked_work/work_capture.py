"""Owner-selected company work creation. Durable steps never replay an uncertain native write."""
from pathlib import Path
import json
import re
import sqlite3
from decimal import Decimal, InvalidOperation
from copy import deepcopy
from hermes_governance.owner_context import current_session_id
from hermes_team_services import task_capture
import time
import uuid

from hermes_packs.linked_work import deadline_time as dates
from hermes_packs.linked_work import work_content as content

MARKER=task_capture.MAIL_MARKER
LEGEND=task_capture.MAIL_LEGEND


def authorized(td, expected=None, choice_ref=None, *, source=None):
    if not td._task_capture_owner_chat():raise ValueError('WORK_CAPTURE_OWNER_CHAT_REQUIRED')
    if problem:=td._personal_role_problem('personal_work_bundle',{}):raise ValueError(problem)
    from hermes_constants import get_hermes_home
    source=source if source is not None else td._current_owner_choice_source()
    if source.get('error'):raise ValueError('WORK_SCOPE_OWNER_TEXT_UNAVAILABLE:'+source['error'])
    post=_answered_message(td,get_hermes_home(),source)
    picked=task_capture.scope_choice(source['text'], legend=LEGEND in post, choice_ref=choice_ref)
    if picked is None:raise ValueError('WORK_SCOPE_CHOICE_REQUIRED: '+LEGEND+'\n'+MARKER)
    if expected is not None and picked!=expected:raise ValueError('WORK_SCOPE_CHOICE_MISMATCH')
    return picked


def calendar_plan(args,source,wanted):
    if not wanted:return None,None
    value=args.get('calendar') or {}
    try:
        evidence=str(value.get('evidence') or '')
        if not evidence or not source.get('text') or evidence not in source['text']:
            raise ValueError('calendar_date_evidence_required')
        start=dates.extract(str(value.get('start') or ''))
        end=dates.extract(str(value.get('end') or ''))
        # Both endpoints must occur in the cited source. Do not invent an end time or duration.
        explicit=dates.extract(evidence) if not value.get('end_evidence') else dates.extract(str(value['end_evidence']))
        if start!=dates.extract(str(value.get('start_evidence') or evidence)) or end!=explicit:
            raise ValueError('calendar_date_evidence_mismatch')
        for key in ('start_evidence','end_evidence'):
            if value.get(key) and value[key] not in source['text']:raise ValueError('calendar_date_evidence_mismatch')
        if end<start:raise ValueError('calendar_end_before_start')
        return {'start':start,'end':end,'all_day':len(start)==10,
                'location':str(value.get('location') or '')},None
    except ValueError as exc:
        return None,str(exc)


class Native:
    def __init__(self,td):
        self.td=td
        from hermes_constants import get_hermes_home
        self.home=Path(get_hermes_home())
        self.store=td._common_work_store()

    def note(self,args):
        tasks=args['tasks'];source=args.get('source') or {}
        summary='- 본문: 내용 | '+str(args.get('body') or args['title']).replace('\n','\n- 본문: 내용 | ')
        summary+=''.join('\n- 할 일: '+('[x] ' if t.get('done') else '[ ] ')+t['text']+' | '+(t.get('due') or '') for t in tasks)
        payload={'action':'create','title':args['title'],'preview_summary':args['title'][:140],
                 'summary':summary,'original_text':source.get('text') or args.get('body') or args['title'],
                 'folder':self.td.DEFAULT_NOTES_FOLDER,'attachments':args.get('attachments') or [],
                 'approved':True,'_skip_common_work':True}
        row=json.loads(self.td._apple_notes_direct_mutation(payload))
        if not row.get('ok'):raise RuntimeError('work_note_creation_unverified')
        return {'id':row['target_id'],'receipt':row}

    def notion(self,args,cid):
        self.store.require_notion(cid)
        from hermes_packs.linked_work.source_adapters import DATABASE
        from hermes_packs.notion import load_api
        n = load_api('_work_capture_notion')
        # Reuse Notion's writable/preflight/undo/verification implementation, with a fixed company DB.
        import hermes_yaml
        settings=hermes_yaml.safe_load((self.home/'config.yaml').read_text())['plugins']['entries']['team-kit']['settings']
        paragraphs=[{'type':'to_do','text':t['text']+(' | '+t['due'] if t.get('due') else ''),'checked':bool(t.get('done'))} for t in args['tasks']]
        if args.get('body'):paragraphs.insert(0,{'type':'paragraph','text':args['body']})
        paragraphs += [{'type':'file','path':p} for p in args.get('attachments') or []]
        due=content.next_due(args)
        payload={'action':'create','common_id':cid,'database_id':DATABASE,
                 'properties':{'업무/프로젝트':args['title'],**({'다음 마감':due} if due else {})},'paragraphs':paragraphs}
        result=json.loads(n.handle(settings['notion'],self.home,payload,files_config=settings.get('files'),chat=True))
        rows=result.get('operations') or []
        created=result.get('created') or next((r.get('result',{}).get('created') for r in rows if r.get('result',{}).get('created')),None)
        if not result.get('ok') or not created or not created.get('id'):raise RuntimeError('work_notion_creation_unverified')
        return {'id':created['id'],'receipt':result}

    def calendar(self,args,plan):
        payload={'action':'create','title':args['title'],**plan,'notes':content.render(args),
                 'approved':True,'_skip_common_work':True}
        if plan['all_day']:payload['alarms']=[]
        row=json.loads(self.td._calendar_direct_mutation(payload))
        if not row.get('ok'):raise RuntimeError('work_calendar_creation_unverified')
        linked=self.td._bundle_native_source('calendar','create',payload,row)
        identifier=linked and linked['source_id']
        if not identifier:raise RuntimeError('work_calendar_identity_unverified')
        return {'id':identifier,'receipt':row}

    def mail(self,cid,source):
        from hermes_packs.linked_work import mail_work
        return mail_work.link(self.store,{**{k:source[k] for k in ('thread_id','message_id','rfc_id','account','subject') if k in source},'common_id':cid})

    def ack(self,source):
        if not source.get('message_id'):return {'ok':True,'skipped':True}
        result=json.loads(self.td._gmail_direct({'action':'ack','ids':[source['message_id']]}))
        if not result.get('ok'):raise RuntimeError('work_mail_ack_unverified')
        return result

    def properties(self,item):
        from hermes_packs.notes import obsidian_notes
        for source in item['sources']:
            if source['domain']=='notes':
                obsidian_notes.sync_properties(self.td,obsidian_notes.disk.Store().read(source['source_id']),item)

    def properties_match(self,item):
        from hermes_packs.notes import obsidian_notes
        expected=obsidian_notes.work_properties(item)
        # Read every linked note, even after a mismatch: another read may be indeterminate.
        matches=[]
        for source in item['sources']:
            if source['domain']=='notes':
                props=obsidian_notes.disk.Store().read(source['source_id'])['properties']
                matches.append(all(props.get(k)==v for k,v in expected.items()))
        return all(matches)

    def source(self,item):
        from hermes_packs.linked_work.work_sources import Sources
        sources=Sources(self.home)
        authority=sources.authority(item,sources.references(item))
        if not authority:raise ValueError('scope_transition_source_required')
        return sources.read(*authority)


def create(td,args,*,native=None):
    picked=authorized(td,choice_ref=args.get('choice_ref'))
    scope,calendar=picked
    source=args.get('source') or {}
    native=native or Native(td)
    if scope is None and not calendar:
        return {'ok':True,'applied':False,'skipped':True,'ack':native.ack(source),'mutation_calls':0}
    title=str(args.get('title') or '').strip()
    if not title:raise ValueError('work_title_required')
    tasks=[]
    for row in args.get('tasks') or []:
        if not isinstance(row,dict) or not str(row.get('text') or '').strip() or '\n' in row['text']:
            raise ValueError('work_task_invalid')
        evidence=str(row.get('evidence') or '')
        if not evidence or evidence not in str(source.get('text') or ''):
            raise ValueError('work_task_source_evidence_required')
        due=dates.extract(row['due']) if row.get('due') else None
        if due:
            due_evidence=str(row.get('due_evidence') or evidence)
            if due_evidence not in str(source.get('text') or '') or dates.extract(due_evidence)!=due:
                raise ValueError('work_task_due_evidence_required')
        tasks.append({'text':row['text'].strip(),'due':due,'done':bool(row.get('done'))})
    plan,warning=calendar_plan(args,source,calendar)
    if not scope and not plan:return {'ok':False,'applied':False,'calendar_skipped':warning,'mutation_calls':0}
    body=str(args.get('body') or '')
    links='\n'.join(v for v in [source.get('url'),*source.get('attachment_names',[])] if v)
    payload={**args,'title':title,'tasks':tasks,'body':body+('\n'+links if links else '')}
    digest=content.digest([picked,payload])
    identity=[source.get('account'),source.get('message_id') or source.get('rfc_id')]
    key=content.digest(identity) if identity[1] else td._bundle_key(content.digest(title))
    with content.ledger(native.home,'work-capture') as (path,state):
        work=state['works'].setdefault(key,{'digest':digest,'steps':{},'scope':scope,'plan':payload,
                                          'created_at':time.time()})
        if work['digest']!=digest:raise ValueError('work_capture_plan_changed_use_existing_receipt')
        if work.get('pending'):return {'ok':False,'status':'uncertain','execution_uncertain':True,'journal_key':key,'common_work':native.store.get(work['common_id']) if work.get('common_id') else None,'steps':work['steps'],'error':'원본을 확인하기 전 자동 재실행하지 않는다.'}
        if work.get('result'):return {**work['result'],'replayed':True}
        def step(name,call):
            if name in work['steps']:return work['steps'][name]
            work['pending']={'step':name,'at':time.time()};content.save(path,state)
            result=call()
            work['steps'][name]=result;work.pop('pending');content.save(path,state)
            return result
        try:
            if scope:
                note=step('notes',lambda:native.note(payload))
                first=('notes',note['id'])
            else:
                event=step('calendar',lambda:native.calendar({**payload,'tasks':[]},plan))
                first=('calendar',event['id'])
            if not work.get('common_id'):
                # Stable ID written before SQLite registration makes a crash recoverable without duplicates.
                work['common_id']='CW-'+uuid.uuid4().hex
                content.save(path,state)
            cid=work['common_id']
            try:item=native.store.get(cid)
            except ValueError:
                item=native.store.create(title=title,sources=[{'domain':first[0],'source_id':first[1]}],
                    common_id=cid,link_reason='approved_mutation',scope=scope or 'private')
            if scope=='shared':
                page=step('notion',lambda:native.notion(payload,cid))
                if not any(r['ref_type']=='notion_page' and r['external_id']==page['id'] for r in item['knowledge_refs']):
                    item=native.store.link_knowledge_ref(cid,ref_type='notion_page',external_id=page['id'],relation_type='documented_by',link_reason='verified_workflow_evidence',receipt_id='work-capture:'+key)
            if scope and plan:
                event=step('calendar',lambda:native.calendar(payload,plan))
                if not any(r['domain']=='calendar' and r['source_id']==event['id'] for r in item['sources']):
                    item=native.store.link(cid,domain='calendar',source_id=event['id'],link_reason='approved_mutation')
            if scope:
                step('properties',lambda:native.properties(item))
            if source.get('thread_id') or source.get('rfc_id'):step('mail',lambda:native.mail(cid,source))
            result={'ok':warning is None,'status':'partial' if warning else 'completed','common_work':native.store.get(cid),
                    'steps':dict(work['steps']),'journal_key':key,'replayed':False,**({'calendar_skipped':warning} if warning else {})}
            work['result']=result;content.save(path,state)
            return result
        except Exception as exc:
            content.save(path,state)
            return {'ok':False,'status':'uncertain' if work.get('pending') else 'partial','execution_uncertain':bool(work.get('pending')),
                    'journal_key':key,'common_id':work.get('common_id'),'steps':dict(work['steps']),
                    'error':type(exc).__name__+': 확인한 단계부터 원본을 대조하고 재개한다. 불명확 쓰기는 재실행하지 않는다.'}


def _answered_message(td, home, source):
    """The clicked post or the last visible nonempty assistant before the selected row."""
    if td.get_session_env('HERMES_SESSION_PLATFORM', '') == 'hejo':
        from hermes_owner_chat import current_owner_message, answered_employee_message
        owner = current_owner_message(td.get_session_env)
        if not owner or source.get('message_id') != owner['msg_id'] or source.get('text') != owner['text'].strip():
            raise ValueError('WORK_SCOPE_TARGET_UNBOUND')
        post = answered_employee_message(td.get_session_env)
        if post is None:
            raise ValueError('WORK_SCOPE_TARGET_UNBOUND')
        return post['text']
    sid=current_session_id(td)
    if not sid or source.get('row_id') is None:return ''
    try:
        with sqlite3.connect((Path(home)/'state.db').as_uri()+'?mode=ro',uri=True) as db:
            row=db.execute("SELECT content FROM messages WHERE session_id=? AND role='user' AND id=?",(sid,source['row_id'])).fetchone()
            if not row:return ''
            raw=str(row[0] or '')
            # The learning parser remains the only interpreter of gateway wrappers.
            from hermes_team_services.learning import _quoted_body
            parsed=_quoted_body(raw)
            if parsed:raw=parsed[1]
            pressed='[Thread context — the message the owner just pressed a button on ('
            if raw.startswith(pressed):
                if '[End of thread context]' not in raw:return ''
                context=raw.split('[End of thread context]',1)[0]
                return context.split('[pressed message] ',1)[1] if '[pressed message] ' in context else ''
            columns={r[1] for r in db.execute('PRAGMA table_info(messages)')}
            visible=" AND COALESCE(display_kind,'')!='hidden'" if 'display_kind' in columns else ''
            prior=db.execute("SELECT content FROM messages WHERE session_id=? AND role='assistant' AND id<? "
                             "AND TRIM(COALESCE(content,''))!=''"+visible+" ORDER BY id DESC LIMIT 1",(sid,source['row_id'])).fetchone()
            return str(prior[0]) if prior else ''
    except (OSError,sqlite3.Error):
        return ''


def _target_message(td, home, item, *, source=None):
    """Target binding and bare-memo meaning use exactly the same answered post."""
    source=source if source is not None else td._current_owner_choice_source()
    post=_answered_message(td,home,source)
    try:
        common_id=str(item['common_id'])
        if common_id.strip() and re.search(r'(?<![\w])'+re.escape(common_id)+r'(?![\w])',post):
            return True
        title=str(item['title'])
        # A single Korean particle may follow the exact title, including a closing parenthesis.
        particle=r'(?:을|를|은|는|이|가|의|에|에서|로|으로|와|과|도|만|이나|나|부터|까지)?'
        return bool(title.strip() and re.search(r'(?<![\w])'+re.escape(title)+particle+r'(?![\w])',post))
    except (OSError, sqlite3.Error):
        return False


def _stage_names(target):
    return ('scope','notion','link','properties') if target=='shared' else ('unlink','scope','properties')


def _step_done(record, name):
    value=record['steps'].get(name)
    return name in record['steps'] and not (isinstance(value,dict) and value.get('verified') is False)


def _local_applied(native, cid, record, step):
    item=native.store.get(cid)
    refs=[r for r in item['knowledge_refs'] if r['ref_type']=='notion_page']
    if step=='scope':return item['scope']==record['target']
    if step=='unlink':return not refs
    if step=='link':
        page=record['steps'].get('notion',{}).get('id')
        return bool(page and any(r['external_id']==page for r in refs))
    if step=='properties':return native.properties_match(item)
    raise ValueError('invalid local transition step')


def _result(native, cid, record):
    status=record['status']
    return {'ok':status=='completed','status':status,'common_work':native.store.get(cid),
            'journal_key':'scope:'+cid,'steps':deepcopy(record['steps']),
            **({'execution_uncertain':True} if status=='uncertain' else {})}


def _finish(native, cid, record, status):
    record['status']=status
    result=_result(native,cid,record)
    event=record['events'].get(record.get('current_event'))
    if event is not None:
        event['status']=status
        event['result']=result
    return result


def _reconcile(native, cid, record, *, all_local=False):
    """Reads only: the ledger records proof, never guesses whether a native creation succeeded."""
    if record.get('pending',{}).get('step')=='notion':
        return _finish(native,cid,record,'uncertain')
    try:
        for name in _stage_names(record['target']):
            if name=='notion':continue
            if all_local or not _step_done(record,name) or record.get('pending',{}).get('step')==name:
                if _local_applied(native,cid,record,name):
                    record['steps'].setdefault(name,{'verified':True})
                    value=record['steps'][name]
                    if isinstance(value,dict) and value.get('verified') is False:value['verified']=True
                elif _step_done(record,name):
                    record['steps'][name]={'verified':False,'previous':deepcopy(record['steps'][name])}
        record.pop('pending',None)
        status='completed' if all(_step_done(record,s) for s in _stage_names(record['target'])) else 'partial'
    except Exception:
        status='uncertain'
    return _finish(native,cid,record,status)


def transition(td,args,*,native=None):
    if not td._task_capture_owner_chat():raise ValueError('WORK_SCOPE_OWNER_CHAT_REQUIRED')
    source=td._current_owner_choice_source()
    picked=authorized(td,choice_ref=args.get('choice_ref'),source=source)
    target=picked[0]
    if target is None:return {'ok':True,'applied':False,'mutation_calls':0}
    if args.get('scope') is not None and args['scope']!=target:raise ValueError('WORK_SCOPE_CHOICE_MISMATCH')
    native=native or Native(td)
    cid=str(args.get('common_id') or '')
    mid=str(source['message_id'] or '').strip()
    if not mid:raise ValueError('WORK_SCOPE_TARGET_UNBOUND')
    hejo = td.get_session_env('HERMES_SESSION_PLATFORM', '') == 'hejo'
    if hejo:
        from datetime import datetime
        from hermes_owner_chat import current_owner_message
        owner = current_owner_message(td.get_session_env)
        if not owner or owner['msg_id'] != mid:
            raise ValueError('WORK_SCOPE_TARGET_UNBOUND')
        try:
            stamp = datetime.fromisoformat(owner['ts'].replace('Z', '+00:00'))
            if stamp.tzinfo is None:raise ValueError('timezone required')
            event_at = stamp.timestamp()
        except (KeyError, TypeError, ValueError):raise ValueError('WORK_SCOPE_TARGET_UNBOUND')
    else:
        try:event_ts=Decimal(mid)
        except InvalidOperation:raise ValueError('WORK_SCOPE_TARGET_UNBOUND')
        if not event_ts.is_finite() or event_ts<=0:raise ValueError('WORK_SCOPE_TARGET_UNBOUND')
    with content.ledger(native.home,'work-scope-transitions') as (path,state):
        item=native.store.get(cid)
        if any(s.get('metadata',{}).get('owner_scope')=='personal' for s in item['sources']):
            raise ValueError('WORK_SCOPE_COMPANY_REQUIRED')
        if not _target_message(td,native.home,item,source=source):raise ValueError('WORK_SCOPE_TARGET_UNBOUND')
        key='scope:'+cid
        record=state['works'].get(key)
        if record and record['status']=='running':
            _reconcile(native,cid,record)
            content.save(path,state)
        if record:
            previous=record.get('events',{}).get(mid)
            if previous:
                if previous['target']!=target:raise ValueError('WORK_SCOPE_EVENT_CONFLICT')
                return {**previous.get('result',{'ok':False,'status':previous['status']}),'replayed':True}
            if hejo:
                if event_at <= record.get('last_hejo_event_at', float('-inf')):raise ValueError('WORK_SCOPE_EVENT_STALE')
            elif record.get('last_event_ts') and event_ts<=Decimal(record['last_event_ts']):
                raise ValueError('WORK_SCOPE_EVENT_STALE')
        legacy_uncertain=any(k!=key and not k.startswith('scope:') and v.get('common_id')==cid
                             and (v.get('pending') or v.get('status') in {'pending','uncertain'})
                             for k,v in state['works'].items())
        if legacy_uncertain or (record and (record['status']=='uncertain' or record.get('pending',{}).get('step')=='notion')):
            return {'ok':False,'status':'uncertain','execution_uncertain':True,'journal_key':key}
        if record and record.get('pending'):
            _reconcile(native,cid,record)
            content.save(path,state)
            if record['status']=='uncertain':return _result(native,cid,record)
        partial=record and record['status']=='partial'
        if partial and record['target']!=target:raise ValueError('WORK_SCOPE_TRANSITION_INCOMPLETE')
        if not partial and item['scope']==target:
            return {'ok':True,'unchanged':True,'common_work':item}
        if not partial:
            events=deepcopy(record['events']) if record else {}
            attempts=deepcopy(record.get('attempts',[])) if record else []
            if record:
                attempts.append({k:deepcopy(v) for k,v in record.items() if k not in {'events','attempts'}})
            watermarks={k:record[k] for k in ('last_event_ts','last_hejo_event_at') if record and k in record}
            record={'target':target,'status':'running','steps':{},'events':events,'attempts':attempts,'at':time.time(),**watermarks}
            state['works'][key]=record
        record.update(status='running',current_event=mid)
        if hejo:record['last_hejo_event_at']=event_at
        else:record['last_event_ts']=mid
        record['events'][mid]={'target':target,'status':'running'}
        content.save(path,state)
        def step(name,call):
            if _step_done(record,name):return record['steps'][name]
            prior=deepcopy(record['steps'].get(name))
            record['pending']={'step':name};content.save(path,state)
            result=call()
            record['steps'][name]=result if prior is None else {'verified':True,'receipt':result,'previous':prior}
            record.pop('pending');content.save(path,state)
            return result
        def publish():
            before=native.source(native.store.get(cid))['content']
            public={'title':before['title'],'tasks':[{k:t[k] for k in ('text','due','done') if k in t} for t in before['tasks']],'body':''}
            return native.notion(public,cid)
        def link():
            page=record['steps']['notion']
            if _local_applied(native,cid,record,'link'):return {'verified':True}
            return native.store.link_knowledge_ref(cid,ref_type='notion_page',external_id=page['id'],
                relation_type='documented_by',link_reason='verified_workflow_evidence',receipt_id='scope-transition:'+cid+':'+mid)
        def unlink():
            for ref in native.store.get(cid)['knowledge_refs']:
                if ref['ref_type']=='notion_page':native.store.unlink_knowledge_ref(cid,ref_id=ref['ref_id'],reason='owner_scope_private')
            return {'verified':True}
        try:
            calls={'scope':lambda:native.store.set_scope(cid,target),'notion':publish,'link':link,
                   'unlink':unlink,'properties':lambda:native.properties(native.store.get(cid))}
            for name in _stage_names(target):step(name,calls[name])
            result=_finish(native,cid,record,'completed');content.save(path,state)
            return result
        except Exception as exc:
            result=_reconcile(native,cid,record)
            result['error']=type(exc).__name__+': 원본 대조가 필요한 단계는 자동 재실행하지 않는다.'
            content.save(path,state)
            return result


def inspect_transitions(home):
    """Read-only rollback gate. Includes unsettled legacy token records."""
    path=Path(home)/'state/work-scope-transitions.json'
    if not path.exists():return {}
    state=json.loads(path.read_text())
    if state.get('version')!=1 or not isinstance(state.get('works'),dict):raise ValueError('sync_state_corrupt')
    return {key:deepcopy(row) for key,row in state['works'].items()
            if (key.startswith('scope:') and row.get('status') not in {'completed','not_applied'})
            or row.get('pending') or row.get('status') in {'running','partial','pending','uncertain'}}


def resolve_transition(native, common_id, outcome, *, by, evidence, page_id=None):
    """Operator only, never exported as an agent tool. Completion is derived from original stores."""
    if outcome not in {'notion_applied','not_applied','reconcile'}:raise ValueError('invalid transition resolution')
    if not str(by).strip() or not str(evidence).strip():raise ValueError('resolution evidence required')
    with content.ledger(native.home,'work-scope-transitions') as (path,state):
        record=state['works']['scope:'+common_id]
        if outcome=='notion_applied':
            if record['target']!='shared' or not str(page_id or '').strip():raise ValueError('notion page receipt required')
            record['steps']['notion']={'id':str(page_id).strip(),'operator_verified':True}
            record.pop('pending',None)
        elif outcome=='not_applied':
            item=native.store.get(common_id)
            original='private' if record['target']=='shared' else 'shared'
            if item['scope']!=original or any(r['ref_type']=='notion_page' for r in item['knowledge_refs']):
                raise ValueError('original scope and absent notion link must be verified first')
            record.pop('pending',None)
            result=_finish(native,common_id,record,'not_applied')
        elif record.get('pending',{}).get('step')=='notion' or (record['target']=='shared' and 'notion' not in record['steps']):
            raise ValueError('notion outcome must be resolved first')
        if outcome!='not_applied':result=_reconcile(native,common_id,record,all_local=True)
        record['resolution']={'by':by,'outcome':outcome,'evidence':evidence,'at':time.time()}
        content.save(path,state)
        return result
