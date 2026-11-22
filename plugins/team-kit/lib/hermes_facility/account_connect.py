"""Employee-local account opt-outs using the existing app write-ahead journal and undo."""
import json
from pathlib import Path
import time

from hermes_facility import app_connect as app, app_registry as registry
from hermes_facility.config_assembly import CONFIG, atomic_write, checked_path, locked, yaml_bytes, yaml_load
from hermes_facility.connections import ACCOUNT_IDS, ACCOUNT_SWITCHES, find_connection, service_enabled


def record_path(home, connection):
    return Path(home)/'state/connections'/('account-'+app.digest(connection.encode())[:24]+'.json')


def undo_available(home, connection, clock=time.time):
    path=record_path(home,connection)
    if not path.exists() or path.is_symlink():return False
    record=json.loads(path.read_bytes())
    return 'undo' in record and record.get('phase')=='applied' and clock()<record['at']+app.UNDO_SECONDS


def string_list(value):
    if isinstance(value,str):value=json.loads(value)
    if value is None:return []
    if not isinstance(value,list) or any(not isinstance(v,str) for v in value):raise ValueError('CONFIG_INVALID')
    return list(value)


def set_enabled(config, service, enabled):
    path=ACCOUNT_SWITCHES[service]; branch=config
    for key in path[:-1]:branch=branch.setdefault(key,{})
    if service=='instagram':
        names=string_list(branch.get(path[-1]))
        branch[path[-1]]=list(dict.fromkeys([*names,'instagram-dm'])) if enabled else [n for n in names if n!='instagram-dm']
    else:branch[path[-1]]=enabled
    if service=='google':
        skills=config.setdefault('skills',{})
        disabled=string_list(skills.get('disabled'))
        if not enabled and 'google-workspace' not in disabled:
            disabled.append('google-workspace');branch['off_added_skills']=['google-workspace']
        elif enabled:
            added=string_list(branch.pop('off_added_skills',[]))
            disabled=[s for s in disabled if s not in added]
        skills['disabled']=disabled


def run(root, action, profile, connection, *, clock=time.time):
    result=dict(profile=profile,connection=connection,outcome='refused',reason='INVALID_ARGUMENTS')
    if connection not in ACCOUNT_IDS or action not in {'connect','disconnect','undo'}:return result
    root=Path(root).resolve()
    try:
        ctx=find_connection(root,profile,connection)
        if not ctx or ctx.row.get('group')!='account':return result
        home=ctx.home;path=checked_path(root,str(record_path(home,connection).relative_to(root)))
        if action=='undo':
            reply=app.undo(root,profile,connection,clock,journal_path=path)
            reply.pop('app',None);return dict(reply,connection=connection)
        target=checked_path(root,str((home/'config.yaml').relative_to(root)))
        with locked(root/'owner/.app-connect.lock'):
            record=app.recover(root,path,app.read_record(path,clock))
            before=target.read_bytes()
            config=yaml_load(before,CONFIG)
            enabled=action=='connect';service=ACCOUNT_IDS[connection]
            if service_enabled(config,service)==enabled:
                return dict(result,outcome='done',reason='UNCHANGED')
            set_enabled(config,service,enabled)
            body=yaml_bytes(config,CONFIG);name=str(target.relative_to(root))
            journal=dict(at=clock(),action=action,phase='applying',done=[],restart_required=True,
                undo=dict(before={name:before.hex()},after={name:app.digest(body)}))
            app.write_transaction(root,path,journal,{target:body})
        return dict(result,outcome='waiting',reason='RESTART_REQUIRED',undo_until=clock()+app.UNDO_SECONDS,
            next=dict(kind='gateway_restart'))
    except ValueError as error:
        reason=str(error)
        return dict(result,outcome='failed',reason=reason if reason in {'UNDO_CONFLICT','LOCKED','UNSAFE_PATH','CONFIG_INVALID'} else 'CONNECTIONS_READ_FAILED')
    except (OSError,TypeError,KeyError):
        return dict(result,outcome='failed',reason='WRITE_FAILED')
