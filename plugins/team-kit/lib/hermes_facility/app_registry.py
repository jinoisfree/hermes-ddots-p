"""Employee app grants: owner/team.yaml is authoritative; legacy inference never writes."""
from pathlib import Path
from hermes_packs.mac_apps.catalog import load_catalog


def enabled(block):
    return isinstance(block, dict) and block.get('enabled') is True


def root_of(home):
    home = Path(home)
    return home.parent.parent if home.parent.name == 'profiles' else home


def profile_home(root, profile):
    if not isinstance(profile, str) or not profile or '/' in profile or profile in ('.', '..'):
        raise ValueError('PROFILE_INVALID')
    return Path(root) if profile == 'default' else Path(root) / 'profiles' / profile


def read_team(root):
    from ruamel.yaml import YAML
    path = Path(root) / 'owner/team.yaml'
    if not path.exists(): return {'version': 1, 'agents': {}}
    value = YAML(typ='safe').load(path.read_text(encoding='utf-8'))
    if not isinstance(value, dict) or not isinstance(value.get('agents'), dict):
        raise ValueError('TEAM_INVALID')
    return value


def legacy_apps(config, roles=()):
    kit = config.get('plugins', {}).get('entries', {}).get('team-kit', {}).get('settings', {})
    delegation = config.get('plugins', {}).get('entries', {}).get('team-delegation', {}).get('settings', {})
    scoped = enabled(delegation.get('personal_roles'))
    states = {
        'apple_mail': (delegation.get('gmail', {}).get('mail_app_enabled') is True if 'mail_app_enabled' in delegation.get('gmail', {})
                       else delegation.get('gmail', {}).get('full_mail_tools') is True and 'work' in roles),
        'notes_read': not enabled(delegation.get('obsidian_notes')) and (enabled(kit.get('notes_read')) or (scoped and 'work' in roles)),
        'obsidian_notes': enabled(delegation.get('obsidian_notes')),
        'calendar_read': enabled(kit.get('calendar_read')) or (scoped and 'work' in roles),
        'contacts': 'work' in roles,
        'messages': 'personal' in roles,
        'slack_read': enabled(kit.get('slack_read')),
        'notion': enabled(kit.get('notion')),
        'local_files': enabled(kit.get('files')) and bool(kit.get('files', {}).get('folders')),
        'synology': enabled(kit.get('files')) and enabled(kit.get('files', {}).get('synology')),
    }
    return {bundle for bundle, item in load_catalog().items()
            if item['route'] == 'tool' and states.get(item['service'], False)}


def ordered_grants(root, profile, config=None):
    agent = read_team(root)['agents'].get(profile, {})
    if not isinstance(agent, dict): raise ValueError('TEAM_AGENT_INVALID')
    if 'apps' in agent:
        values = agent['apps']
        if not isinstance(values, list) or any(not isinstance(v, str) or not v for v in values):
            raise ValueError('TEAM_APPS_INVALID')
        return list(dict.fromkeys(values))
    if config is None:
        from hermes_facility.connections import read_yaml
        path = profile_home(root, profile) / 'config.yaml'
        config = read_yaml(path) if path.exists() else {}
    legacy = legacy_apps(config, agent.get('roles', []))
    return sorted(legacy, key=lambda b: (b != 'service:obsidian-notes', b))


def grants(root, profile, config=None):
    return set(ordered_grants(root, profile, config))


def explicit(root, profile):
    return 'apps' in read_team(root)['agents'].get(profile, {})


def connected(config, home, app):
    home = Path(home)
    root = root_of(home)
    profile = home.name if home != root else 'default'
    from hermes_packs.mac_apps.catalog import connection_key
    return connection_key(app['bundle_id']) in grants(root, profile, config)


def config_drift(root, profile, config):
    if not explicit(root, profile): return set()
    agent = read_team(root)['agents'][profile]
    tool_apps = {bundle for bundle, item in load_catalog().items() if item['route'] == 'tool'}
    return (grants(root, profile, config) ^ legacy_apps(config, agent.get('roles', []))) & tool_apps


def profile_of(home):
    home = Path(home)
    return home.name if home.parent.name == 'profiles' else 'default'


def role_hint(root,profile):
    roles=read_team(root)['agents'].get(profile,{}).get('roles',[])
    return ('읽기 전용 진단 담당이에요. 직접 연결한 앱은 고른 범위에서 쓸 수 있어요.' if 'doctor' in roles
            else '직접 연결한 앱의 도구를 고른 범위에서 쓸 수 있어요.')


def values(root, profile):
    from hermes_facility.config_assembly import yaml_load
    path = Path(root) / 'owner/vault.yaml'
    vault = yaml_load(path.read_bytes()) if path.exists() else {}
    return vault.get('apps', {}).get(profile, {})


def capabilities(bundles=(),config=None,selected_values=None):
    table = load_catalog()
    unknown = set(bundles) - table.keys()
    if unknown:
        from hermes_packs.mac_apps import discovery, catalog
        for app in discovery.scan():
            if app['bundle_id'] in unknown: table[app['bundle_id']] = catalog.entry(app)
    if any(table.get(b,{}).get('service') in ('local_files','synology') for b in bundles):
        from hermes_packs.files_docs import files
        configured=file_settings(config or {},bundles,selected_values or {},table)
        for item in table.values():
            if item.get('service') in ('local_files','synology'):item['tools']=files.tool_names(configured)
    return table


def tool_apps(name):
    """The capability catalog is also the registration map (no second allowlist)."""
    from hermes_packs.files_docs import files
    return {bundle for bundle, app in load_catalog().items() if name in app['tools'] or
            name in files.HANDLERS and app['service'] in ('local_files','synology')}


def tool_granted(home, name, config=None):
    """None means legacy installation or a tool unrelated to Mac apps."""
    home = Path(home); root = root_of(home); profile = profile_of(home)
    if not explicit(root, profile): return None
    if name == 'mac_app': return name in offered(home)
    chosen = grants(root, profile, config)
    from hermes_packs.files_docs import files
    if name in files.HANDLERS:
        return any(name in item['tools'] for b,item in capabilities(chosen,config,values(root,profile)).items() if b in chosen)
    owners = {b for b, item in capabilities(chosen).items() if name in item['tools']}
    if not owners: return None
    if name == 'gmail_direct' and not owners & grants(root, profile, config): return None  # Keep independent Google mail.
    return bool(owners & grants(root, profile, config))


def file_settings(config,bundles,selected_values,table):
    from copy import deepcopy
    files=deepcopy(config.get('plugins',{}).get('entries',{}).get('team-kit',{}).get('settings',{}).get('files',{}))
    apps=[b for b in bundles if table.get(b,{}).get('service') in ('synology','local_files')]
    files['enabled']=bool(apps);files['folders']=[]
    if apps:files.update(extra_only=False,convert=True)
    for bundle in apps:
        data=selected_values.get(bundle,{})
        for folder in data.get('scope',[]):
            if folder not in files['folders']:files['folders'].append(folder)
        if table[bundle]['service']=='synology':
            nas=files.setdefault('synology',{})
            nas.update({k:data[k] for k in ('api_base','link_host','sync_root','drive_root') if k in data})
            nas.update(enabled=True,user='SYNOLOGY_DRIVE_USER',password='SYNOLOGY_DRIVE_PASSWORD')
    if not any(table[b]['service']=='synology' for b in apps):files.setdefault('synology',{})['enabled']=False
    return files


def derived_settings(config, bundles, selected_values):
    """Assembled opt-ins only. Channels and existing account-scope policy are untouched."""
    from copy import deepcopy
    kit = deepcopy(config.get('plugins', {}).get('entries', {}).get('team-kit', {}).get('settings', {}))
    delegation = deepcopy(config.get('plugins', {}).get('entries', {}).get('team-delegation', {}).get('settings', {}))
    result = {'team-kit': {}, 'team-delegation': {}}
    catalog = capabilities(bundles)
    for service in ('notes_read', 'calendar_read', 'slack_read', 'notion'):
        connected_apps = [b for b in bundles if catalog.get(b, {}).get('service') in ((service, 'obsidian_notes') if service == 'notes_read' else (service,))]
        block = deepcopy(kit.get(service, {})); block['enabled'] = bool(connected_apps)
        if service == 'notion' and connected_apps:
            block.update(token='NOTION_API_KEY', full_api=True, writable=[v for b in connected_apps for v in selected_values.get(b, {}).get('scope', [])])
        result['team-kit'][service] = block
    result['team-kit']['files'] = file_settings(config,bundles,selected_values,catalog)
    for plugin, previous in (('team-kit', kit), ('team-delegation', delegation)):
        selected = deepcopy(previous.get('packs', {}))
        if isinstance(selected, dict) and isinstance(selected.get('enabled'), list):
            for bundle in sorted(bundles):
                app = catalog.get(bundle, {})
                for pack in app.get('packs', ['mac-apps'] if not app else []):
                    if pack not in selected['enabled']: selected['enabled'].append(pack)
            result[plugin]['packs'] = selected
    gmail = deepcopy(delegation.get('gmail', {}))
    gmail['mail_app_enabled'] = any(catalog.get(b, {}).get('service') == 'apple_mail' for b in bundles)
    result['team-delegation']['gmail'] = gmail
    obsidian = deepcopy(delegation.get('obsidian_notes', {}))
    obsidian['enabled'] = 'service:obsidian-notes' in bundles
    data = selected_values.get('service:obsidian-notes', {})
    if data.get('vault'): obsidian['vault'] = data['vault']
    result['team-delegation']['obsidian_notes'] = obsidian
    return result


class AppContext:
    """Roster wins even if a stale assembled config is passed by a running host."""
    def __init__(self, context, home):
        self._context, self._home = context, Path(home)

    def __getattr__(self, name): return getattr(self._context, name)

    def get_config(self, key, default=None):
        root = root_of(self._home); profile = profile_of(self._home)
        if not explicit(root, profile): return self._context.get_config(key, default)
        from hermes_facility.config_assembly import CONFIG, yaml_load
        path = self._home / 'config.yaml'
        config = yaml_load(path.read_bytes(), CONFIG) if path.exists() else {}
        derived = derived_settings(config, grants(root, profile, config), values(root, profile))
        plugin = getattr(self._context, 'plugin_name', '') or getattr(getattr(self._context,'manifest',None),'name','')
        # Each host only requests the settings it owns; overlapping keys are absent here.
        for name in ((plugin,) if plugin in derived else ('team-kit', 'team-delegation')):
            if key in derived[name]: return derived[name][key]
        return self._context.get_config(key, default)

    def register_tool(self, *args, **kwargs):
        name = kwargs.get('name') or (args[0] if args else None)
        if tool_granted(self._home, name) is False: return None
        if (getattr(self._context,'plugin_name','') or getattr(getattr(self._context,'manifest',None),'name',''))=='team-delegation':
            from hermes_packs.files_docs import files
            if name in files.HANDLERS:return None  # one file writer, team-kit's full pack
        handler = kwargs.get('handler')
        if handler and tool_apps(name):
            def live(arguments, **context):
                if tool_granted(self._home, name) is False:
                    import json
                    return json.dumps({'ok': False, 'error': 'APP_NOT_CONNECTED'})
                from hermes_facility.app_scope import bind
                from hermes_governance import write_policy, app_tools
                if write_policy.classify(name, arguments) != write_policy.READ and not write_policy.owner_chat(self._home, app_tools.env):
                    import json
                    return json.dumps({'ok':False,'error':'APP_OWNER_CHAT_REQUIRED'})
                with bind(self._home, source=arguments.get('source') if name in ('notes_read','apple_notes_direct_lookup','apple_notes_direct_mutation') else None):
                    return handler(arguments, **context)
            kwargs['handler'] = live
        return self._context.register_tool(*args, **kwargs)


def runtime_context(context):
    from hermes_constants import get_hermes_home
    home = Path(get_hermes_home())
    return AppContext(context, home) if explicit(root_of(home), profile_of(home)) else context


def offered(home):
    root = root_of(home); profile = profile_of(home)
    if not explicit(root, profile): return set()
    table = capabilities(grants(root, profile))
    return {tool for bundle in grants(root, profile) for tool in table.get(bundle, {}).get('tools', ['mac_app'])}
