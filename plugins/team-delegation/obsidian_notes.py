"""Obsidian implementation behind the existing memo tool/approval contracts.

Tiny office routes here; assistant retains Apple Notes. Background callers must already have
passed their existing company-scope guard and may use only the linked-work operations.
"""
from pathlib import Path
from urllib.parse import quote, unquote, urlparse
from html import escape
import json
import re
import shutil
import uuid
try:
    from . import obsidian_store as disk, obsidian_format as fmt
except ImportError:
    import obsidian_store as disk
    import obsidian_format as fmt

NOTICE = ('업무비서의 모든 메모(ㅁ·Inbox·메일 반영·업무·예약)는 Obsidian pie1이다. '
          '개인비서의 개인 메모는 Apple 메모를 유지한다. 기존 apple_notes_direct_*와 notes_read 도구 이름은 호환용이며 '
          '업무비서에서는 Obsidian을 읽고 쓴다. 업무 원본은 연결된 Notion 우선, Notion이 없을 때만 Obsidian이다. '
          'Notion 읽기 실패는 없음이 아니며 하위 원본으로 덮어쓰지 않는다. 본문 자동 동기화 금지와 기존 승인 경계는 유지한다. '
          '메모 속성은 created·modified·common_id·notion을 사용하고 본문에 제목을 중복 작성하지 않는다. '
          'Apple 메모로 우회하거나 terminal로 승인 경계를 우회하지 않는다. ')


def selected(td):
    context=getattr(td,'_PLUGIN_CONTEXT',None)
    cfg=context.get_config('obsidian_notes',{}) if context else {}
    return cfg.get('enabled') is True and td.personal_roles.profile(td)=='work-assistant'

def handles(identifier):return disk.is_id(identifier)


def snapshot(td,identifier):
    row=disk.Store().read(identifier)
    parsed=td._NoteHTML();parsed.feed(row['body_html']);parsed.close()
    row['edit_markup']=parsed.text()
    return row


def rollback_snapshot(td,identifier):
    row=snapshot(td,identifier)
    return {'note_id':identifier,'title':row['title'],'body_html':json.dumps({'backend':'obsidian','id':identifier,'path':row['path'],'text':row['full_text']},ensure_ascii=False)}


def identity(identifier):
    data=disk.Store().metadata(identifier)
    return {'owner_scope':'company','identity':data['original']}


def lookup(td,args):
    store=disk.Store();limit=min(20,max(1,int(args.get('limit') or 10)));query=str(args.get('query') or '').casefold()
    folder=str(args.get('folder') or '')
    if folder:folder=store.folder(folder)
    rows=[]
    for raw in store.all():
        if folder and not (raw['folder']==folder or raw['folder'].startswith(folder+'/')):continue
        haystack=raw['title']+('\n'+raw['plaintext'] if args.get('search_body') else '')
        if query not in haystack.casefold():continue
        row={'stableNoteIdentifier':raw['note_id'],'note_id':raw['note_id'],'title':raw['title'],
             'folder':raw['folder'],'url':raw['url'],'path':raw['path'],'backend':'obsidian'}
        if args.get('include_body'):
            row.update(body=snapshot(td,raw['note_id'])['edit_markup'],bodyAvailable=True,body_format='markdown',
                       summary_readable=True,body_representation='edit_markup',table_count=raw['body_html'].count('<table'),
                       attachments=raw['attachment_paths'])
        rows.append(row)
        if len(rows)>=limit:break
    td._attach_common_work_links(rows,domain='notes',source_id_field='stableNoteIdentifier')
    value=json.loads(td._direct_receipt('apple_notes_lookup','Obsidian pie1',rows))
    value.update(stable_note_identifier_available=True,common_id_link_allowed=True)
    return json.dumps(value,ensure_ascii=False)


def read_tool(args):
    store=disk.Store();rows=[store.read(args['note_id'])] if args.get('note_id') else store.all()
    folder=str(args.get('folder') or '');folder=store.folder(folder) if folder else ''
    query=str(args.get('query') or '').casefold()
    rows=[r for r in rows if (not folder or r['folder']==folder or r['folder'].startswith(folder+'/'))
          and query in (r['title']+('\n'+r['plaintext'] if args.get('search_body') else '')).casefold()]
    if args.get('summary'):
        from collections import Counter
        counts=Counter(r['folder'] for r in rows)
        return {'ok':True,'folders':[{'folder':k,'count':v} for k,v in sorted(counts.items())],'total':len(rows),'authority':'Obsidian pie1'}
    offset=int(args.get('offset') or 0);limit=min(20,max(1,int(args.get('limit') or 10)));items=[]
    for r in rows[offset:offset+limit]:
        item={'stableNoteIdentifier':r['note_id'],'note_id':r['note_id'],'title':r['title'],'folder':r['folder'],'url':r['url'],'backend':'obsidian'}
        if args.get('include_body') or args.get('note_id'):item.update(body=r['markdown'][:15000],body_length=len(r['markdown']),body_truncated=len(r['markdown'])>15000,bodyAvailable=True,body_format='markdown',attachments=r['attachment_paths'])
        if args.get('save_images'):item['images']=[{'path':p,'bytes':Path(p).stat().st_size} for p in r['attachment_paths'] if Path(p).suffix.lower() in {'.png','.jpg','.jpeg','.gif','.webp','.heic'}]
        items.append(item)
    more=offset+len(items)<len(rows)
    return {'ok':True,'items':items,'count':len(items),'limit_reached':more,'next_offset':offset+len(items) if more else None,'authority':'Obsidian pie1'}


def scope(td,args,owner):
    if owner!='company':raise ValueError('Obsidian pie1은 업무비서 회사 메모 범위다.')
    store=disk.Store();sid=args.get('note_id')
    if sid and not handles(sid):raise ValueError('OBSIDIAN_REQUIRED: 업무비서는 Apple 메모를 수정하지 않는다.')
    if sid:store.read(sid)
    args=dict(args)
    if args.get('folder'):args['folder']=store.folder(args['folder'])
    elif args.get('action')=='create':args['folder']=store.folder(td._notes_create_folder(''))
    return args


def local_links(body,root,source_parent):
    # Preserve all body-local links when re-rendering a summary/source.
    def sub(m):
        target=m[2]
        if urlparse(target).scheme:return m[0]
        p=(source_parent/unquote(target)).resolve()
        if not p.is_relative_to(root):raise ValueError('OBSIDIAN_ATTACHMENT_OUTSIDE_VAULT')
        return m[0]
    return re.sub(r'(!?\[[^\]\n]*\]\()([^)]+)\)',sub,body)


def sync_properties(td,row,common=None):
    cid=(common or {}).get('common_id') or row['properties'].get('common_id')
    if not cid:return row
    props={'common_id':cid,'notion':None}
    item=td._common_work_store().get(cid)
    urls=[]
    for ref in item.get('knowledge_refs',[]):
        if ref['ref_type']=='notion_page':urls.append(ref.get('metadata',{}).get('url') or 'https://www.notion.so/'+ref['external_id'].replace('-',''))
    if urls:props['notion']=urls[0] if len(urls)==1 else urls
    if all(row['properties'].get(k)==v for k,v in props.items()):return row
    return disk.Store().write(row['note_id'],row['markdown'],before=row,properties=props)


def mutate(td,args,context):
    action=str(args.get('action') or '').lower();store=disk.Store();sid=str(args.get('note_id') or '')
    if action=='pending_choices':return json.dumps({'ok':True,'choices':[],'authority':'Obsidian pie1'})
    if action not in {'create','update','move','delete','restore'}:raise ValueError('OBSIDIAN_ACTION_INVALID')
    if action!='create' and not handles(sid):raise ValueError('OBSIDIAN_NOTE_ID_REQUIRED')
    if not args.get('approved') and not td._owner_chat_no_approval('apple_notes_direct_mutation',action,args):
        return td._mutation_preview('Obsidian pie1',action,{k:args[k] for k in ('title','note_id','folder','summary') if k in args})
    before=store.read(sid) if sid else None
    context['_obsidian_write_attempted']=True
    if context.get('_linked_title_authority') is td._LINKED_TITLE_AUTHORITY:
        expected=context.get('_linked_title_before') or {}
        if before is None or before['revision']!=expected.get('revision'):raise ValueError('OBSIDIAN_CONCURRENT_CHANGE')
    if action=='restore':
        if not args.get('_skip_common_work'):raise ValueError('OBSIDIAN_RESTORE_INTERNAL_ONLY')
        row=store.restore(sid,args['body_html'])
    elif action=='delete':
        result=store.delete(sid,before)
        if not args.get('_skip_common_work'):td._unlink_owner_deleted_source('notes',sid)
        return json.dumps({'ok':True,'authority':'Obsidian pie1','action':action,'target_id':sid,'result':result,'approved':True,'mutation_calls':1,'fallback_used':False,'tool_search_calls':0},ensure_ascii=False)
    elif action=='move':
        if not args.get('folder'):raise ValueError('OBSIDIAN_FOLDER_REQUIRED')
        row=store.write(sid,before['markdown'],before=before,folder=args['folder'])
    else:
        title=str(args.get('title') or '').strip();summary=str(args.get('summary') or '').strip();preview=str(args.get('preview_summary') or '').strip();original=str(args.get('original_text') or '')
        if not title or not summary or not preview or '\n' in preview or len(preview)>140:raise ValueError('OBSIDIAN_SUMMARY_REQUIRED')
        if problem:=td.notes_format.validate_summary(summary):raise ValueError(problem)
        if action=='create' and not original.strip():raise ValueError('OBSIDIAN_ORIGINAL_REQUIRED')
        assets=list(before['attachment_paths']) if before else []
        if before:
            if not args.get('rename_title'):title=before['title']
            try:old_original=td._linked_note_sections(before['body_html'])[2]
            except ValueError:old_original=before['markdown']
            if not original.strip():original=old_original
            elif td._squash(old_original) not in td._squash(original):original=old_original+'\n\n['+disk.stamp()+' 추가]\n'+original
        sid=sid or 'obsidian:'+uuid.uuid4().hex
        folder=store.folder(args.get('folder') or (before['folder'] if before else td._notes_create_folder('')))
        # Resolve and copy before the document write. Preserve original asset bytes and names.
        supplied=args.get('attachments') or []
        if not isinstance(supplied,list) or len(supplied)>10:raise ValueError('OBSIDIAN_ATTACHMENTS_INVALID')
        for value in supplied:
            p=Path(value).expanduser()
            if not p.is_absolute() or not p.is_file():raise ValueError('OBSIDIAN_ATTACHMENT_UNAVAILABLE')
        removal=args.get('remove_existing')
        if removal:
            assets=[p for p in assets if not (removal=='all' or (removal=='images')==td._is_note_image(p))]
        destdir=store.path('attachments/'+sid.split(':')[1],system=True)
        if supplied:destdir.mkdir(parents=True,exist_ok=True)
        if destdir.is_symlink() or not destdir.resolve().is_relative_to(store.root):raise ValueError('OBSIDIAN_SYMLINK_REFUSED')
        for value in supplied:
            src=Path(value)
            with disk.materialize():raw=src.read_bytes()
            name=src.stem[:100]+'-'+disk.digest(raw)[:12]+src.suffix
            target=store.path(str((destdir/name).relative_to(store.root)),system=True)
            if target.exists():
                if target.read_bytes()!=raw:raise ValueError('OBSIDIAN_ATTACHMENT_COLLISION')
            else:
                with target.open('xb') as f:f.write(raw)
            if str(target) not in assets:assets.append(str(target))
        progress=str(args.get('progress') or (td._note_progress(before['body_html']) if before else '') or ('진행중' if folder.startswith('02. Task Notes') else ''))
        html=td._notes_html(title,td._structured_note_body(summary,original,preview),[],
                            created_at=str((before or {}).get('properties',{}).get('created') or disk.stamp()),
                            attachment_analysis=str(args.get('attachment_analysis') or ''),layout=td._notes_layout(folder),progress=progress)
        body=fmt.convert(html)
        # Preserve the source section byte-for-byte, including tables, images, and local links.
        # New mail/source text is appended; summary changes never reformat the old source.
        if before and not removal:
            old_source=source_tail(before['markdown'])
            new_source=source_tail(body)
            if old_source and new_source:
                extra=str(args.get('original_text') or '').strip()
                appendix=('\n\n['+disk.stamp()+' 추가]\n\n'+escape(extra)+'\n') if extra and td._squash(extra) not in td._squash(old_original) else ''
                breakpoint=re.search(r'(?m)^## [^\n]*(첨부 분석|원문 첨부파일)',old_source)
                if breakpoint:old_source=old_source[:breakpoint.start()]+appendix+old_source[breakpoint.start():]
                else:old_source+=appendix
                body=body[:-len(new_source)]+old_source
            elif new_source:
                body=body[:-len(new_source)]+'## 원문\n\n'+before['markdown']+'\n'
                if args.get('original_text'):body+='\n'+escape(str(args['original_text']))+'\n'
        existing=disk.Store().snapshot(sid,store.root/(before['folder'] if before else folder)/(title+'.md'),body)['attachment_paths']
        assets=[a for a in assets if a not in existing]
        if assets:
            body+='\n## 원문 첨부파일\n\n'
            parent=store.root/(before['folder'] if before else folder)
            import os
            for path in assets:
                p=Path(path);rel=quote(os.path.relpath(p,parent),safe='/');label=p.name.replace('[','\\[').replace(']','\\]')
                body+=('![' if td._is_note_image(path) else '[')+label+']('+rel+')\n\n'
        row=store.write(sid,body,before=before,title=title,folder=folder)
    common=None
    if not args.get('_skip_common_work'):
        common=td._register_approved_common_work_source(domain='notes',source_id=sid,title=row['title'],common_id=str(args.get('common_id') or ''))
        row=sync_properties(td,row,common)
    td._clear_pending_personal_owner()
    result={'note_id':sid,'title':row['title'],'url':row['url'],'path':row['path'],'attachments':len(row['attachment_paths']),'content_loss':False}
    return json.dumps({'ok':True,'authority':'Obsidian pie1','action':action,'target_id':sid,'result':result,
                       'approved':True,'mutation_calls':1,'fallback_used':False,'tool_search_calls':0,
                       **({'common_work':common} if common is not None else {})},ensure_ascii=False)


def rename(td,sid,title,before):
    row=disk.Store().write(sid,before['markdown'],before=before,title=title)
    return {'ok':True,'before':before,'after':row,'note_id':sid}


def progress(td,sid,value):
    if value not in {'진행중','완료'}:raise ValueError('OBSIDIAN_PROGRESS_INVALID')
    store=disk.Store();before=store.read(sid);body=before['markdown']
    if td._note_progress(before['body_html']):
        body=re.sub(r'(진행도:\s*)(진행중|완료)',lambda m:m[1]+value,body,count=1)
    else:body='진행도: '+value+'\n\n'+body
    if body==before['markdown']:return {'ok':True,'changed':False,'note_id':sid}
    row=store.write(sid,body,before=before)
    return {'ok':True,'changed':True,'note_id':sid,'after':row}


def edit(td,sid,before,lines,edits):
    current=disk.Store().read(sid)
    if current['revision']!=before.get('revision'):raise ValueError('OBSIDIAN_CONCURRENT_CHANGE')
    html,applied=td._note_apply_edits(before['body_html'],edits)
    wanted=[x for x in lines if x not in before['plaintext'].splitlines()]
    if not applied and not wanted:return {'ok':True,'changed':False,'applied':[]}
    body=fmt.convert(html) if applied else before['markdown']
    # HTML rendering already refers to the same local assets; preserve their embeds/links.
    body+='\n'+ '\n'.join(escape(x) for x in wanted)
    row=disk.Store().write(sid,body,before=before)
    return {'ok':True,'changed':True,'applied':applied,'after':row}


def move_completed(sid):
    store=disk.Store();before=store.read(sid)
    if before['folder']=='02. Task Notes/Complete':return True
    store.write(sid,before['markdown'],before=before,folder='02. Task Notes/Complete');return True


def source_tail(body):
    match=re.search(r'(?m)^## [^\n]*원문[^\n]*\n',body)
    return body[match.start():] if match else ''


def markdown_tasks(row):
    """Only explicit Markdown checkboxes outside quoted source/code are active tasks."""
    import work_content as content
    body=row['markdown'];tail=source_tail(body)
    prefix=body[:-len(tail)] if tail else body
    lines=prefix.splitlines(keepends=True);positions=[];tasks=[];fence=None
    for i,line in enumerate(lines):
        if re.match(r'^\s*(```|~~~)',line):
            token=line.lstrip()[:3];fence=None if fence==token else token;continue
        if fence:continue
        m=re.match(r'^\s*[-*] \[([ xX])\] (.*)',line)
        if m:
            positions.append(i);tasks.append(content.task(disk.plain(m[2]),done=m[1].lower()=='x'))
    rest=''.join(line for i,line in enumerate(lines) if i not in positions)+tail
    rest=re.sub(r'진행도:\s*(진행중|완료)','',rest)
    return {'title':row['title'],'body':rest.strip(),'tasks':tasks},lines,positions,tail


def apply_markdown_tasks(identifier,before,wanted,*,write=False):
    import work_content as content
    row=before['raw'];own,lines,positions,tail=markdown_tasks(row)
    if own['body']!=wanted['body']:raise ValueError('OBSIDIAN_BODY_SYNC_REFUSED')
    if any('\n' in t['text'] for t in wanted['tasks']):raise ValueError('OBSIDIAN_MULTILINE_TASK_REFUSED')
    rendered=[]
    for t in wanted['tasks']:
        text=escape(t['text'])+(' | '+t['due'] if t.get('due') else '')
        rendered.append('- ['+('x' if t['done'] else ' ')+'] '+text+'\n')
    for n,i in enumerate(positions):
        if n<len(rendered):
            if n<len(own['tasks']) and content.semantic({'tasks':[own['tasks'][n]]})==content.semantic({'tasks':[wanted['tasks'][n]]}):continue
            lines[i]=rendered[n]
        else:lines[i]=''
    body=''.join(lines)
    if len(rendered)>len(positions):body+=('' if body.endswith('\n') else '\n')+''.join(rendered[len(positions):])
    body+=tail
    if not write:return
    return disk.Store().write(identifier,body,before=row,title=wanted['title'])


def legacy_company_status(identifier):
    """Historical company Apple IDs are never read back as active memo sources."""
    if handles(identifier) or not disk.enabled():return None
    import sqlite3
    db=Path.home()/'.hermes/shared/common-work-links.sqlite3'
    with sqlite3.connect(db.as_uri()+'?mode=ro',uri=True) as conn:
        rows=conn.execute("SELECT metadata_json FROM source_links WHERE domain='notes' AND source_id=?",(identifier,)).fetchall()
    for (raw,) in rows:
        meta=json.loads(raw)
        if meta.get('owner_scope')=='company':
            return 'missing' if meta.get('identity',{}).get('folder_name')=='Recently Deleted' else 'unsupported'
    return None


def linked_receipt(td,item):
    try:
        for source in item.get('sources',[]):
            if source['domain']=='notes' and handles(source['source_id']):
                sync_properties(td,disk.Store().read(source['source_id']),item)
    except Exception as exc:
        return json.dumps({'ok':False,'item':item,'registry_changed':True,
                           'error':'연결 변경 완료; Obsidian 속성 반영 확인 필요: '+str(exc)},ensure_ascii=False)
    return json.dumps({'ok':True,'item':item},ensure_ascii=False)
