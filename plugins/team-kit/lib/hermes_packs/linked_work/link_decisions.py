"""Owner-confirmed local relinks. Disabled until the operator enables a restarted gateway."""
from contextlib import contextmanager
from pathlib import Path
import asyncio
import fcntl
import hashlib
import re
import json
import logging
import os
import time

from hermes_packs.linked_work import slack_report
from hermes_packs.linked_work.link_candidates import Finder, Inventory, deleted
import importlib.util as _ilu, pathlib as _pl, sys as _sys
from hermes_facility import team_registry as team


def enabled(home):
    import hermes_yaml
    if not team.home_has_role(home, 'work'):
        return False
    try:
        cfg = hermes_yaml.safe_load((Path(home)/'config.yaml').read_text()) or {}
    except FileNotFoundError:
        return False
    return cfg.get('plugins',{}).get('entries',{}).get('team-delegation',{}).get('settings',{}).get('notion_completion_sync',{}).get('link_decisions') is True


@contextmanager
def locked(home):
    path = Path(home)/'state/link-decisions.json'
    path.parent.mkdir(parents=True,exist_ok=True)
    lock = path.with_suffix('.lock')
    if path.is_symlink() or lock.is_symlink():
        raise ValueError('decision_state_symlink')
    with lock.open('a') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        state = json.loads(path.read_text()) if path.exists() else {'decisions':{},'batches':{}}
        def save():
            tmp = path.with_name(path.name+'.tmp')
            if tmp.is_symlink():
                raise ValueError('decision_state_symlink')
            with tmp.open('w') as output:
                os.chmod(tmp,0o600)
                json.dump(state,output,ensure_ascii=False,indent=2)
                output.flush();os.fsync(output.fileno())
            os.replace(tmp,path)
        yield state,save


def decision_key(row):
    return hashlib.sha256('|'.join(row[k] for k in ['common_id','domain','source_id']).encode()).hexdigest()[:16]


# Owner decision 2026-10-31: '어떤 후보를 연결할까요?' with the candidates' numbers, then 거절 (do not link),
# 의견 (the owner types an instruction) and 확인 (hold). Earlier reports' words still answer.
TAIL = ['거절', '의견', '확인']
LEGEND = '숫자=그 후보 연결 · 거절=연결 안 함 · 의견=직접 적기 · 확인=보류'
LEGACY = re.compile(r'(\d+)번 연결')


def numbers(count):
    return [str(i + 1) for i in range(count)]


def choices(decision):
    return numbers(1 if decision.get('title_confirm') else len(decision['candidates'])) + TAIL


def legacy_choice(text):
    """Earlier buttons: 'N번 연결', '연결', '연결 안 함' -> the same answer in today's words."""
    if text == '연결 안 함':
        return '거절'
    if text == '연결':
        return '1'
    match = LEGACY.fullmatch(text)
    return match[1] if match else text


def item_text(d, *, failed=False):
    lines=[f'*🔴 {d["title"]} — 원본 연결 확인*',f'항목 `{d["id"]}` · {d["domain"]}']
    if d['candidates']:
        lines.append('어떤 후보를 연결할까요?')
    for i,c in enumerate(d['candidates'],1):
        x=c['identity']
        lines.append(f'{i}. {x["title"]} · {x.get("folder_name") or x.get("list_name") or x.get("calendar_id")} · {x.get("created_at") or x.get("start") or "생성 시각 확인 불가"}')
    if d.get('recently_deleted'):
        lines.append('최근 삭제된 항목에 있음 — 복원하거나 연결하지 않습니다.')
    if not d['candidates']:
        if d['domain']=='calendar' and not d.get('metadata',{}).get('identity'):
            lines.append('후보 없음. 저장된 일정 날짜가 없어 제목만으로 조회할 수 없습니다. 현재 연결 안 함으로 남겨둘 수 있습니다.')
        else:
            lines.append('후보 없음. 원본 제목을 답글로 적으면 찾아서 확인을 받습니다. 여러 업무가 있으면 항목 ID와 제목을 함께 적어 주세요.')
    if failed:
        lines.append('후보가 바뀌었거나 조회·연결에 실패했습니다. 원본을 확인한 뒤 다시 선택해 주세요.')
    lines.append('_'+LEGEND+'_')
    lines.append('[[버튼: '+' | '.join(choices(d) if d['candidates'] else TAIL)+']]')
    return '\n'.join(lines)


def batch_text(rows):
    """Several certain candidates at once: the same question, one number per work."""
    lines=['*🔴 연결된 업무 원본 확인*',f'연결이 끊긴 업무 {len(rows)}건에 확실한 후보가 있어요. 어떤 후보를 연결할까요?']
    for i,r in enumerate(rows,1):
        x=r['candidates'][0]['identity']
        lines.append(f'{i}. {r["title"]} → {x["title"]} · {x.get("folder_name") or x.get("list_name") or x.get("calendar_id")}')
    lines.append('_숫자=그 업무 연결 · 거절=모두 연결 안 함 · 의견=직접 적기(예: 다 연결해) · 확인=보류_')
    lines.append('[[버튼: '+' | '.join(numbers(len(rows))+TAIL)+']]')
    return '\n'.join(lines)


class Decisions:
    def __init__(self, home, store, inventory, *, send=None):
        self.home,self.store,self.inventory=Path(home),store,inventory
        self.finder=Finder(store,inventory)
        self.answer_state='done'
        self.claimed=False
        self.send=send or (lambda channel,text,**kw:slack_report.post_thread(self.home,channel,text,script='link_decisions',**kw))

    def preview(self):
        with self.store._connect() as conn:
            missing=[dict(r) for r in conn.execute("SELECT h.*,w.title,w.created_at FROM source_health h JOIN common_work w USING(common_id) WHERE h.status='missing' AND h.reason NOT IN ('relinked','agent_rebuilt') AND w.status='active'")]
        rows=[]
        for row in missing:
            row['metadata']=json.loads(row['metadata_json'])
            result=self.finder.find(row,row)
            rows.append({'id':decision_key(row),'common_id':row['common_id'],'domain':row['domain'],
                         'source_id':row['source_id'],'title':row['title'],'created_at':row['created_at'],
                         'metadata':row['metadata'],**result})
        return rows

    def request(self, *, dry_run=True, only_keys=None):
        if not dry_run and not enabled(self.home):
            return {'enabled':False,'sent':0,'rows':[]}
        rows=self.preview()
        if only_keys is not None:rows=[r for r in rows if r['id'] in only_keys]
        if dry_run:
            return {'enabled':enabled(self.home),'sent':0,'rows':rows}
        channel=slack_report.report_room(self.home)
        if not channel:
            raise ValueError('report_channel_required')
        with locked(self.home) as (state,save):
            fresh=[r for r in rows if r['status']=='ok' and r['id'] not in state['decisions']]
            if not fresh:
                return {'sent':0,'rows':rows}
            bid=hashlib.sha256('|'.join(r['id'] for r in fresh).encode()).hexdigest()[:16]
            certain=[r['id'] for r in fresh if r['certain']]
            batch={'id':bid,'channel':channel,'thread_ts':None,'decisions':[r['id'] for r in fresh],
                   'certain':certain,'label':f'확실한 {len(certain)}건 모두 연결','numbered':True}
            state['batches'][bid]=batch
            for r in fresh:
                state['decisions'][r['id']]={**r,'status':'waiting','channel':channel,'thread_ts':None,'message_ts':None,'batch':bid}
            save()  # Never blindly resend after an ambiguous Slack timeout.
            head=f'*🔴 연결된 업무 원본 확인*\n연결이 끊긴 업무 {len(fresh)}건의 원본을 확인해 주세요.'
            if len(certain)>=2:head=batch_text([r for r in fresh if r['certain']])
            thread=self.send(channel,head);batch['thread_ts']=thread;save()
            for r in fresh:
                d=state['decisions'][r['id']];d['thread_ts']=thread;save()
                d['message_ts']=self.send(channel,item_text(d),thread_ts=thread);save()
        return {'sent':len(fresh),'rows':rows}

    def notify(self, channel, text, **kwargs):
        # The durable decision must not fall through to an LLM on Slack failure.
        try:
            return self.send(channel, text, **kwargs)
        except Exception as exc:
            logging.getLogger(__name__).warning('decision_notification_failed:%s', type(exc).__name__)
            return None

    def decide(self, d, label, save):
        recovered = self.store.owner_relink_result(d['common_id'],d['id'])
        if recovered:
            d['status']='linked';d['new_source_id']=recovered['new_id'];save()
        if d['status'] in {'linked','declined'}:
            return f'{d["title"]}: 이미 {d["status"]} 처리됐습니다.'
        label=legacy_choice(label)
        if label=='확인':
            return f'{d["title"]}: 보류했어요. 연결하지 않고 그대로 둡니다.'
        if label=='거절':
            d['status']='declined';save()
        else:
            index=int(label)-1
            candidate=d['candidates'][index]
            self.notify(d['channel'],f'*🟡 {d["title"]}*\n원본을 다시 확인하고 있습니다.',message_ts=d['message_ts'])
            try:
                fresh=self.inventory.fresh(d['domain'],candidate['source_id'])
                if (fresh['owner_scope']!='company' or fresh['identity']!=candidate['identity'] or deleted(fresh['identity'])):
                    raise ValueError('candidate_changed')
                self.store.owner_relink(d['common_id'],d['domain'],d['source_id'],candidate['source_id'],fresh,d['id'])
                d['status']='linked';d['new_source_id']=candidate['source_id'];save()
            except Exception as exc:
                self.answer_state='failed'
                d['status']='failed';d['failure_type']=type(exc).__name__;save()
                self.notify(d['channel'],item_text(d,failed=True),message_ts=d['message_ts'])
                return f'{d["title"]}: 연결하지 못했습니다. 항목의 확인 버튼을 다시 선택해 주세요.'
        self.notify(d['channel'],f'*🟢 {d["title"]}*\n'+('새 원본을 연결했습니다.' if d['status']=='linked' else '연결하지 않기로 했습니다.'),message_ts=d['message_ts'])
        return f'{d["title"]}: '+('연결 완료' if d['status']=='linked' else '연결 안 함')

    def handle(self, channel, thread, text, button=None):
        with locked(self.home) as (state,save):
            batches=[b for b in state['batches'].values() if b['channel']==channel and b['thread_ts']==thread]
            if len(batches)!=1:return None
            batch=batches[0]
            ds=[state['decisions'][key] for key in batch['decisions']]
            if text=='의견':
                # 의견: the owner writes the instruction next; nothing runs and nothing is posted.
                self.claimed=True
                return ''
            if button:
                if button.get('label')!=text:return None
                if button.get('message_ts')==thread:
                    if batch.get('numbered'):
                        self.claimed=True
                        if text=='확인':
                            self.answer_state='waiting'
                            return '보류했어요. 연결하지 않고 그대로 둡니다.'
                        if batch.get('bulk_disabled'):return '후보가 바뀌었습니다. 각 항목의 확인 버튼을 선택해 주세요.'
                        if text=='거절':
                            return '\n'.join(self.decide(state['decisions'][key],'거절',save) for key in batch['certain'])
                        if text.isdigit() and 1<=int(text)<=len(batch['certain']):
                            return self.decide(state['decisions'][batch['certain'][int(text)-1]],'1',save)
                        return None
                    if text=='하나씩 볼게':
                        self.claimed=True
                        self.answer_state='waiting'
                        return '각 항목의 번호 버튼으로 선택해 주세요.'
                    if text!=batch['label'] or len(batch['certain'])<2:return None
                    self.claimed=True
                    if batch.get('bulk_disabled'):return '후보가 바뀌었습니다. 각 항목의 확인 버튼을 선택해 주세요.'
                    replies=[self.decide(state['decisions'][key],'1번 연결',save) for key in batch['certain']]
                    return '\n'.join(replies)
                matches=[d for d in ds if d['message_ts']==button.get('message_ts') and legacy_choice(text) in choices(d)]
                if len(matches)!=1:return None
                self.claimed=True
                if legacy_choice(text)=='확인':self.answer_state='waiting'
                return self.decide(matches[0],text,save)
            self.claimed=True
            self.answer_state='waiting'
            if batch.get('numbered') and len(batch['certain'])>=2 and not batch.get('bulk_disabled'):
                # Typed after 의견: '다 연결해' or the numbers, for the certain works listed in the question.
                if re.search(r'(?:모두|전부|다)\s*연결',text):
                    self.answer_state='done'
                    return '\n'.join(self.decide(state['decisions'][key],'1',save) for key in batch['certain'])
                picked=re.fullmatch(r'\s*(\d+(?:\s*[,\s]\s*\d+)*)\s*(?:번)?\s*(?:연결(?:해|해줘)?)?\s*',text)
                if picked and len([d for d in ds if d['status'] in {'waiting','failed'}])!=1:
                    keys=[batch['certain'][int(n)-1] for n in re.findall(r'\d+',picked[1]) if 1<=int(n)<=len(batch['certain'])]
                    if keys:
                        self.answer_state='done'
                        return '\n'.join(self.decide(state['decisions'][key],'1',save) for key in dict.fromkeys(keys))
            active=[d for d in ds if d['status'] in {'waiting','failed'}]
            parts=text.split(maxsplit=1)
            selected=[d for d in active if parts and parts[0]==d['id']]
            if selected and len(parts)==2:
                d=selected[0];text=parts[1]
            elif len(active)==1:d=active[0]
            else:return '항목 ID와 원본 제목을 함께 적어 주세요. 연결은 확인 버튼을 누른 뒤에만 합니다.'
            if legacy_choice(text) in choices(d) and text!='의견':
                self.answer_state='done' if legacy_choice(text)!='확인' else 'waiting'
                return self.decide(d,text,save)
            result=self.finder.find(d,d,exact_title=text)
            if result['status']!='ok':return '원본 조회가 실패했습니다. 연결하지 않았습니다.'
            if result['total_candidates']!=1:return '회사 범위에서 제목이 정확히 일치하는 미연결 원본을 하나로 확인하지 못했습니다.'
            d.update(candidates=result['candidates'],title_confirm=True,status='waiting',certain=False)
            # A text-discovered candidate is never part of the original bulk approval.
            batch['bulk_disabled']=True
            save()
            d['message_ts']=self.send(channel,item_text(d),thread_ts=thread);save()
            return '원본 후보를 찾았습니다. 새 확인 버튼을 선택해 주세요.'


async def dispatch(home, event=None, **_):
    if not enabled(home):return None
    if not (Path(home)/'state/link-decisions.json').is_file():return None
    source=getattr(event,'source',None)
    if getattr(getattr(source,'platform',None),'value','')!='slack':return None
    if getattr(source,'user_id','')!=slack_report._sender().owner(home):return None
    from hermes_packs.linked_work.common_work_links import CommonWorkStore
    from hermes_constants import get_hermes_home
    if Path(get_hermes_home()).resolve()!=Path(home).resolve():return None
    def process():
        app=Decisions(home,CommonWorkStore.production(Path.home()/'.hermes/shared/common-work-links.sqlite3'),Inventory(home))
        channel,thread=getattr(source,'chat_id',''),getattr(source,'thread_id','')
        try:
            result=app.handle(channel,thread,str(getattr(event,'text','') or '').strip(),
                              (getattr(event,'raw_message',None) or {}).get('_hermes_button'))
        except Exception as exc:
            if not app.claimed:
                raise
            logging.getLogger(__name__).warning('decision_dispatch_failed:%s',type(exc).__name__)
            app.answer_state='failed'
            result='처리가 중단됐습니다. 해당 항목의 확인 버튼을 다시 선택해 주세요.'
        if result is None:return None
        if result=='':return {'action':'skip','reason':'owner will write the instruction (의견)'}
        color={'done':'🟢','waiting':'🟡','failed':'🔴'}[app.answer_state]
        app.notify(channel,f'*{color} 연결 결정 처리*\n'+result,thread_ts=thread)
        return {'action':'skip','reason':'owner link decision handled by plugin'}
    return await asyncio.to_thread(process)
