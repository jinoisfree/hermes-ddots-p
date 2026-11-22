"""Read-only setup adapters. No root-account fallback and no implicit selections."""
import hashlib
import json
import os
from pathlib import Path
from hermes_facility import app_registry as registry
from hermes_facility import path_form
from hermes_packs.mac_apps import discovery, catalog


def option(value, label):
    return dict(id=hashlib.sha256(str(value).encode()).hexdigest()[:24], label=label, value=value)


FINDER_LIMIT = 300
FINDER_PACKAGES = {'.app', '.bundle', '.framework', '.photoslibrary',
                   '.musiclibrary', '.tvlibrary', '.pkg', '.plugin'}


def finder_scopes(selected, home=None):
    """List folder names only; preserve saved choices beyond the bounded tree."""
    from hermes_facility import synology_setup
    home = Path.home() if home is None else Path(home)
    selected.pop('_scope_hint', None)

    def eligible(path):
        try:
            return (not path.name.startswith('.') and path.suffix.casefold() not in FINDER_PACKAGES
                    and not any(p.is_symlink() for p in (path, *path.parents)) and path.is_dir())
        except OSError:
            return False

    def children(path):
        if not eligible(path): return []
        try:
            with os.scandir(path) as entries:
                paths = [Path(entry.path) for entry in entries]
        except OSError:
            return []
        return sorted((p for p in paths if eligible(p)), key=lambda p: (p.name.casefold(), p.name))

    try:
        roots = [Path(row['id']) for row in synology_setup.candidates(home)]
    except OSError:
        roots = []
    roots.extend(children(home / 'Library/CloudStorage'))
    icloud = home / 'Library/Mobile Documents/com~apple~CloudDocs'
    roots.append(icloud)
    roots = list(dict.fromkeys(p for p in roots if eligible(p)))
    rows = []

    def label(path):
        for root in roots:
            if path.is_relative_to(root):
                return ' › '.join(['iCloud Drive' if root == icloud else root.name,
                                   *path.relative_to(root).parts])
        return path.name

    def visit(path, depth):
        rows.append((path, depth))
        if depth < 2:
            for child in children(path): visit(child, depth + 1)

    for root in roots: visit(root, 0)
    # Allocate shallower rows across all roots before restoring display order.
    chosen = {p for p, depth in sorted(rows, key=lambda row: row[1])[:FINDER_LIMIT]}
    paths = {path_form.normal(p): p for p, depth in rows if p in chosen}
    for raw in selected.get('scope', []):
        path = Path(raw)
        try:
            if path.is_absolute() and path.is_dir():
                paths.setdefault(path_form.normal(path), path)
        except OSError:
            continue
    # A native chooser is a user action. Keep its existing explicit-path contract.
    for raw in selected.get('_requested_scope', []):
        path = Path(raw).expanduser()
        if not path.is_absolute() or not path.is_dir(): raise ValueError('SCOPE_INVALID')
        path = path.resolve()
        paths.setdefault(path_form.normal(path), path)
    if len(rows) > FINDER_LIMIT:
        selected['_scope_hint'] = '폴더가 많아 일부만 보여요. 위 폴더를 고르면 그 안의 폴더도 함께 쓸 수 있어요.'
    elif not paths:
        selected['_scope_hint'] = '서버에서 고를 수 있는 폴더를 찾지 못했어요. 서버 Mac에 Synology Drive나 iCloud Drive 동기화 폴더가 있는지 확인해 주세요.'
    if 'scope' in selected:
        selected['scope'] = list(dict.fromkeys(path_form.normal(raw) for raw in selected['scope']))
    return [dict(id=key, label=path_form.normal(label(path)), value=key)
            for key, path in paths.items()]


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
                                fields=[dict(id='token', label='Notion 로그인 열쇠', secure=True)])
                answer = checks.check_notion(home, checks.default_opener())
            return dict(ok=answer[0] == 'connected', reason=answer[1], values={'_secrets': secret},
                        fields=[dict(id='token',label='Notion 로그인 열쇠',secure=True)])
        from hermes_facility import synology_setup as nas
        from hermes_packs.files_docs import files
        base=values.get('api_base');host=values.get('link_host')
        bad=files.address_problems(base,host)
        if bad:
            return dict(ok=False,reason='ADDRESS_INVALID',fields=nas.address_fields(values))
        base=base.rstrip('/')
        secret = {env: values[field] for field, env in [('user', 'SYNOLOGY_DRIVE_USER'),
                  ('password', 'SYNOLOGY_DRIVE_PASSWORD')] if values.get(field)}
        # An unrelated saved credential is never selected merely because it exists.
        chosen=values.get('login_selected') is True
        with checks.candidate_values(secret):
            ready=(chosen or set(secret)=={'SYNOLOGY_DRIVE_USER','SYNOLOGY_DRIVE_PASSWORD'}) and all(
                checks.env_value(home,k) for k in ('SYNOLOGY_DRIVE_USER','SYNOLOGY_DRIVE_PASSWORD'))
        if not ready:
            return dict(ok=False, reason='VALUES_REQUIRED', values=dict(api_base=base,link_host=host),
                        fields=[dict(id='user',label='아이디',secure=False,**({'value':values['_username']} if values.get('_username') else {})),dict(id='password',label='비밀번호',secure=True)])
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

    def obsidian_vaults(self, user_home=None):
        user_home=Path.home() if user_home is None else Path(user_home)
        path=user_home/'Library/Application Support/obsidian/obsidian.json'
        try:
            raw=json.loads(path.read_text())
            vaults=raw['vaults']
            if not isinstance(vaults,dict):return []
            paths=[]
            for value in vaults.values():
                if not isinstance(value,dict) or not isinstance(value.get('path'),str):continue
                folder=Path(value['path'])
                if folder.is_absolute() and folder.is_dir() and not folder.is_symlink():paths.append(folder)
            return [option(str(p),p.name) for p in dict.fromkeys(paths)]
        except (OSError,ValueError,KeyError,TypeError):return []

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
            if app['bundle_id'] == 'com.apple.finder':
                return finder_scopes(selected)
            paths = catalog.sync_folders(app)
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
