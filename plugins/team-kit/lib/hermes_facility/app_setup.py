"""Read-only setup adapters. No root-account fallback and no implicit selections."""
import hashlib
import json
from pathlib import Path
from urllib.parse import urlsplit
from hermes_facility import app_registry as registry
from hermes_packs.mac_apps import discovery, catalog


def option(value, label):
    return dict(id=hashlib.sha256(str(value).encode()).hexdigest()[:24], label=label, value=value)


class Adapters:
    def apps(self):
        apps = discovery.scan()
        if not any(a['bundle_id'] == 'md.obsidian' for a in apps): apps.append(catalog.obsidian_service())
        return apps

    def execute(self, home, script):
        from hermes_facility.mac_executor import execute
        return execute(registry.root_of(home), script)

    def accounts(self, home, app):
        rows = self.execute(home, '''JSON.stringify(Application('com.apple.mail').accounts().map(
            a => ({id:a.id(),label:a.name(),addresses:a.emailAddresses()})))''')
        return [dict(id=str(a['id']), label=a['label'], addresses=a['addresses']) for a in rows]

    def account_allowed(self, home, app, account, config):
        # Existing ownership bounds remain separate from the app grant.
        kit = config.get('plugins', {}).get('entries', {}).get('team-kit', {}).get('settings', {})
        scopes = kit.get('personal_scopes', {})
        if not scopes.get('enabled'): return True
        from hermes_facility import team_registry
        owner = ('personal' if team_registry.has_role(registry.profile_of(home), 'personal') else
                 'company' if team_registry.has_role(registry.profile_of(home), 'work') else None)
        allowed = scopes.get(owner, {}).get('mail_accounts', []) if owner else []
        # Account ids are resolved by a read call before comparing addresses, never chosen here.
        rows = self.execute(home, "JSON.stringify(Application('com.apple.mail').accounts().map(a=>({id:a.id(),addresses:a.emailAddresses()})))")
        return any(str(a['id']) == account and a['addresses'] and
                   {str(v).casefold() for v in a['addresses']} <= {str(v).casefold() for v in allowed} for a in rows)

    def credentials(self, home, app, values, config):
        from hermes_facility import connection_checks as checks
        if app['service'] == 'obsidian_notes':
            raw = values.get('vault')
            if not raw:
                return dict(ok=False, reason='VALUES_REQUIRED', fields=[dict(id='vault', label='Obsidian 보관함 폴더', secure=False)])
            path = Path(raw).expanduser()
            if not path.is_absolute() or not path.is_dir() or path.is_symlink(): return dict(ok=False, reason='SCOPE_INVALID')
            return dict(ok=True, values=dict(vault=str(path.resolve())))
        if app['service'] == 'notion':
            secret = {'NOTION_API_KEY': values['token']} if values.get('token') else {}
            with checks.candidate_values(secret):
                if not checks.env_value(home, 'NOTION_API_KEY'):
                    return dict(ok=False, reason='VALUES_REQUIRED',
                                fields=[dict(id='token', label='Notion 비밀값', secure=True)])
                answer = checks.check_notion(home, checks.default_opener())
            return dict(ok=answer[0] == 'connected', reason=answer[1], values={'_secrets': secret},
                        fields=[dict(id='token',label='Notion 비밀값',secure=True)])
        base = values.get('api_base', '')
        host = values.get('link_host', '')
        if not base or not host:
            return dict(ok=False, reason='VALUES_REQUIRED', fields=[
                dict(id='api_base', label='시놀로지 API 주소', secure=False),
                dict(id='link_host', label='시놀로지 링크 주소', secure=False)])
        for value in (base, host if '://' in host else 'https://'+host):
            parsed = urlsplit(value)
            if parsed.scheme not in ('https', 'http') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
                return dict(ok=False, reason='FORMAT_INVALID', fields=[dict(id='api_base',label='시놀로지 API 주소',secure=False),dict(id='link_host',label='시놀로지 링크 주소',secure=False)])
        host=urlsplit(host if '://' in host else 'https://'+host).netloc
        secret = {env: values[field] for field, env in [('user', 'SYNOLOGY_DRIVE_USER'),
                  ('password', 'SYNOLOGY_DRIVE_PASSWORD')] if values.get(field)}
        # An unrelated saved credential is never selected merely because it exists.
        chosen=values.get('login_selected') is True
        with checks.candidate_values(secret):
            ready=(chosen or set(secret)=={'SYNOLOGY_DRIVE_USER','SYNOLOGY_DRIVE_PASSWORD'}) and all(
                checks.env_value(home,k) for k in ('SYNOLOGY_DRIVE_USER','SYNOLOGY_DRIVE_PASSWORD'))
        if not ready:
            return dict(ok=False, reason='VALUES_REQUIRED', values=dict(api_base=base,link_host=host),
                        fields=[dict(id='user',label='아이디',secure=False),dict(id='password',label='비밀번호',secure=True)])
        return dict(ok=True, values=dict(api_base=base, link_host=host, login_selected=True, _secrets=secret))

    def synology(self,home,selected):
        from hermes_facility import synology_setup as nas
        nas.settings(selected)
        if selected.get('sync_root'):
            return dict(ok=True,values=dict(sync_root=str(nas.sync_root(selected)),drive_root='/mydrive'))
        # Explicit credentials must prove a login before showing any sync-root choices.
        try:nas.login(home,selected)
        except ValueError as error:
            return dict(ok=False,reason=str(error),next='secret_set',fields=[dict(id='user',label='아이디',secure=False),dict(id='password',label='비밀번호',secure=True)],
                        **(error.details if isinstance(error,nas.LoginError) else {}))
        return dict(ok=False,reason='CHOOSE_SYNC_ROOT',next='choose_sync_root',options=nas.candidates(),selected=[],
                    values=dict(drive_root='/mydrive'),fields=[dict(id='sync_root',label='이 Mac의 Synology Drive 동기화 폴더',secure=False)])

    def scopes(self, home, app, selected, config):
        kind = app['scope']
        if kind == 'obsidian_folders':
            root = Path(selected['vault'])
            paths = [root] + sorted(p for p in root.rglob('*') if p.is_dir() and not p.is_symlink()
                and not any(part.startswith('.') for part in p.relative_to(root).parts))
            return [option(str(p.relative_to(root)), '보관함 전체' if p == root else str(p.relative_to(root))) for p in paths]
        if kind == 'mail_accounts':
            return [dict(id=a['id'], label=a['label'], value=a.get('addresses') or a['id']) for a in self.accounts(home, app)
                    if a['id'] in selected.get('accounts', [selected.get('account')])]
        if kind == 'note_folders':
            rows = self.execute(home, "JSON.stringify(Application('com.apple.Notes').folders().map(f=>({id:f.id(),name:f.name()})))")
            return [option(a['id'], a['name']) for a in rows if isinstance(a,dict) and isinstance(a.get('id'),str) and a['id'].strip() and isinstance(a.get('name'),str) and a['name'].strip()]
        if kind == 'calendars':
            rows = self.execute(home, '''ObjC.import('EventKit');const s=$.EKEventStore.alloc.init;
                const calendars=s.calendarsForEntityType(0), rows=[];
                for(let i=0;i<Number(calendars.count);i++){const c=calendars.objectAtIndex(i);
                    const id=ObjC.unwrap(c.calendarIdentifier), name=ObjC.unwrap(c.title);
                    if(id && name)rows.push({id:id,name:name,writable:Number(c.allowsContentModifications)});}
                JSON.stringify(rows)''')
            choices=[]
            for a in rows:
                if not (isinstance(a,dict) and isinstance(a.get('id'),str) and a['id'].strip()
                        and isinstance(a.get('name'),str) and a['name'].strip()):continue
                if a.get('writable') not in (0,1):raise ValueError('CONNECTIONS_READ_FAILED')
                writable=bool(a['writable'])
                choices.append(dict(option(a['id'],a['name']+('' if writable else ' (읽기 전용)')),writable=writable))
            return choices
        if kind == 'notion_pages':
            from hermes_packs.notion import api
            from hermes_facility.connection_checks import candidate_values
            with candidate_values(selected.get('_secrets', {})):
                result = api.request(home, 'POST', 'search', {'filter': {'property': 'object', 'value': 'page'}}, timeout=15)
            pages = result.get('results', [])
            return [option(p['id'], p.get('title') or '공유된 페이지') for p in pages if p.get('object') == 'page']
        if kind in ('folders', 'sync_folders'):
            paths = catalog.sync_folders(app)
            if app['bundle_id'] == 'com.apple.finder':
                # A native chooser is a user action in phase 2. No default folder is selected.
                for raw in selected.get('_requested_scope', []):
                    path = Path(raw).expanduser()
                    if not path.is_absolute() or not path.is_dir(): raise ValueError('SCOPE_INVALID')
                    paths.append(path.resolve())
                return [dict(id=str(p), label=p.name, value=str(p)) for p in dict.fromkeys(paths)]
            if app['service'] == 'synology':
                from hermes_facility.synology_setup import folders
                return folders(home,selected)
            return [option(str(p), p.name) for p in paths]
        return []

    def restart(self, root, home, profile, app, record, resume):
        if not record.get('restart_required'): return dict(ok=True)
        from hermes_facility import gateway_restart
        if gateway_restart.completed_since(root, record.get('at')): return dict(ok=True)
        result = gateway_restart.restart(root)
        return dict(ok=result.get('outcome') == 'done', reason=result.get('reason'), next='gateway_restart')

    def permission(self, root, home, profile, app, record, resume):
        permission = app['permission']
        if permission in ('none', 'secret', 'channel'): return dict(ok=True)
        from hermes_facility import mac_permission
        result=mac_permission.connection_step(root,'app:'+app['bundle_id'],permission,resume)
        if account_settings:=mac_permission.mac_account_settings(app):result['next']['account_settings']=account_settings
        return result

    def check(self, root, home, profile, app, record, resume):
        from hermes_facility import connection_checks as checks
        service = app['service']
        if service in ('notion', 'slack_read', 'notes_read', 'calendar_read'):
            name = {'slack_read': 'slack'}.get(service, service)
            # Existing checks retain their bounded network calls and credential handling.
            result = checks.check(root, profile, name, manual=True)
            ok = result.get('check', {}).get('state') == 'connected'
            return dict(ok=ok, reason=result.get('reason', 'CHECK_FAILED'))
        if service == 'contacts':
            from hermes_facility import mac_permission
            from hermes_packs.native_tools import contacts_app
            observation = mac_permission.run_job(root, 'judge_info', 'contacts', timeout=mac_permission.JUDGE_SECONDS)
            if observation.get('outcome') != 'granted':
                reason = 'PERMISSION_DENIED' if observation.get('outcome') == 'denied' else 'PERMISSION_REQUIRED'
                return dict(ok=False, reason=reason, next=mac_permission.permission_next('contacts', observation, reason))
            try: ok = contacts_app.connection_metadata(root).get('ok') is True
            except (ValueError, OSError): ok = False
        elif service == 'ego_browser':
            import shutil, subprocess
            executable = shutil.which('ego-browser')
            if not executable: return dict(ok=False, reason='EGO_CLI_MISSING')
            try:
                # The pack has no status/version action; never open or read a site here.
                answer = subprocess.run([executable, '--version'], stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, timeout=10, check=False)
                ok = answer.returncode == 0
            except (OSError, subprocess.SubprocessError): ok = False
        elif service=='synology':
            from hermes_facility import synology_setup as nas
            selected=registry.values(root,profile).get(app['bundle_id'],{})
            try:ok=nas.check_folders(home,selected)
            except (ValueError,OSError) as error:
                return dict(ok=False,reason='CHECK_FAILED',next=dict(kind='choose_scope',
                    hint=nas.scope_failure_hint(error,checking=True),
                    **(error.details if isinstance(error,nas.LoginError) else {})))
        elif service == 'obsidian_notes':
            from hermes_facility.app_scope import bind
            from hermes_packs.notes import obsidian_store
            with bind(home, source='obsidian'):
                obsidian_store.Store().all()
            ok = True
        elif service == 'local_files':
            choices = registry.values(root, profile).get(app['bundle_id'], {}).get('scope', [])
            ok = bool(choices) and all(Path(p).is_dir() for p in choices)
            if ok:
                for p in choices: next(iter(Path(p).iterdir()), None)
        elif service == 'apple_mail':
            selected = registry.values(root, profile).get(catalog.connection_key(app['bundle_id']), {})
            accounts = self.accounts(home, app)
            available = {str(address).casefold() for a in accounts for address in a.get('addresses', [])}
            ok = bool(selected.get('scope')) and {str(s).casefold() for s in selected['scope']} <= available
        elif app['route'] == 'sdef':
            ok = bool(self.execute(home, 'Application(' + json.dumps(app['bundle_id']) + ').name()'))
        else:
            return dict(ok=False, reason='CHECK_FAILED')
        if ok:
            import time
            from datetime import datetime, timezone
            checks.save_check(root, profile, 'app-' + app['bundle_id'], dict(state='connected', reason='APP_VERIFIED',
                verified_by='app_read', checked_at=datetime.now(timezone.utc).isoformat(), at=time.time()))
        return dict(ok=ok, reason='OK' if ok else 'CHECK_FAILED')
