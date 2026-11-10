"""Read-only Drive folder choices, mapped solely by /mydrive relative paths."""
import json
from contextlib import contextmanager
from pathlib import Path
import time
import unicodedata
from hermes_packs.files_docs import files
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
    save_check(home,answer[0],answer[1],**extra)
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
            save_check(home,'needs_reconnect' if auth else 'unknown',reason,**details)
            raise LoginError(reason,details) from None
        except OSError:
            details=dict(retry_after=time.time()+checks.SYNOLOGY_TRANSPORT_COOLDOWN,
                         credential_digest=credential_digest,error_category='CONNECTION')
            save_check(home,'unknown','NETWORK',**details)
            raise LoginError('NETWORK',details) from None
        finally:
            if session['sid']:
                try:files._nas_api(base,{'api':'SYNO.API.Auth','version':6,'method':'logout','session':'SynologyDrive','_sid':session['sid']},opener,deadline)
                except (OSError,ValueError,TypeError):pass  # logout failure cannot authorize any folder
    save_check(home,'connected','SYNOLOGY_VERIFIED')


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
                normalized=unicodedata.normalize('NFC',name)
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
    remote_paths=[]
    for raw in scopes:
        if not isinstance(raw,str):raise ValueError('SCOPE_INVALID')
        target=Path(raw)
        if (not target.is_absolute() or not target.is_dir() or any(p.is_symlink() for p in (target,*target.parents))
                or not target.resolve().is_relative_to(local)):raise ValueError('SCOPE_INVALID')
        relative=target.resolve().relative_to(local)
        remote_paths.append(unicodedata.normalize('NFC','/mydrive'+('/'+relative.as_posix() if relative.parts else '')))
        next(iter(target.iterdir()),None)
    with metadata_session(home,selected,opener) as (_,request):
        for remote in remote_paths:
            data=request(dict(method='get',path=json.dumps(remote)))
            if data.get('type')!='dir':raise ValueError('SCOPE_INVALID')
    return True
