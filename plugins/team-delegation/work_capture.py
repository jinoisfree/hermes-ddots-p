"""Owner-selected company work creation. Durable steps never replay an uncertain native write."""
from pathlib import Path
import importlib.util
import json
import re
import time
import uuid

import deadline_time as dates
import work_content as content

MARKER='[[버튼: 메모 | 메모+노션 | 확인]]'
LEGEND='메모 = 개인(Obsidian 메모→미리알림), 메모+노션 = 공용(노션+Obsidian 메모→미리알림), 확인 = 만들지 않음'


def selection(text):
    text=str(text or '').strip()
    text=text.replace('메모+노션','lv2').replace('메모 작성','lv1')
    if re.fullmatch(r'(?:선택:\s*)?(?:건너뛰기|확인)',text):return (None,False)
    private=bool(re.search(r'\blv1\b|비공개|개인(?:으로)?|\bprivate\b',text,re.I))
    shared=bool(re.search(r'\blv2\b|공용|공유|\bshared\b',text,re.I))
    if private and shared:raise ValueError('WORK_SCOPE_CHOICE_AMBIGUOUS')
    calendar='일정' in text
    if private or shared:return ('private' if private else 'shared',calendar)
    if calendar and re.fullmatch(r'(?:선택:\s*)?일정(?:만)?(?:\s*확인)?',text):return (None,True)
    return None


def authorized(td, expected=None):
    if not td._task_capture_owner_chat():raise ValueError('WORK_CAPTURE_OWNER_CHAT_REQUIRED')
    if problem:=td._personal_role_problem('personal_work_bundle',{}):raise ValueError(problem)
    text=td._notes_current_owner_text()
    # Reuse explicit click values and current inbound legend context from the A/B guard.
    from hermes_constants import get_hermes_home
    path=Path(__file__).resolve().parent.parent/'team-kit'/'task_capture.py'
    spec=importlib.util.spec_from_file_location('_mail_task_capture',path)
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    text=helper.mail_choice(text, mail=helper.mail_thread(get_hermes_home(), td.get_session_env('HERMES_SESSION_ID','')))
    picked=selection(text)
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
                 'folder':'02. Task Notes','attachments':args.get('attachments') or [],
                 'approved':True,'_skip_common_work':True}
        row=json.loads(self.td._apple_notes_direct_mutation(payload))
        if not row.get('ok'):raise RuntimeError('work_note_creation_unverified')
        return {'id':row['target_id'],'receipt':row}

    def notion(self,args,cid):
        self.store.require_notion(cid)
        from notion_completion_sync import DATABASE
        spec=importlib.util.spec_from_file_location('_work_capture_notion',self.home/'plugins/team-kit/notion.py')
        n=importlib.util.module_from_spec(spec);spec.loader.exec_module(n)
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

    def reminders(self,cid):
        import task_reminders_sync
        return task_reminders_sync.sync(self.home,{'common_id':cid})

    def mail(self,cid,source):
        import mail_work
        return mail_work.link(self.store,{**{k:source[k] for k in ('thread_id','message_id','rfc_id','account','subject') if k in source},'common_id':cid})

    def ack(self,source):
        if not source.get('message_id'):return {'ok':True,'skipped':True}
        result=json.loads(self.td._gmail_direct({'action':'ack','ids':[source['message_id']]}))
        if not result.get('ok'):raise RuntimeError('work_mail_ack_unverified')
        return result

    def properties(self,item):
        import obsidian_notes
        for source in item['sources']:
            if source['domain']=='notes':
                obsidian_notes.sync_properties(self.td,obsidian_notes.disk.Store().read(source['source_id']),item)

    def source(self,item):
        from work_sources import Sources
        sources=Sources(self.home)
        authority=sources.authority(item,sources.references(item))
        if not authority:raise ValueError('scope_transition_source_required')
        return sources.read(*authority)


def create(td,args,*,native=None):
    picked=authorized(td)
    scope,calendar=picked
    source=args.get('source') or {}
    native=native or Native(td)
    if scope is None and not calendar:
        return {'ok':True,'skipped':True,'ack':native.ack(source),'mutation_calls':0}
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
                    common_id=cid,link_reason='approved_mutation',scope=scope or 'private',reminder_policy='tasks' if scope else 'none')
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
                result=step('reminders',lambda:native.reminders(cid))
                if not result.get('ok'):raise RuntimeError('work_reminders_partial_check_journal')
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


def transition(td,args,*,native=None):
    if not td._task_capture_owner_chat():raise ValueError('WORK_SCOPE_OWNER_CHAT_REQUIRED')
    if problem:=td._personal_role_problem('personal_work_bundle',{}):raise ValueError(problem)
    native=native or Native(td)
    cid,target=args.get('common_id'),args.get('scope')
    if target not in {'private','shared'}:raise ValueError('invalid work scope')
    item=native.store.get(cid)
    if item['scope']==target:return {'ok':True,'unchanged':True,'common_work':item}
    if any(s.get('metadata',{}).get('owner_scope')=='personal' for s in item['sources']):
        raise ValueError('WORK_SCOPE_COMPANY_REQUIRED')
    context=[td.get_session_env(k,'') for k in ('HERMES_SESSION_USER_ID','HERMES_SESSION_CHAT_ID','HERMES_SESSION_THREAD_ID')]
    before=native.source(item) if target=='shared' else None
    # A private note's prose and attachments never enter the preview or the published payload.
    public={'title':before['content']['title'],'tasks':before['content']['tasks'],'body':''} if before else None
    signature=content.digest([item,before and before['revision']])
    with content.ledger(native.home,'work-scope-transitions') as (path,state):
        token=str(args.get('token') or '')
        command=('공용' if target=='shared' else '개인')+' 전환 '
        if not token:
            token=uuid.uuid4().hex[:10]
            state['works'][token]={'common_id':cid,'scope':target,'context':context,'signature':signature,
                                   'public':public,'at':time.time(),'status':'offered'}
            content.save(path,state)
            text=('*🔴 공용 업무 전환 확인*\n\n노션에 올라갈 내용(메모 본문·첨부 제외):\n'+
                  content.render(public) if public else
                  '*🔴 개인 업무 전환 확인*\n\n이미 노션에 공개된 내용은 되돌릴 수 없어요. 연결만 끊고 페이지는 삭제하지 않아요.')
            text+='\n[[버튼: '+command+token+' | 취소]]'
            return {'ok':True,'approval_required':True,'token':token,'message':text}
        offer=state['works'].get(token)
        if (not offer or offer['context']!=context or offer['common_id']!=cid or offer['scope']!=target
                or offer['signature']!=signature or time.time()-offer['at']>1800):
            raise ValueError('WORK_SCOPE_APPROVAL_EXPIRED_OR_CHANGED')
        if offer['status']!='offered':return {'ok':False,'status':offer['status'],'error':'이 전환은 이미 처리했거나 결과 확인 중이다. 재실행하지 않는다.'}
        if td._notes_current_owner_text().strip()!=command+token:raise ValueError('WORK_SCOPE_BUTTON_APPROVAL_REQUIRED')
        offer['status']='pending';content.save(path,state)
        try:
            item=native.store.set_scope(cid,target)
            if target=='shared':
                page=native.notion(offer['public'],cid)
                offer['page']=page;content.save(path,state)
                item=native.store.link_knowledge_ref(cid,ref_type='notion_page',external_id=page['id'],relation_type='documented_by',link_reason='verified_workflow_evidence',receipt_id='scope-transition:'+token)
            native.properties(item)
            offer['status']='completed';content.save(path,state)
            return {'ok':True,'common_work':item,'transition_token':token}
        except Exception:
            offer['status']='uncertain';content.save(path,state)
            return {'ok':False,'status':'uncertain','execution_uncertain':True,'transition_token':token,
                    'error':'등급·노션·속성 반영을 대조해야 한다. 자동 재실행하지 않는다.'}
