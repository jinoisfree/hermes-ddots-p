"""Owner-facing app connection transaction and resumable setup steps.

Roster is the grant, vault is user input, config is assembled, progress and the
short-lived transaction undo record belong to the employee's locker.
"""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import time
import unicodedata
from hermes_facility import app_registry as registry
from hermes_facility import plugin_store as store
from hermes_facility.config_assembly import assemble_config, app_manifests, atomic_write, locked, yaml_bytes, yaml_load, checked_path
from hermes_packs.mac_apps import catalog, discovery
from hermes_facility.mac_permission import internet_accounts, mac_account_settings

UNDO_SECONDS = 600
LABELS = [('enable', '연결 켜기'), ('values', '쓸 곳 고르기'), ('restart', '다시 시작'),
          ('permission', '권한 허용'), ('check', '실제로 확인')]
HINTS = {'choose_account': '사용할 계정을 직접 골라 주세요.',
         'choose_sync_root': '이 Mac에서 Synology Drive가 동기화하는 폴더를 직접 골라 주세요.',
         'choose_scope': '쓸 곳을 골라 주세요. 모두 선택할 수도 있어요.',
         'secret_set': '이 연결에 쓸 값을 직접 입력해 주세요.',
         'gateway_restart': '진행 중인 대화가 끝나면 다시 시작을 눌러 주세요.',
         'permission_request': '이 Mac 화면의 권한 창에서 허용을 눌러 주세요.',
         'open_settings': '시스템 설정에서 이 앱의 접근을 허용해 주세요.',
         'oauth_connect': '고른 계정으로 이 직원의 로그인 화면에서 로그인해 주세요.'}


def digest(data): return hashlib.sha256(data).hexdigest()


def record_path(home, bundle):
    return Path(home) / 'state/connections' / ('app-' + digest(bundle.encode())[:24] + '.json')


def read_record(path, clock):
    if not path.exists(): return {}
    if path.is_symlink(): raise ValueError('UNSAFE_PATH')
    value = json.loads(path.read_bytes())
    if clock() - value.get('at', 0) >= UNDO_SECONDS and 'undo' in value and value.get('phase') not in ('applying','undoing','choosing','input_applying'):
        del value['undo']
        atomic_write(path, json.dumps(value).encode())
    return value


def response(profile, bundle, steps=None, *, reason='OK', kind='done', **extra):
    return dict(profile=profile, app=bundle, outcome='done' if kind == 'done' and reason == 'OK' else 'waiting',
                reason=reason, steps=steps or [], next=dict(kind=kind, **extra), undo_until=None)


def steps_from(record):
    finished = set(record.get('done', []))
    labels=([('address','주소 입력'),('login','로그인'),('sync_root','동기화 폴더 확인'),
             ('values','폴더 고르기'),*[(i,l) for i,l in LABELS if i!='values']]
            if record.get('service')=='synology' else LABELS)
    return [dict(id=id, label=label, state='done' if id in finished else 'todo',
                 reason=None, needs_user=False, hint=None) for id, label in labels]


def wait(result, step, kind, reason, **extra):
    row = next(s for s in result['steps'] if s['id'] == step)
    row.update(state='failed' if reason not in ('CHOOSE_ACCOUNT', 'CHOOSE_SCOPE', 'SCOPE_EMPTY', 'CHOOSE_SYNC_ROOT', 'VALUES_REQUIRED',
                                              'RESTART_REQUIRED', 'PERMISSION_REQUIRED') else 'todo',
               reason={'PERMISSION_DENIED': '접근 권한이 꺼져 있어요. 시스템 설정에서 켜 주세요.',
                       'BUSY': '다른 대화를 처리하고 있어요. 끝난 뒤 다시 해 주세요.'}.get(reason, HINTS.get(kind, '확인하지 못했어요. 다시 해 주세요.')),
               needs_user=kind in HINTS, hint=extra.get('hint') or HINTS.get(kind))
    if 'guide' not in extra and kind not in ('open_settings','permission_request'):
        from hermes_facility.connection_guides import instructions
        extra['guide'] = instructions(catalog.load_catalog().get(result.get('app'),{}).get('service')) if kind == 'secret_set' else [dict(n=1,text=extra.get('hint') or HINTS.get(kind,'계속을 누르세요.'))]
    service = catalog.load_catalog().get(result.get('app'),{}).get('service')
    if kind == 'secret_set' and not extra.get('fields'):
        from hermes_facility.connection_secrets import FIELDS
        extra['fields'] = [dict(id=f,label=label,secure=secure) for f,label,secure,_ in FIELDS.get(service,[])]
        if service == 'obsidian_notes':extra['fields']=[dict(id='vault',label='Obsidian 보관함 폴더',secure=False)]
    from hermes_facility.connection_guides import failure_hint
    error = failure_hint(service,reason)
    if error and 'input_error' not in extra: extra['input_error'] = error
    result.update(outcome='waiting', reason=reason, next=dict(kind=kind, **extra))
    return result


def pending_progress(root, home, profile, bundle):
    """Present a pending journal without expiring undo, requesting access or writing it.

    Resuming uses the normal transaction command, which rechecks the next step
    and supplies fresh choices/permission instructions instead of caching them.
    """
    path = record_path(home, bundle)
    try:
        if path.is_symlink(): return None
        record = json.loads(path.read_bytes())
        if record.get('phase') not in ('applied', 'choosing'): return None
        action = record.get('action')
        if action not in ('connect', 'disconnect'): return None
        projected = deepcopy(record)
        done = projected.setdefault('done', [])
        if record.get('phase') == 'applied' and 'restart' not in done:
            from hermes_facility import gateway_restart
            if not record.get('restart_required') or gateway_restart.completed_since(root, record.get('at')):
                done.append('restart')
        if record.get('phase') == 'choosing':
            projected['service'] = catalog.load_catalog().get(bundle, {}).get('service')
            projected['done'] = draft_values(Path(root), profile, bundle).get('setup_done', [])
        steps = steps_from(projected)
        remaining = [s for s in steps if s['state'] != 'done' and (action != 'disconnect' or s['id'] == 'restart')]
        if not remaining:
            if action != 'disconnect' or all(s['id'] in record.get('done', []) for s in steps): return None
            for step in steps: step['state'] = 'done'
        result = response(profile, bundle, steps, reason='SETUP_PENDING', kind='resume', action=action)
        result['undo_until'] = record['at'] + UNDO_SECONDS if 'undo' in record and time.time() < record['at'] + UNDO_SECONDS else None
        if remaining and remaining[0]['id'] == 'restart':
            return wait(result, 'restart', 'gateway_restart', 'RESTART_REQUIRED', action=action)
        if remaining: remaining[0].update(needs_user=True, hint='이어가기를 누르면 저장된 단계부터 다시 확인해요.')
        return result
    except (OSError, ValueError, TypeError, KeyError):
        return None


def legacy_values(config, bundles):
    """A read-only presentation of the scopes the existing installation chose."""
    kit = config.get('plugins', {}).get('entries', {}).get('team-kit', {}).get('settings', {})
    scopes = kit.get('personal_scopes', {})
    delegation = config.get('plugins', {}).get('entries', {}).get('team-delegation', {}).get('settings', {})
    scope_path = delegation.get('personal_roles', {}).get('scope_config')
    if not scopes and scope_path:
        source = yaml_load(Path(scope_path).expanduser().read_bytes())
        scopes = source.get('plugins', {}).get('entries', {}).get('team-kit', {}).get('settings', {}).get('personal_scopes', {})
    combined = [v for v in scopes.values() if isinstance(v, dict)]
    result = {}
    table=catalog.load_catalog()
    for bundle in bundles:
        scope = table.get(bundle, {}).get('scope')
        if scope == 'folders': selected = kit.get('files', {}).get('folders', [])
        else:
            key = {'mail_accounts': 'mail_accounts', 'note_folders': 'notes_folders', 'calendars': 'calendar_ids'}.get(scope)
            selected = [item for group in combined for item in group.get(key, [])] if key else []
        if scope == 'note_folders':
            selected = list(dict.fromkeys([*selected, *(g['notes_folder_id'] for g in combined if g.get('notes_folder_id'))]))
        result[bundle] = dict(scope=deepcopy(selected))
        if table.get(bundle,{}).get('service')=='synology':
            nas=kit.get('files',{}).get('synology',{})
            result[bundle].update({k:nas[k] for k in ('api_base','link_host','sync_root','drive_root') if k in nas})
        if scope == 'calendars':
            defaults = [g['default_calendar_id'] for g in combined if g.get('default_calendar_id') in selected]
            if defaults: result[bundle]['default'] = defaults[0]
        if bundle == 'service:obsidian-notes':
            delegation = config.get('plugins', {}).get('entries', {}).get('team-delegation', {}).get('settings', {})
            result[bundle] = dict(vault=delegation.get('obsidian_notes', {}).get('vault'), scope=['.'])
    return result


def transaction_paths(root, snapshot):
    allowed = {'owner/team.yaml', 'owner/vault.yaml','owner/policy.yaml','plugin-store/links.json'}
    files = {}
    for name in snapshot['before']:
        if isinstance(snapshot['before'][name],dict):
            files[name]=store.host_path(root,name)
            continue
        path = checked_path(root, name)
        relative=Path(name).parts
        tail=relative[2:] if len(relative)>2 and relative[0]=='profiles' and registry.profile_home(root,relative[1]) else relative
        manifest=len(tail)==3 and tail[0]=='plugins' and tail[1] in ('team-kit','team-delegation') and tail[2]=='plugin.yaml'
        baseline=tail==('state','connections','manifest-bases.json')
        if name not in allowed and path.name not in ('config.yaml', '.env') and not manifest and not baseline:
            raise ValueError('UNSAFE_PATH')
        files[name] = path
    if set(snapshot['after']) != set(files): raise ValueError('CONNECTIONS_READ_FAILED')
    return files


def recover(root, path, record):
    """Roll interrupted multi-file changes back; never overwrite a third-party edit."""
    if record.get('phase') not in ('applying', 'undoing', 'input_applying'): return record
    snapshot = record['undo']; files = transaction_paths(root, snapshot)
    for name, p in files.items():
        before = snapshot['before'][name]
        raw = store.current(root,p,isinstance(before,dict))
        partial=isinstance(before,dict) and name in snapshot.get('hosts',{}) and store.in_transition(raw,before,snapshot['hosts'][name])
        if raw != store.decode(before) and store.fingerprint(raw)!=snapshot['after'][name] and not partial:
            raise ValueError('UNDO_CONFLICT')
    # Keeping phase until every restoration succeeds lets the next call resume recovery.
    for name, p in files.items():
        data = snapshot['before'][name]
        if isinstance(data,dict):store.write(root,p,data)
        elif data is None:p.unlink(missing_ok=True)
        else:atomic_write(p,bytes.fromhex(data))
    record['phase'] = 'recovered'; record['done'] = []
    record.pop('undo', None)
    atomic_write(path, json.dumps(record).encode())
    return record


def draft_values(root, profile, bundle):
    path=checked_path(root,'owner/vault.yaml')
    vault=yaml_load(path.read_bytes()) if path.exists() else {}
    return deepcopy(vault.get('app_setup',{}).get(profile,{}).get(bundle,{}))


def _input_slot(vault, profile, bundle):
    branch=vault.get('app_setup',{}).get(profile,{})
    return dict(exists=True,data=yaml_bytes(branch[bundle]).hex()) if bundle in branch else dict(exists=False)


def _input_mark(slot):
    value=dict(exists=slot['exists'])
    if slot['exists']:value['value']=yaml_load(bytes.fromhex(slot['data']))
    return digest(json.dumps(value,sort_keys=True,ensure_ascii=False).encode())


def _input_parents(vault,profile):
    return dict(setup='app_setup' in vault,profile=profile in vault.get('app_setup',{}))


def _input_env_parts(body):
    from dotenv.parser import parse_stream
    from io import StringIO
    return [(part.key,part.original.string.encode()) for part in parse_stream(StringIO(body.decode()))]


def _input_env_rows(body,names):
    rows={name:[] for name in names}
    for name,line in _input_env_parts(body):
        if name in rows:rows[name].append(line.hex())
    return rows


def _input_env_marks(rows):
    from dotenv import dotenv_values
    from io import StringIO
    return {name:dict(exists=bool(lines),digest=digest(json.dumps(dotenv_values(
        stream=StringIO(b''.join(bytes.fromhex(line) for line in lines).decode()),interpolate=False).get(name)).encode())) for name,lines in rows.items()}


def _input_env_names(bundle):
    return {'synology':{'SYNOLOGY_DRIVE_USER','SYNOLOGY_DRIVE_PASSWORD'},'notion':{'NOTION_API_KEY'}}.get(
        catalog.load_catalog().get(bundle,{}).get('service'),set())


def _input_restore_env(body,before):
    chunks=[];seen=set()
    def append(line):
        if line and chunks and not chunks[-1].endswith(b'\n') and not line.startswith(b'\n'):chunks.append(b'\n')
        chunks.append(line)
    for name,line in _input_env_parts(body):
        if name not in before:append(line)
        elif name not in seen:
            for value in before[name]:append(bytes.fromhex(value))
            seen.add(name)
    for name,lines in before.items():
        if name not in seen:
            for value in lines:append(bytes.fromhex(value))
    return b''.join(chunks)


def _input_validate(root,home,profile,bundle,scope):
    if scope.get('version')!=1 or scope.get('profile')!=profile or scope.get('app')!=bundle:raise ValueError('UNSAFE_PATH')
    p=checked_path(root,'owner/vault.yaml');vault=yaml_load(p.read_bytes()) if p.exists() else {}
    if _input_mark(_input_slot(vault,profile,bundle))!=scope['vault']['after']:raise ValueError('UNDO_CONFLICT')
    if 'env' in scope:
        env=scope['env'];name=str((home/'.env').relative_to(root))
        if env['path']!=name or set(env['before'])!=set(env['after']) or not set(env['before'])<=_input_env_names(bundle):raise ValueError('UNSAFE_PATH')
        p=checked_path(root,name);body=p.read_bytes() if p.exists() else b''
        if _input_env_marks(_input_env_rows(body,env['before']))!=env['after']:raise ValueError('UNDO_CONFLICT')


def _input_scope(root,home,profile,bundle,path,record):
    """Migrate only choosing journals. Old after bytes are unavailable: adopt the current owned slot."""
    undo=record.get('undo',{})
    if 'input' in undo:
        scope=undo['input'];_input_validate(root,home,profile,bundle,scope);return scope
    vault_path=checked_path(root,'owner/vault.yaml');env_name=str((home/'.env').relative_to(root))
    if set(undo.get('before',{}))!=set(undo.get('after',{})) or not set(undo.get('before',{}))<={'owner/vault.yaml',env_name} or 'owner/vault.yaml' not in undo.get('before',{}):raise ValueError('UNSAFE_PATH')
    before=undo['before']['owner/vault.yaml'];old=yaml_load(bytes.fromhex(before)) if before is not None else {}
    current=yaml_load(vault_path.read_bytes()) if vault_path.exists() else {}
    scope=dict(version=1,profile=profile,app=bundle,vault=dict(before=_input_slot(old,profile,bundle),
        parents=_input_parents(old,profile),existed=before is not None,after=_input_mark(_input_slot(current,profile,bundle))))
    if env_name in undo['before']:
        before=undo['before'][env_name];p=checked_path(root,env_name);names=_input_env_names(bundle)
        if not names:raise ValueError('UNSAFE_PATH')
        scope['env']=dict(path=env_name,existed=before is not None,before=_input_env_rows(bytes.fromhex(before) if before is not None else b'',names),
            after=_input_env_marks(_input_env_rows(p.read_bytes() if p.exists() else b'',names)))
    record['undo']=dict(input=scope);atomic_write(path,json.dumps(record).encode())
    return scope


def _input_restore(root,home,profile,bundle,scope):
    """Compose the original owned values into the latest shared files; never restore an old shared file."""
    _input_validate(root,home,profile,bundle,scope)
    p=checked_path(root,'owner/vault.yaml');body=p.read_bytes() if p.exists() else None
    vault=yaml_load(body) if body is not None else {};baseline=scope['vault'];slot=baseline['before']
    if slot['exists']:vault.setdefault('app_setup',{}).setdefault(profile,{})[bundle]=yaml_load(bytes.fromhex(slot['data']))
    else:
        setup=vault.get('app_setup',{});branch=setup.get(profile,{})
        branch.pop(bundle,None)
        if not branch and not baseline['parents']['profile']:setup.pop(profile,None)
        if not setup and not baseline['parents']['setup']:vault.pop('app_setup',None)
    restored={p:yaml_bytes(vault) if vault or baseline['existed'] else None}
    if 'env' in scope:
        env=scope['env'];p=checked_path(root,env['path']);body=p.read_bytes() if p.exists() else b''
        body=_input_restore_env(body,env['before']);restored[p]=body if body or env['existed'] else None
    return restored


def _cancel_input(root,home,profile,bundle,path,record):
    scope=_input_scope(root,home,profile,bundle,path,record)
    desired=_input_restore(root,home,profile,bundle,scope)
    # The existing short rollback protects a cancellation interrupted between files.
    record.update(phase='undoing',undo=dict(before={str(p.relative_to(root)):body.hex() if body is not None else None for p,body in desired.items()},
        after={str(p.relative_to(root)):store.fingerprint(p.read_bytes() if p.exists() else None) for p in desired}))
    atomic_write(path,json.dumps(record).encode())
    return recover(root,path,record)


def stage_values(root,profile,bundle,selected,clock):
    """Save explicit choices in vault, secrets only in .env, without a grant.

    Choosing keeps only this input's rollback scope. A short write-ahead
    transaction still protects a process dying between the input writes.
    """
    home=registry.profile_home(root,profile)
    path=record_path(home,bundle)
    with locked(root/'owner/.app-connect.lock'):
        record=read_record(path,clock)
        if record.get('phase') in ('input_applying','applying','undoing'):record=recover(root,path,record)
        if record.get('phase')=='applied' and record.get('undo'):raise ValueError('CONNECTION_IN_PROGRESS')
        vault_path=checked_path(root,'owner/vault.yaml')
        vault=yaml_load(vault_path.read_bytes()) if vault_path.exists() else {}
        scope=deepcopy(_input_scope(root,home,profile,bundle,path,record)) if record.get('phase')=='choosing' else dict(
            version=1,profile=profile,app=bundle,vault=dict(before=_input_slot(vault,profile,bundle),
            parents=_input_parents(vault,profile),existed=vault_path.exists()))
        saved={k:deepcopy(v) for k,v in selected.items() if not k.startswith('_')}
        vault.setdefault('app_setup',{}).setdefault(profile,{})[bundle]=saved
        desired={vault_path:yaml_bytes(vault)}
        scope['vault']['after']=_input_mark(_input_slot(vault,profile,bundle))
        if selected.get('_secrets'):
            from hermes_facility.connection_secrets import env_bytes
            env_path=checked_path(root,str((home/'.env').relative_to(root)))
            if not set(selected['_secrets'])<=_input_env_names(bundle):raise ValueError('UNSAFE_PATH')
            body=env_path.read_bytes() if env_path.exists() else b''
            env=scope.setdefault('env',dict(path=str(env_path.relative_to(root)),existed=env_path.exists(),before={},after={}))
            # Existing 0600 rollback exception: previous owned lines only; never the submitted secret.
            env['before'].update(_input_env_rows(body,set(selected['_secrets'])-set(env['before'])))
            desired[env_path]=env_bytes(body,selected['_secrets'])
            env['after']=_input_env_marks(_input_env_rows(desired[env_path],env['before']))
        # Roll a failed input save back to the original owned values, retaining other callers' current values.
        original=deepcopy(scope)
        original['vault']['after']=_input_mark(_input_slot(yaml_load(vault_path.read_bytes()) if vault_path.exists() else {},profile,bundle))
        if 'env' in original:
            p=checked_path(root,original['env']['path']);body=p.read_bytes() if p.exists() else b''
            original['env']['after']=_input_env_marks(_input_env_rows(body,original['env']['before']))
        before=_input_restore(root,home,profile,bundle,original)
        for p in before:desired.setdefault(p,p.read_bytes() if p.exists() else None)
        record=dict(at=clock(),action='connect',phase='input_applying',done=[],undo=dict(before=before,
                    after={str(p.relative_to(root)):store.fingerprint(body) for p,body in desired.items()}))
        record['undo']['before']={str(p.relative_to(root)):body.hex() if body is not None else None for p,body in before.items()}
        atomic_write(path,json.dumps(record).encode())
        try:
            for target,body in desired.items():
                if body is None:target.unlink(missing_ok=True)
                else:atomic_write(target,body)
            choosing=dict(record,phase='choosing',undo=dict(input=scope))
            atomic_write(path,json.dumps(choosing).encode())
        except Exception:
            recover(root,path,record);raise
        return saved


def transact(root, profile, bundle, action, config, app_values, clock, app=None):
    home = registry.profile_home(root, profile)
    team_path = checked_path(root, 'owner/team.yaml')
    config_path = checked_path(root, str((home/'config.yaml').relative_to(root)))
    team = yaml_load(team_path.read_bytes()) if team_path.exists() else {'version': 1, 'agents': {}}
    agent = team.setdefault('agents', {}).setdefault(profile, {})
    bundles = registry.ordered_grants(root, profile, config)
    old_values = legacy_values(config, bundles)
    old_values.update(registry.values(root, profile))
    previous = list(bundles)
    if action == 'connect' and bundle not in bundles: bundles.append(bundle)
    elif action == 'disconnect': bundles = [b for b in bundles if b != bundle]
    agent['apps'] = bundles
    stored = deepcopy(old_values)
    if action == 'connect': stored[bundle] = {k: deepcopy(v) for k, v in app_values.items() if not k.startswith('_')}
    packs = []
    table = registry.capabilities(bundles,config,stored)
    if app is not None and bundle not in table:table[bundle]=app
    for b in bundles:
        route = table.get(b, {}).get('route', 'sdef')
        packs.extend(table.get(b, {}).get('packs', ['mac-apps'] if route == 'sdef' else []))
    config_body = assemble_config(config_path.read_bytes() if config_path.exists() else b'',
        packs=list(dict.fromkeys(packs)), plugins=['team-kit', 'team-delegation'],
        app_settings=registry.derived_settings(config, bundles, stored))
    vault_path = checked_path(root, 'owner/vault.yaml')
    vault = yaml_load(vault_path.read_bytes()) if vault_path.exists() else {}
    draft=read_record(record_path(home,bundle),clock)
    staged=_input_scope(root,home,profile,bundle,record_path(home,bundle),draft) if draft.get('phase')=='choosing' else None
    originals={}
    if action=='connect' and staged:
        originals=_input_restore(root,home,profile,bundle,staged)
        setup=vault.get('app_setup',{}).get(profile,{})
        setup.pop(bundle,None)
        if not setup:vault.get('app_setup',{}).pop(profile,None)
        if not vault.get('app_setup'):vault.pop('app_setup',None)
    vault.setdefault('apps', {})[profile] = stored
    desired = {team_path: yaml_bytes(team), config_path: config_body}
    tools=sorted({tool for b in bundles for tool in table.get(b,{}).get('tools',[])})
    manifests,manifest_changed=app_manifests(root,home,profile,tools)
    desired.update(manifests)
    if action == 'connect': desired[vault_path] = yaml_bytes(vault)
    secret_values = app_values.get('_secrets', {}) if action == 'connect' else {}
    if secret_values:
        from hermes_facility.connection_secrets import env_bytes
        env_path = checked_path(root, str((home/'.env').relative_to(root)))
        desired[env_path] = env_bytes(env_path.read_bytes() if env_path.exists() else b'', secret_values)
    if action=='connect' and staged:
        for target in originals:desired.setdefault(target,target.read_bytes() if target.exists() else None)
    before = {str(p.relative_to(root)): store.journal_value(store.current(root,p,isinstance(body,dict))) for p,body in desired.items()}
    if action=='connect' and staged:before.update({str(p.relative_to(root)):body.hex() if body is not None else None for p,body in originals.items()})
    after = {str(p.relative_to(root)): store.fingerprint(data) for p, data in desired.items()}
    path = record_path(home, bundle)
    journal = dict(at=clock(), action=action, phase='applying', service=table.get(bundle,{}).get('service'),
                   done=list(dict.fromkeys(['enable','values',*app_values.get('setup_done',[])])),
                   undo=dict(before=before, after=after,hosts={str(p.relative_to(root)):body for p,body in desired.items() if isinstance(body,dict)}), restart_required=manifest_changed or (
                       action == 'connect' and bundle not in previous and (
                           not any(table.get(b, {}).get('route') == 'sdef' for b in previous)
                           if table.get(bundle, {}).get('route', 'sdef') == 'sdef' else
                           bool(set(table.get(bundle, {}).get('tools', [])) - {t for b in previous for t in table.get(b, {}).get('tools', [])}))))
    # The write-ahead undo record also handles a process dying during the transaction.
    atomic_write(path, json.dumps(journal).encode())
    try:
        for p, body in desired.items():
            if isinstance(body,dict):store.write(root,p,body)
            elif body is None:p.unlink(missing_ok=True)
            else:atomic_write(p,body)
        journal['phase'] = 'applied'
        atomic_write(path, json.dumps(journal).encode())
    except Exception:
        journal['phase'] = 'applying'
        recover(root, path, journal)
        raise

    return journal


def undo(root, profile, bundle, clock=time.time):
    root = Path(root).resolve()
    home = registry.profile_home(root, profile)
    path = checked_path(root, str(record_path(home, bundle).relative_to(root)))
    with locked(root / 'owner/.app-connect.lock'):
        record = recover(root, path, read_record(path, clock))
        snapshot = record.get('undo')
        if snapshot is None: return response(profile, bundle, reason='UNDO_EXPIRED')
        if record.get('phase')=='choosing':
            _cancel_input(root,home,profile,bundle,path,record)
            path.unlink()
            return response(profile,bundle)
        files = transaction_paths(root, snapshot)
        for name, expected in snapshot['after'].items():
            p = files[name]
            host=isinstance(snapshot['before'][name],dict)
            if (not host and p.is_symlink()) or store.fingerprint(store.current(root,p,host))!=expected:
                return response(profile, bundle, reason='UNDO_CONFLICT')
        record['phase'] = 'undoing'
        atomic_write(path, json.dumps(record).encode())
        recover(root, path, record)
        path.unlink()
        return response(profile, bundle)


def run(root, action, profile, bundle, *, account=None, scopes=None, default=None,
        values=None, resume=None, adapters=None, clock=time.time):
    from hermes_facility.app_setup import Adapters
    root = Path(root).resolve(); home = registry.profile_home(root, profile)
    checked_path(root, str(home.relative_to(root)))
    if not home.is_dir(): return response(profile, bundle, reason='PROFILE_MISSING')
    if action == 'undo':
        try: return undo(root, profile, catalog.connection_key(bundle), clock)
        except ValueError as error: return response(profile, bundle, reason=str(error))
    adapters = adapters or Adapters()
    bundle = catalog.connection_key(bundle)
    app = next((a for a in adapters.apps() if catalog.connection_key(a['bundle_id']) == bundle), None)
    if app is None and bundle == 'service:obsidian-notes': app = catalog.obsidian_service()
    if app is None and action == 'connect': return response(profile, bundle, reason='APP_MISSING')
    app = dict(app or {'bundle_id': bundle, 'has_sdef': False})
    app.update(catalog.entry(app))
    fields={'synology':{'api_base','link_host','user','password','sync_root'},'notion':{'token'},'obsidian_notes':{'vault'}}.get(app.get('service'),set())
    if values is not None and (not isinstance(values,dict) or set(values)-fields):
        return response(profile,bundle,reason='INVALID_ARGUMENTS')
    if scopes is not None and (not isinstance(scopes,list) or any(not isinstance(s,str) for s in scopes)):
        return response(profile,bundle,reason='SCOPE_INVALID')
    if app['route'] in ('none', 'excluded') and action == 'connect':
        return response(profile, bundle, reason='APP_UNAVAILABLE')
    try:
        path = checked_path(root, str(record_path(home, bundle).relative_to(root)))
        config_path = checked_path(root, str((home/'config.yaml').relative_to(root)))
        checked_path(root, 'owner/team.yaml'); checked_path(root, 'owner/vault.yaml')
        if path.exists():
            with locked(root / 'owner/.app-connect.lock'):
                prior = read_record(path, clock)
                if prior.get('phase') in ('applying', 'undoing', 'input_applying'): recover(root, path, prior)
                elif prior.get('phase')=='choosing':
                    _input_scope(root,home,profile,bundle,path,prior)
                    if action=='disconnect':_cancel_input(root,home,profile,bundle,path,prior)
        # All preflight choices are read-only. Even a single account requires a choice.
        config = yaml_load(config_path.read_bytes()) if config_path.exists() else {}
        record = read_record(path, clock)
        if resume=='internet_accounts' and mac_account_settings(app):
            if record.get('phase')=='choosing':
                staged=draft_values(root,profile,bundle)
                staged.pop('account',None);staged.pop('accounts',None)
                stage_values(root,profile,bundle,staged,clock)
            return wait(response(profile,bundle,steps_from(record)), 'values', reason='ACCOUNT_LOGIN_REQUIRED', **internet_accounts())
        pending = record.get('phase') == 'applied' and record.get('action') == action and not any((account is not None, scopes is not None, values is not None))
        selected = registry.values(root, profile).get(bundle, {}) if pending else (draft_values(root,profile,bundle) if record.get('phase')=='choosing' and action=='connect' else {})
        result = response(profile,bundle,steps_from(record if pending else dict(service=app.get('service'),done=selected.get('setup_done',[]))))
        result['role_hint']=registry.role_hint(root,profile)
        if action == 'connect' and not pending:
            supplied=values is not None or account is not None and app.get('scope')=='mail_accounts'
            def checkpoint():
                nonlocal supplied
                if supplied:
                    stage_values(root,profile,bundle,selected,clock)
                    supplied=False
            if app.get('scope') == 'mail_accounts':
                options = adapters.accounts(home, app)
                if account is None and selected.get('accounts'):account=selected['accounts']
                if account is None:
                    return wait(result, 'values', 'choose_account', 'CHOOSE_ACCOUNT', options=options,
                                selected=[], multi=True, other_account=False,
                                account_settings=internet_accounts())
                accounts = list(dict.fromkeys(account if isinstance(account, list) else [account]))
                if not accounts or any(not isinstance(a, str) or not a for a in accounts):
                    return wait(result, 'values', 'choose_account', 'ACCOUNT_OUT_OF_SCOPE', options=options, selected=[])
                if any(not adapters.account_allowed(home, app, a, config) for a in accounts):
                    return wait(result, 'values', 'choose_account', 'ACCOUNT_OUT_OF_SCOPE', options=options, selected=[])
                selected['accounts'] = accounts
                selected['account'] = accounts[0]  # Compatibility for adapters accepting one account.
                if any(not any(o['id'] == a for o in options) for a in accounts):
                    return wait(result, 'values', reason='ACCOUNT_LOGIN_REQUIRED', **internet_accounts())
            if app.get('service') in ('synology', 'notion', 'obsidian_notes'):
                setup = adapters.credentials(home, app, {**selected,**(values or {})}, config)
                selected.update(setup.get('values', {}))
                if not setup.get('ok'):
                    step=('login' if selected.get('api_base') and selected.get('link_host') else 'address') if app.get('service')=='synology' else 'values'
                    if step=='login':
                        selected['setup_done']=['address'];result['steps']=steps_from(dict(service='synology',done=selected['setup_done']))
                    checkpoint()
                    if step=='address' and not record:
                        previous=legacy_values(config,[bundle]).get(bundle,{})
                        setup['fields']=[dict(f, value=previous[f['id']]) if not f.get('secure') and f['id'] in ('api_base','link_host') and previous.get(f['id']) else f for f in setup.get('fields',[])]
                    return wait(result, step, 'secret_set', setup.get('reason', 'VALUES_REQUIRED'),
                                fields=setup.get('fields', []))
            checkpoint()
            if app.get('service')=='synology':
                if values and 'sync_root' in values:selected['sync_root']=values['sync_root']
                try:setup=adapters.synology(home,selected)
                except ValueError as error:
                    return wait(result,'sync_root','choose_sync_root',str(error),selected=[])
                selected.update(setup.get('values',{}))
                selected['setup_done']=['address']+(['login'] if setup.get('ok') or setup.get('next')=='choose_sync_root' else [])+(['sync_root'] if setup.get('ok') else [])
                stage_values(root,profile,bundle,selected,clock)
                result['steps']=steps_from(dict(service='synology',done=selected['setup_done']))
                if not setup.get('ok'):
                    return wait(result,'sync_root' if setup.get('next')=='choose_sync_root' else 'login',setup.get('next','secret_set'),setup.get('reason','VALUES_REQUIRED'),
                                **{k:v for k,v in setup.items() if k in ('options','selected','fields','retry_after','error_category','input_error')})
            if app.get('scope'):
                selected['_requested_scope'] = scopes or []
                try:options = adapters.scopes(home, app, selected, config)
                except ValueError as error:
                    if app.get('service')!='synology':raise
                    from hermes_facility.synology_setup import LoginError, scope_failure_hint
                    return wait(result,'login' if str(error)=='AUTH_FAILED' else 'values','secret_set' if str(error)=='AUTH_FAILED' else 'choose_scope',str(error),selected=[],hint=scope_failure_hint(error),
                                **(error.details if isinstance(error,LoginError) else {}))
                choice_fields=dict(scope=app['scope'],
                    options=[{k:v for k,v in o.items() if k in ('id','label','server_path','mac_path','disabled','needs_user','hint')} for o in options],
                    selected=[],multi=True,select_all=True,needs_default=app['scope']=='calendars',
                    account_settings=mac_account_settings(app))
                if not scopes:
                    checkpoint()
                    return wait(result, 'values', 'choose_scope', 'CHOOSE_SCOPE' if options else 'SCOPE_EMPTY',
                                **({} if options else dict(hint='고를 수 있는 항목이 없어요. 앱의 계정과 쓸 곳을 확인한 뒤 다시 골라 주세요.')),
                                **choice_fields)
                by_id={};ambiguous=set()
                for option in options:
                    key=unicodedata.normalize('NFC',option['id'])
                    if key in by_id:ambiguous.add(key)
                    else:by_id[key]=option
                scope_ids=list(dict.fromkeys(unicodedata.normalize('NFC',s) for s in scopes))
                default_id=unicodedata.normalize('NFC',default) if isinstance(default,str) else None
                if (any(s not in by_id or s in ambiguous or by_id[s].get('disabled') for s in scope_ids)
                        or (app['scope']=='calendars' or default is not None) and default_id not in scope_ids):
                    return wait(result, 'values', 'choose_scope', 'SCOPE_INVALID',
                                hint='고른 항목을 확인하지 못했어요. 목록에서 다시 골라 주세요.',**choice_fields)
                if app['scope']=='calendars' and by_id[default_id].get('writable') is False:
                    return wait(result,'values','choose_scope','SCOPE_INVALID',
                                hint='고른 기본 캘린더는 읽기 전용이에요. 일정을 만들 수 있는 캘린더를 기본으로 골라 주세요.',**choice_fields)
                selected['scope'] = []
                for scope_id in scope_ids:
                    value = by_id[scope_id]['value']
                    for item in (value if isinstance(value, list) else [value]):
                        if item not in selected['scope']: selected['scope'].append(item)
                if default: selected['default'] = by_id[default_id]['value']
        with locked(root / 'owner/.app-connect.lock'):
            # Another caller must not invalidate the choices/config while we were checking them.
            current = config_path.read_bytes() if config_path.exists() else b''
            if yaml_load(current) != config: return response(profile, bundle, reason='CONFIG_CHANGED')
            if not pending:
                record = transact(root, profile, bundle, action, config, selected, clock,app)
            result['steps'] = steps_from(record)
            result['undo_until'] = record['at'] + UNDO_SECONDS if 'undo' in record else None
        if action == 'disconnect' and not record.get('restart_required'):
            record['done'] = [id for id, _ in LABELS]
        else:
            for step in (('restart',) if action=='disconnect' else ('restart', 'permission', 'check')):
                if step in record['done']: continue
                from hermes_facility import gateway_restart
                completed = step == 'restart' and gateway_restart.completed_since(root, record.get('at'))
                if step == 'restart' and record.get('restart_required') and not completed and resume != 'gateway_restart':
                    return wait(result, step, 'gateway_restart', 'RESTART_REQUIRED')
                outcome = dict(ok=True) if completed else getattr(adapters, step)(root, home, profile, app, record, resume)
                if not outcome.get('ok'):
                    following=outcome.get('next','done')
                    following=following if isinstance(following,dict) else dict(kind=following)
                    return wait(result, step, reason=outcome.get('reason', 'CHECK_FAILED'),
                                **following)
                record['done'].append(step)
                atomic_write(path, json.dumps(record).encode())
                result['steps'] = steps_from(record)
            if action=='disconnect':record['done']=[id for id,_ in LABELS]
        atomic_write(path, json.dumps(record).encode())
        result.update(outcome='done', reason='OK', next={'kind': 'done'})
        return result
    except ValueError as error:
        reason = str(error)
        return response(profile, bundle, reason=reason if reason in ('LOCKED', 'UNSAFE_PATH', 'CONFIG_INVALID', 'AUTH_FAILED', 'PERMISSION_REQUIRED', 'SCOPE_INVALID', 'NETWORK', 'TOKEN_INVALID', 'UNDO_CONFLICT') else 'CONNECTIONS_READ_FAILED')
    except Exception:
        return response(profile, bundle, reason='CONNECTIONS_READ_FAILED')
