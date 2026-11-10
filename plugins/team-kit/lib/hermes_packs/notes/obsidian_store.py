"""Company memo storage. No Apple Events, no network, no writes outside the configured vault.

Stable identities live in a hidden HTML comment (not Obsidian properties). The local index
is only a cache: renames are resolved by that identity, never by a similar title or body.
"""
from __future__ import annotations
from contextlib import contextmanager
from datetime import datetime
from html import escape, unescape
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import quote, unquote, urlparse
from zoneinfo import ZoneInfo
import ctypes
import fcntl
import hashlib
import json
import os
import re
import tempfile
import uuid
from hermes_facility import team_registry as team, owner_vault as vault

CONFIG = team.home_of_role('work', Path.home()/'.hermes')/'config.yaml'
STATE = team.home_of_role('work', Path.home()/'.hermes')/'state/obsidian-notes'
MARK = re.compile(r'<!-- hermes-note-id: (obsidian:[a-f0-9]{32}) -->')
EXCLUDED = {'attachments', '_attachment', '_templates', '_이전 기록', 'Scripts', 'Libraries'}
# 회사 메모 볼트의 폴더 이름은 사장 금고(obsidian.folders.*)에서 온다.
INBOX_FOLDER = vault.text('obsidian.folders.inbox')
INBOX_LABEL = vault.text('obsidian.folders.inbox_label')
TASKS_FOLDER = vault.text('obsidian.folders.tasks')
COMPLETE_FOLDER = vault.text('obsidian.folders.complete')


def required_folders():
    """금고에 폴더 이름이 없으면 볼트 맨 위에 쓰지 않고 분명히 실패한다."""
    if not (INBOX_FOLDER and INBOX_LABEL and TASKS_FOLDER and COMPLETE_FOLDER):
        raise vault.VaultError('owner vault obsidian.folders.* is not set; refusing to use the vault root')



def settings():
    from hermes_facility import app_scope, app_registry
    home = app_scope.bound_home()
    if home is not None and app_registry.explicit(app_registry.root_of(home), app_registry.profile_of(home)):
        selected = app_scope.require_selected('obsidian_folders')
        data = app_registry.values(app_registry.root_of(home), app_registry.profile_of(home)).get('service:obsidian-notes', {})
        return {'enabled': app_scope.note_source() == 'obsidian', 'vault': data.get('vault'), 'folders': selected}
    import hermes_yaml
    try:
        value = hermes_yaml.safe_load(CONFIG.read_text())['plugins']['entries']['team-delegation']['settings'].get('obsidian_notes', {})
    except (FileNotFoundError, KeyError):
        return {}
    if not isinstance(value, dict): raise ValueError('OBSIDIAN_CONFIG_INVALID')
    return value


def enabled(home=None):
    if home is not None and Path(home).resolve()!=CONFIG.parent.resolve():return False
    return settings().get('enabled') is True

def is_id(value): return isinstance(value, str) and bool(re.fullmatch(r'obsidian:[a-f0-9]{32}', value))

def stamp(): return datetime.now(ZoneInfo('Asia/Seoul')).strftime('%Y-%m-%d %H:%M')

def digest(value): return hashlib.sha256(value.encode() if isinstance(value,str) else value).hexdigest()


@contextmanager
def materialize():
    libc = ctypes.CDLL(None); old = -1
    try:
        if hasattr(libc, 'getiopolicy_np'):
            old = libc.getiopolicy_np(3, 1)
            if old >= 0: libc.setiopolicy_np(3, 1, 2)
        yield
    finally:
        if old >= 0: libc.setiopolicy_np(3, 1, old)


def split(text):
    import hermes_yaml
    m = re.match(r'^---\r?\n(.*?)\r?\n---(?:\r?\n|$)', text, re.S)
    if not m: return {}, text
    meta = hermes_yaml.safe_load(m[1]) or {}
    if not isinstance(meta,dict): raise ValueError('OBSIDIAN_PROPERTIES_INVALID')
    return meta, text[m.end():]


def pack(meta, body, sid):
    # JSON values are valid YAML, including local timestamps and lists.
    header = ''.join(k+': '+json.dumps(v,ensure_ascii=False,default=str)+'\n' for k,v in meta.items())
    body = MARK.sub('',body).rstrip()
    return '---\n'+header+'---\n\n'+body+'\n\n<!-- hermes-note-id: '+sid+' -->\n'


class Plain(HTMLParser):
    def __init__(self): super().__init__(convert_charrefs=True); self.parts=[]
    def handle_data(self,data): self.parts.append(data)
    def handle_starttag(self,tag,attrs):
        if tag in {'br','p','div','li','tr','h1','h2','h3'}: self.parts.append('\n')
    def handle_endtag(self,tag):
        if tag in {'p','div','li','tr','h1','h2','h3'}: self.parts.append('\n')
        elif tag in {'td','th'}: self.parts.append(' | ')


def plain(value):
    p=Plain();p.feed(value);p.close();return ''.join(p.parts)


def rendered(title, body):
    import markdown
    body=MARK.sub('',body)
    # The existing format parser recognizes the visible checkbox glyph in HTML lists.
    body=re.sub(r'(?m)^(\s*[-*] )\[([ xX])\] ',lambda m:m[1]+('☐ ' if m[2]==' ' else '☑ '),body)
    result=markdown.markdown(body,extensions=['tables','sane_lists'],tab_length=2)
    # Keep the formatter's color recognition for inline CSS imported from Notes.
    result=re.sub(r'<span style="color:(#[a-fA-F0-9]{6})">',r'<span color="\1" style="color:\1">',result)
    # Do not replace closing spans globally: the HTML parser tolerates font color on spans too.
    return '<h1>'+escape(title)+'</h1>\n'+result


class Store:
    def __init__(self, root=None, state=None):
        cfg=settings() if root is None else {}
        raw=Path(root or cfg.get('vault','')).expanduser()
        if root is None and (not cfg.get('enabled') or not cfg.get('vault')): raise ValueError('OBSIDIAN_NOT_ENABLED')
        if not raw.is_absolute() or not raw.is_dir(): raise ValueError('OBSIDIAN_VAULT_UNAVAILABLE')
        from hermes_facility.app_scope import bound_home
        home = bound_home() if root is None else None
        self.root=raw.resolve();self.state=Path(state or (home/'state/obsidian-notes' if home is not None else STATE))
        self.allowed = cfg.get('folders')

    def allowed_path(self, relative):
        p = Path(relative)
        return self.allowed is None or any(p == Path(f) or Path(f) in p.parents for f in self.allowed)

    def path(self, relative, *, system=False):
        p=Path(relative)
        if p.is_absolute() or '..' in p.parts or not p.parts: raise ValueError('OBSIDIAN_PATH_REFUSED')
        if not system and not self.allowed_path(p): raise ValueError('APP_OUT_OF_SCOPE')
        if not system and any(x.startswith('.') or x in EXCLUDED for x in p.parts): raise ValueError('OBSIDIAN_PATH_REFUSED')
        target=self.root/p
        if not target.resolve().is_relative_to(self.root) or any((self.root/Path(*p.parts[:i])).is_symlink() for i in range(1,len(p.parts)+1)):
            raise ValueError('OBSIDIAN_SYMLINK_REFUSED')
        return target

    @contextmanager
    def locked(self):
        self.state.mkdir(parents=True,exist_ok=True)
        with (self.state/'lock').open('a') as lock, materialize():
            fcntl.flock(lock,fcntl.LOCK_EX)
            file=self.state/'index.json'
            data=json.loads(file.read_text()) if file.exists() else {'notes':{},'history':[]}
            original=json.dumps(data,sort_keys=True,ensure_ascii=False)
            try:
                yield data
            finally:
                if json.dumps(data,sort_keys=True,ensure_ascii=False)!=original:
                    self.atomic(file,json.dumps(data,ensure_ascii=False,indent=2)+'\n')

    HISTORY_PER_NOTE = 10

    @classmethod
    def trim(cls, index):
        """Keep every pending record and each note's latest records only: the full 'before' text of every
        edit otherwise accumulates forever in index.json, which every read and write loads (2026-11-03)."""
        kept, counts = [], {}
        for record in reversed(index['history']):
            counts[record['id']] = counts.get(record['id'], 0) + 1
            if record.get('status') == 'pending' or counts[record['id']] <= cls.HISTORY_PER_NOTE:
                kept.append(record)
        index['history'] = kept[::-1]

    @staticmethod
    def atomic(path, text):
        path.parent.mkdir(parents=True,exist_ok=True)
        fd,name=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
        try:
            with os.fdopen(fd,'w') as f: f.write(text);f.flush();os.fsync(f.fileno())
            os.replace(name,path)
        finally:
            if os.path.exists(name):os.unlink(name)

    def files(self):
        found=[]
        for base,dirs,names in os.walk(self.root,followlinks=False):
            dirs[:]=[n for n in dirs if not n.startswith('.') and n not in EXCLUDED and not (Path(base)/n).is_symlink()]
            for name in names:
                if name.endswith('.md') and not name.endswith('.excalidraw.md') and not name.startswith('.'):
                    p=Path(base)/name
                    if not self.allowed_path(p.relative_to(self.root)): continue
                    self.path(p.relative_to(self.root));found.append(p)
        return sorted(found)

    def scan(self, index):
        found={};by_path={v['path']:k for k,v in index['notes'].items() if not v.get('deleted')}
        for f in self.files():
            text=f.read_text();matches=MARK.findall(text)
            if len(matches)>1:raise ValueError('OBSIDIAN_DUPLICATE_ID')
            sid=matches[0] if matches else by_path.get(str(f.relative_to(self.root))) or 'obsidian:'+uuid.uuid4().hex
            if sid in found:raise ValueError('OBSIDIAN_DUPLICATE_ID')
            rel=str(f.relative_to(self.root));found[sid]=(f,text)
            index['notes'][sid]={'path':rel,'deleted':False}
        return found

    def read(self, sid):
        if not is_id(sid):raise ValueError('OBSIDIAN_NOTE_ID_REQUIRED')
        with self.locked() as index:
            found=self.scan(index)
            if sid not in found:
                from hermes_facility.errors import SourceReadError
                deleted=index['notes'].get(sid,{}).get('deleted')
                raise SourceReadError('missing' if deleted else 'transient','obsidian_deleted' if deleted else 'obsidian_unavailable_or_syncing')
            f,text=found[sid];return self.snapshot(sid,f,text)

    def snapshot(self,sid,f,text):
        meta,body=split(text);body=MARK.sub('',body).strip()
        html=rendered(f.stem,body)
        assets=[];missing=[]
        links=re.findall(r'(?:src|href)=[\"\']([^\"\']+)[\"\']',body)
        links+=re.findall(r'!?\[(?:\\.|[^\]\\\n])*\]\(([^)]+)\)',body)
        for target in links:
            if urlparse(target).scheme:continue
            asset=(f.parent/unquote(target)).resolve()
            if not asset.is_relative_to(self.root):continue
            self.path(asset.relative_to(self.root),system=True)
            if asset.is_file():assets.append(str(asset))
            else:missing.append(str(asset))
        assets=list(dict.fromkeys(assets))
        return {'note_id':sid,'title':f.stem,'path':str(f.relative_to(self.root)),'folder':str(f.parent.relative_to(self.root)),
                'markdown':body,'full_text':text,'properties':meta,'revision':digest(text),'body_html':html,
                'plaintext':plain(html),'attachment_names':[Path(x).name for x in assets],'attachment_paths':assets,
                'missing_attachment_paths':list(dict.fromkeys(missing)),
                'url':self.url(f.relative_to(self.root)),'backend':'obsidian'}

    def all(self):
        with self.locked() as index:return [self.snapshot(k,*v) for k,v in self.scan(index).items()]

    def url(self,path):return 'obsidian://open?vault='+quote(self.root.name,safe='')+'&file='+quote(str(path),safe='')

    def folder(self,value):
        if value=='.':
            if not self.allowed_path('.'): raise ValueError('APP_OUT_OF_SCOPE')
            return '.'
        if self.allowed is None: required_folders()
        value={INBOX_LABEL:INBOX_FOLDER,'complete':COMPLETE_FOLDER,'Complete':COMPLETE_FOLDER}.get(value,value)
        p=self.path(value);return str(p.relative_to(self.root))

    def metadata(self,sid=None):
        if self.allowed is None: required_folders()
        folders={INBOX_FOLDER,TASKS_FOLDER,COMPLETE_FOLDER} if self.allowed is None else set(self.allowed)
        with materialize():
            for f in self.files():folders.add(str(f.parent.relative_to(self.root)))
        def row(folder):return {'id':'obsidian-folder:'+folder,'name':folder,'account':'obsidian:'+self.root.name}
        original=None;current=None
        if sid:
            snap=self.read(sid);current=row(snap['folder']);folders.add(snap['folder'])
            original={'title':snap['title'],'created_at':str(snap['properties'].get('created') or ''),
                      'folder_id':current['id'],'folder_name':current['name'],'account_id':current['account']}
            if not original['created_at']:
                original['created_at']=datetime.fromtimestamp(self.path(snap['path']).stat().st_mtime,ZoneInfo('Asia/Seoul')).isoformat()
        return {'folders':[row(x) for x in sorted(folders)],'current':current,'original':original}

    def write(self,sid,body,*,before=None,title=None,folder=None,properties=None):
        if not is_id(sid):raise ValueError('OBSIDIAN_NOTE_ID_REQUIRED')
        with self.locked() as index:
            found=self.scan(index);old=found.get(sid)
            pending=[r for r in index['history'] if r['id']==sid and r.get('status')=='pending']
            if pending:raise ValueError('OBSIDIAN_UNCERTAIN_WRITE_NO_REPLAY')
            if before is not None:
                if old is None or digest(old[1])!=before['revision']:raise ValueError('OBSIDIAN_CONCURRENT_CHANGE')
                meta,_=split(old[1]);previous=old[0]
            elif old is not None:raise ValueError('OBSIDIAN_ALREADY_EXISTS')
            else:meta={};previous=None
            if properties is not None:meta.update(properties)
            meta.setdefault('created',stamp());meta['modified']=stamp()
            name=title or (previous.stem if previous else '')
            if not name or re.search(r'[/\\\x00-\x1f]',name) or name in {'.','..'}:raise ValueError('OBSIDIAN_TITLE_INVALID')
            rel=Path(self.folder(folder or (str(previous.parent.relative_to(self.root)) if previous else TASKS_FOLDER)))/(name+'.md')
            target=self.path(rel);target.parent.mkdir(parents=True,exist_ok=True)
            if target!=previous and target.exists():raise ValueError('OBSIDIAN_DESTINATION_EXISTS')
            # Move/rename keeps all relative attachment links valid.
            if previous and target.parent!=previous.parent:
                def relocate(m):
                    link=m[2]
                    if urlparse(link).scheme:return m[0]
                    asset=(previous.parent/unquote(link)).resolve()
                    if not asset.is_relative_to(self.root):raise ValueError('OBSIDIAN_ATTACHMENT_OUTSIDE_VAULT')
                    return m[1]+quote(os.path.relpath(asset,target.parent),safe='/')+')'
                body=re.sub(r'(!?\[(?:\\.|[^\]\\\n])*\]\()([^)]+)\)',relocate,body)
            text=pack(meta,body,sid)
            record={'id':sid,'before_path':str(previous.relative_to(self.root)) if previous else None,
                    'before':old[1] if old else None,'after_path':str(rel),'after_hash':digest(text),'at':stamp(),'status':'pending'}
            # Refuse a concurrent edit before recording pending: nothing was written, so no replay lock.
            if previous and previous.read_text()!=old[1]:raise ValueError('OBSIDIAN_CONCURRENT_CHANGE')
            index['history'].append(record)
            self.trim(index)
            self.atomic(self.state/'index.json',json.dumps(index,ensure_ascii=False,indent=2)+'\n')
            if target==previous:self.atomic(target,text)
            else:
                with target.open('x') as f:f.write(text);f.flush();os.fsync(f.fileno())
                if previous:
                    if previous.read_text()!=old[1]:raise ValueError('OBSIDIAN_MOVE_SOURCE_CHANGED')
                    previous.unlink()
            if target.read_text()!=text:raise ValueError('OBSIDIAN_WRITE_UNVERIFIED')
            index['notes'][sid]={'path':str(rel),'deleted':False};record['status']='done'
            return self.snapshot(sid,target,text)

    def delete(self,sid,before):
        with self.locked() as index:
            current=self.scan(index).get(sid)
            if not current or digest(current[1])!=before['revision']:raise ValueError('OBSIDIAN_CONCURRENT_CHANGE')
            f,text=current;trash=self.path('.trash/'+sid.split(':')[1]+'-'+uuid.uuid4().hex+'.md',system=True)
            trash.parent.mkdir(exist_ok=True)
            # Never delete attachment files or other notes.
            if f.read_text()!=text:raise ValueError('OBSIDIAN_CONCURRENT_CHANGE')
            os.rename(f,trash);index['notes'][sid]={'path':str(trash.relative_to(self.root)),'deleted':True}
            index['history'].append({'id':sid,'before':text,'before_path':str(f.relative_to(self.root)),'deleted_to':str(trash.relative_to(self.root)),'at':stamp(),'status':'done'})
            self.trim(index)
            return {'note_id':sid,'trash_path':str(trash.relative_to(self.root))}

    def restore(self,sid,snapshot):
        data=json.loads(snapshot)
        if data.get('id')!=sid or data.get('backend')!='obsidian':raise ValueError('OBSIDIAN_ROLLBACK_ID_MISMATCH')
        text=data['text'];matches=MARK.findall(text)
        if matches and matches!=[sid]:raise ValueError('OBSIDIAN_ROLLBACK_ID_MISMATCH')
        target=self.path(data['path'])
        with self.locked() as index:
            found=self.scan(index);current=found.get(sid)
            if current is None:raise ValueError('OBSIDIAN_ROLLBACK_CONCURRENT_CHANGE')
            previous,observed=current
            if previous==target and observed==text:return self.snapshot(sid,target,text)
            last=next((x for x in reversed(index['history']) if x['id']==sid and x.get('status')=='done'),None)
            if (not last or last.get('after_hash')!=digest(observed) or
                    any(r['id']==sid and r.get('status')=='pending' for r in index['history'])):
                raise ValueError('OBSIDIAN_ROLLBACK_CONCURRENT_CHANGE')
            if target!=previous and target.exists():raise ValueError('OBSIDIAN_DESTINATION_EXISTS')
            target.parent.mkdir(parents=True,exist_ok=True)
            # Restore the exact snapshot. A normal write would rewrite modified time
            # and rebase attachment links that already refer to the original folder.
            record={'id':sid,'before_path':str(previous.relative_to(self.root)),
                    'before':observed,'after_path':data['path'],'after_hash':digest(text),'at':stamp(),'status':'pending'}
            if previous.read_text()!=observed:raise ValueError('OBSIDIAN_CONCURRENT_CHANGE')
            index['history'].append(record);self.trim(index)
            self.atomic(self.state/'index.json',json.dumps(index,ensure_ascii=False,indent=2)+'\n')
            if target==previous:self.atomic(target,text)
            else:
                with target.open('x') as stream:stream.write(text);stream.flush();os.fsync(stream.fileno())
                if previous.read_text()!=observed:raise ValueError('OBSIDIAN_MOVE_SOURCE_CHANGED')
                previous.unlink()
            if target.read_text()!=text:raise ValueError('OBSIDIAN_WRITE_UNVERIFIED')
            index['notes'][sid]={'path':data['path'],'deleted':False};record['status']='done'
            return self.snapshot(sid,target,text)
