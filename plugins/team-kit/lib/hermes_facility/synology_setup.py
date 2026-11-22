"""Read-only Drive folder choices, mapped solely by /mydrive relative paths."""
import json
import re
import sqlite3
from contextlib import contextmanager, closing
from pathlib import Path
import time
from hermes_packs.files_docs import files
from hermes_facility import path_form
from hermes_facility import connection_checks as checks
from hermes_facility import app_registry

MAX_FOLDERS=500
SETUP_SECONDS=30
HINT='Synology Drive에서 이 폴더 동기화를 켜 주세요. 켠 뒤 다시 눌러 주세요.'
CHECK_ID='synology-setup'


class LoginError(ValueError):
    """Only safe failure metadata crosses the setup adapter boundary."""
    def __init__(self, reason, details):
        super().__init__(reason)
        self.details = {k: details[k] for k in ('retry_after', 'error_category') if k in details}
        self.details['input_error'] = checks.synology_failure_hint(details.get('error_category'))


def last_check(home):
    return checks.load_checks(app_registry.root_of(home)).get(app_registry.profile_of(home)+'/'+CHECK_ID)


def save_check(home,state,reason,**extra):
    checks.save_check(app_registry.root_of(home),app_registry.profile_of(home),CHECK_ID,
        dict(state=state,reason=reason,at=time.time(),verified_by='synology_login',**extra))


def login(home,selected,opener=None):
    """Check this explicit screen attempt once; retain failure records for background checks."""
    with checks.candidate_values(selected.get('_secrets',{})):
        answer=checks.check_synology(home,settings(selected),opener or checks.default_opener(),time.time,last_check(home),manual=True)
    extra=answer[3] if len(answer)>3 else {}
    if not selected.get('_change'):save_check(home,answer[0],answer[1],**extra)
    if answer[0]!='connected':raise LoginError(answer[1], extra)


def settings(selected):
    value={k:selected.get(k) for k in ('api_base','link_host','sync_root')}
    value.update(sync_root=value['sync_root'] or '/',drive_root='/mydrive',user='SYNOLOGY_DRIVE_USER',password='SYNOLOGY_DRIVE_PASSWORD')
    files.nas_settings(value)  # identical relay, URL, credential-name and drive-root boundary
    return value


def candidates(home=None):
    home=Path.home() if home is None else Path(home)
    cloud=home/'Library/CloudStorage'
    paths=list(cloud.glob('SynologyDrive-*')) if cloud.is_dir() else []
    paths.extend([home/'SynologyDrive',home/'Synology Drive'])
    return [dict(id=str(p),label=p.name,mac_path=str(p)) for p in dict.fromkeys(paths)
            if p.is_dir() and not any(v.is_symlink() for v in (p,*p.parents))]


def sync_root(selected):
    raw=selected.get('sync_root')
    if not isinstance(raw,str) or not Path(raw).is_absolute():raise ValueError('SCOPE_INVALID')
    path=Path(raw)
    if not path.is_dir() or any(v.is_symlink() for v in (path,*path.parents)):raise ValueError('SCOPE_INVALID')
    return path.resolve()


@contextmanager
def metadata_session(home,selected,opener=None):
    """One explicit screen read; record failures without blocking another screen attempt."""
    cfg=settings(selected);local=sync_root(selected);base=cfg['api_base'].rstrip('/')
    with checks.candidate_values(selected.get('_secrets',{})):
        credential_digest=checks.synology_credential_digest(home,cfg)
    opener=opener or checks.default_opener();deadline=time.monotonic()+SETUP_SECONDS
    session={'sid':None,'cooldown':0};logged_in=False
    with checks.candidate_values(selected.get('_secrets',{})):
        try:
            files._nas_login(base,cfg,Path(home),session,opener,deadline)
            logged_in=True
            def request(body):
                return files._nas_api(base,dict(api='SYNO.SynologyDrive.Files',version=1,
                    _sid=session['sid'],**body),opener,deadline)
            yield local,request
        except files._NasError as error:
            auth=not logged_in and error.code in checks.SYNOLOGY_AUTH_CODES
            reason='AUTH_FAILED' if auth else 'NETWORK'
            details=dict(retry_after=time.time()+(
                checks.SYNOLOGY_AUTH_COOLDOWN if auth else checks.SYNOLOGY_TRANSPORT_COOLDOWN),
                credential_digest=credential_digest,error_category=checks.synology_error_category(error.code) if not logged_in else 'CONNECTION')
            if not selected.get('_change'):save_check(home,'needs_reconnect' if auth else 'unknown',reason,**details)
            raise LoginError(reason,details) from None
        except OSError:
            details=dict(retry_after=time.time()+checks.SYNOLOGY_TRANSPORT_COOLDOWN,
                         credential_digest=credential_digest,error_category='CONNECTION')
            if not selected.get('_change'):save_check(home,'unknown','NETWORK',**details)
            raise LoginError('NETWORK',details) from None
        finally:
            if session['sid']:
                try:files._nas_api(base,{'api':'SYNO.API.Auth','version':6,'method':'logout','session':'SynologyDrive','_sid':session['sid']},opener,deadline)
                except (OSError,ValueError,TypeError):pass  # logout failure cannot authorize any folder
    if not selected.get('_change'):save_check(home,'connected','SYNOLOGY_VERIFIED')


def scope_failure_hint(error, *, checking=False):
    """Only fixed facility text and sanitized login metadata reach the screen."""
    action='NAS 폴더를 확인하지 못했어요.' if checking else 'NAS 폴더 목록을 읽지 못했어요.'
    if isinstance(error,LoginError):
        return action+' '+error.details['input_error']+' 다시 하기를 눌러 주세요.'
    detail={
        'SCOPE_INVALID':'고른 폴더와 이 Mac의 동기화 상태를 확인해 주세요.',
        'NAS_LIST_LIMIT':'최상위 폴더가 너무 많아요.',
        'NAS_LIST_INVALID':'서버의 폴더 응답을 확인하지 못했어요.',
        'NAS_LIST_CHANGED':'서버의 폴더 목록이 바뀌었어요.'}.get(str(error),'연결 상태를 확인해 주세요.')
    return action+' '+detail+' 다시 하기를 눌러 주세요.'


def folders(home,selected,*,opener=None):
    """List /mydrive children only, completely paginated; never walk descendants."""
    result=[]
    with metadata_session(home,selected,opener) as (local,request):
        offset=0;seen=set();expected_total=None
        while True:
            data=request(dict(method='list',path=json.dumps('/mydrive'),offset=offset,limit=100))
            rows,total=data.get('items'),data.get('total')
            if not isinstance(rows,list) or type(total) is not int or not 0<=total<=10000 or not rows and offset<total:raise ValueError('NAS_LIST_INVALID')
            if expected_total is not None and total!=expected_total:raise ValueError('NAS_LIST_CHANGED')
            expected_total=total
            for row in rows:
                name=row.get('name') if isinstance(row,dict) else None
                if not isinstance(name,str) or not name or '/' in name or '\x00' in name or name in ('.','..'):raise ValueError('NAS_LIST_INVALID')
                normalized=path_form.normal(name)
                if normalized in seen:raise ValueError('NAS_LIST_CHANGED')
                seen.add(normalized)
                if row.get('type')=='dir':
                    if len(result)>=MAX_FOLDERS:raise ValueError('NAS_LIST_LIMIT')
                    remote='/mydrive/'+name;target=local/name
                    available=target.is_dir() and not any(p.is_symlink() for p in (target,*target.parents)) and target.resolve().is_relative_to(local)
                    result.append(dict(id=remote,label=remote+' → '+str(target),server_path=remote,mac_path=str(target),
                        value=str(target),disabled=not available,needs_user=not available,hint=None if available else HINT))
                elif row.get('type')!='file':raise ValueError('NAS_LIST_INVALID')
            offset+=len(rows)
            if offset>=total:
                if offset!=total:raise ValueError('NAS_LIST_CHANGED')
                break
    return result


def check_folders(home,selected,*,opener=None):
    """Check each granted folder's metadata and local mapping, without listing."""
    local=sync_root(selected);scopes=selected.get('scope')
    if not isinstance(scopes,list) or not scopes:raise ValueError('SCOPE_INVALID')
    relatives=[]
    for raw in scopes:
        if not isinstance(raw,str):raise ValueError('SCOPE_INVALID')
        target=Path(raw)
        if (not target.is_absolute() or not target.is_dir() or any(p.is_symlink() for p in (target,*target.parents))
                or path_form.below(target.resolve(),local) is None):raise ValueError('SCOPE_INVALID')
        relatives.append(path_form.below(target.resolve(),local))
        next(iter(target.iterdir()),None)
    drive_root=settings(selected)['drive_root']  # the same drive-root rule metadata_session applies
    remote_paths=[path_form.normal(drive_root+('/'+relative.as_posix() if relative.parts else '')) for relative in relatives]
    with metadata_session(home,selected,opener) as (_,request):
        for remote in remote_paths:
            data=request(dict(method='get',path=json.dumps(remote)))
            if data.get('type')!='dir':raise ValueError('SCOPE_INVALID')
    return True


def clean_candidate(value):
    """A candidate remains one source's bundle; invalid address cells are discarded."""
    bad=files.address_problems(value.get('api_base'),value.get('link_host'))
    result={k:value[k] for k in ('api_base','link_host') if k not in bad}
    if not result:return None
    if isinstance(value.get('username'),str) and value['username']:result['username']=value['username']
    result['source']=value.get('source','saved')
    return result


def unique_candidates(values):
    found={}
    for value in values:
        candidate=clean_candidate(value)
        if candidate:
            key=tuple(candidate.get(k) for k in ('api_base','link_host','username'))
            found.setdefault(key,candidate)
    return list(found.values())


def drive_candidates(user_home=None):
    """Only public address/username columns, read-only SQLite; no sessions or secrets."""
    user_home=Path.home() if user_home is None else Path(user_home)
    data=user_home/'Library/Application Support/SynologyDrive/data'
    path=data/'db/sys.sqlite'
    if not path.is_file():return []
    try:
        with closing(sqlite3.connect(path.as_uri()+'?mode=ro',uri=True)) as db:
            columns={row[1] for row in db.execute('PRAGMA table_info(connection_table)')}
            allowed=[name for name in ('username','server_name','server_ip','server_port','quickconn_mode','host_name','use_ssl') if name in columns]
            if not allowed:return []
            rows=[dict(zip(allowed,row)) for row in db.execute('SELECT '+','.join(allowed)+' FROM connection_table')]
    except (OSError,sqlite3.Error):return []
    ids=set()
    try:
        # A unique logged relay ID can be associated; multiple IDs must never be guessed.
        with (data/'log/daemon.log').open(errors='replace') as stream:
            for line in stream:
                ids.update(re.findall(r'\.([A-Za-z0-9_-]+)\.direct\.quickconnect\.to',line))
    except OSError:pass
    result=[]
    for row in rows:
        item=dict(username=row.get('username'),source='drive')
        name=row.get('server_name')
        qc=None
        if isinstance(name,str):
            match=re.fullmatch(r'([A-Za-z0-9_-]+)\.quickconnect\.to',name)
            if match:qc=match[1]
            elif row.get('quickconn_mode') and re.fullmatch(r'[A-Za-z0-9_-]+',name):qc=name
        if qc is None and len(ids)==1:qc=next(iter(ids))
        if qc:item['link_host']=qc+'.quickconnect.to'
        for column in ('host_name','server_name','server_ip'):
            host=row.get(column)
            if not isinstance(host,str) or not host:continue
            address=host if '://' in host else ('https://'+host if row.get('use_ssl') and row.get('server_port') in (None,0,443,'443') else '')
            if 'api_base' not in files.address_problems(address,None):
                item['api_base']=address.rstrip('/');break
        result.append(item)
    return unique_candidates(result)


def other_candidates(root, profile, bundle):
    from hermes_facility import connections, app_connect
    result=[]
    for other,home,_,config in connections.profile_contexts(root):
        if other==profile:continue
        if not app_registry.connected(config,home,dict(bundle_id=bundle)):continue
        path=app_connect.record_path(home,bundle)
        try:
            if path.is_symlink():continue
            if path.is_file():
                record=json.loads(path.read_text())
                if not isinstance(record,dict) or record.get('phase')=='choosing':continue
        except (OSError,ValueError,TypeError):continue
        value=app_connect.legacy_values(config,[bundle]).get(bundle,{})
        value.update(app_registry.values(root,other).get(bundle,{}))
        candidate=clean_candidate(dict(value,source='employee'))
        if not candidate:continue
        # Request exactly the allowed username name, never another employee's password.
        username=checks.env_value(home,'SYNOLOGY_DRIVE_USER')
        if username:candidate['username']=username
        result.append(candidate)
    return unique_candidates(result)


def discover(root, profile, bundle, user_home=None):
    """Address-source precedence; own draft/legacy is resolved by the connection command."""
    candidates=other_candidates(root,profile,bundle)
    return candidates if candidates else drive_candidates(user_home)


def address_fields(value):
    return [dict(id=k,label=label,secure=False,**({'value':value[k]} if value.get(k) else {}))
            for k,label in [('api_base','서버에 연결할 주소'),('link_host','파일을 열 때 쓸 주소')]]


def candidate_options(choices):
    labels={key:c['link_host']+(' · '+c['username'] if c.get('username') else '') for key,c in choices.items()}
    sources={'employee':'다른 직원 연결','drive':'이 Mac의 Synology Drive'}
    return [dict(id=key,label=label+(' (출처: '+sources[c['source']]+')' if list(labels.values()).count(label)>1 else ''))
            for key,c in choices.items() for label in [labels[key]]]


def prepare(root, profile, bundle, selected, config, submitted, choice=None):
    """Resolve one source, validate cells, and return safe fields or click choices."""
    from hermes_facility import app_connect
    own=dict(selected)
    if not any(own.get(k) for k in ('api_base','link_host')):
        own.update(app_connect.legacy_values(config,[bundle]).get(bundle,{}))
    own_bad=files.address_problems(own.get('api_base'),own.get('link_host'))
    has_own=not own_bad
    candidates=[] if has_own else discover(root,profile,bundle)
    chosen={};options=None
    invalid=bool(own_bad and any(own.get(k) for k in ('api_base','link_host')))
    if has_own:
        chosen=clean_candidate(own) or {}
        if not invalid:
            # Username-only exception to address precedence: search matching bundles, never borrow addresses.
            candidates=other_candidates(root,profile,bundle)+drive_candidates()
            matches=unique_candidates([c for c in candidates if all(c.get(k)==own.get(k) for k in ('api_base','link_host'))])
            if len(matches)==1 and matches[0].get('username'):chosen['username']=matches[0]['username']
    else:
        complete=[c for c in candidates if not files.address_problems(c.get('api_base'),c.get('link_host'))]
        pool=complete or candidates
        if len(complete)>1:
            import hashlib
            choices={hashlib.sha256(json.dumps(c,sort_keys=True).encode()).hexdigest()[:24]:c for c in complete}
            picked=('manual' if any(k in (submitted or {}) for k in ('api_base','link_host'))
                    else choice[0] if isinstance(choice,list) and len(choice)==1 else choice)
            if isinstance(picked,str) and picked in choices:chosen=choices[picked]
            elif picked!='manual':
                options=candidate_options(choices)+[dict(id='manual',label='직접 넣기')]
        elif len(pool)==1:chosen=pool[0]
        elif pool:
            chosen={k:pool[0][k] for k in ('api_base','link_host','username') if pool[0].get(k) and all(c.get(k)==pool[0][k] for c in pool)}
        # Partial candidates fill cells first; keep a valid own cell only when no source supplies it.
        if not complete:
            for key in ('api_base','link_host'):
                if key not in chosen and key not in own_bad:chosen[key]=own[key]
    value={k:v for k,v in selected.items() if k not in ('api_base','link_host','_username')}
    value.update({k:v for k,v in chosen.items() if k in ('api_base','link_host')})
    if chosen.get('username'):value['_username']=chosen['username']
    if any(k in chosen and v!=chosen[k] for k,v in (submitted or {}).items() if k in ('api_base','link_host')):
        value.pop('_username',None)
    value.update({k:v for k,v in (submitted or {}).items() if k in ('api_base','link_host')})
    bad=files.address_problems(value.get('api_base'),value.get('link_host'))
    invalid=invalid or any(value.get(k) for k in bad)
    if bad or any(value.get(k)!=own.get(k) for k in ('api_base','link_host')):
        value.pop('login_selected',None)
    for k in bad:value.pop(k,None)
    done=[s for s in value.get('setup_done',[]) if s!='address']
    if not bad:
        settings(value);done.insert(0,'address')
    value['setup_done']=done
    return value,options,invalid
