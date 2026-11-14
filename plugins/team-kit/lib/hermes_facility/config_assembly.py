"""Shared round-trip config assembly for hiring and app connections.

Callers own the transaction. Only this module attaches packs and serializes
config, so installing an employee and connecting an app preserve the same YAML.
"""
from contextlib import contextmanager
from copy import deepcopy
import fcntl
import json
from io import StringIO
import os
from pathlib import Path
import tempfile


CONFIG = 'config'  # profile config.yaml and plugin.yaml: Hermes reads them with hermes_yaml (YAML 1.1)
OWNER = 'owner'    # owner/ files and undo fragments: their readers use ruamel YAML 1.2


def _editor(kind):
    """The writer must parse and emit a file the way its reader reads it."""
    if kind == CONFIG:
        import hermes_yaml
        return hermes_yaml.roundtrip_yaml()
    if kind == OWNER:
        from ruamel.yaml import YAML
        return YAML()
    raise ValueError('CONFIG_INVALID')


def _read_back(kind, data):
    if kind == CONFIG:
        import hermes_yaml
        return hermes_yaml.safe_load(data)
    from ruamel.yaml import YAML
    return YAML(typ='safe').load(data)


def yaml_load(data, kind=OWNER):
    value = _editor(kind).load(data) if data else {}
    if value is None: value = {}
    if not isinstance(value, dict): raise ValueError('CONFIG_INVALID')
    return value


def yaml_bytes(value, kind=OWNER):
    """Serialize, then prove the file's own reader sees exactly `value` before anyone writes it."""
    stream = StringIO()
    _editor(kind).dump(value, stream)
    data = stream.getvalue().encode('utf-8')
    if _read_back(kind, data) != value: raise ValueError('CONFIG_INVALID')
    return data


def missing_merge(current, defaults):
    for key, value in defaults.items():
        if key not in current: current[key] = deepcopy(value)
        elif isinstance(current[key], dict) and isinstance(value, dict): missing_merge(current[key], value)
    return current


def assemble_config(before, *, defaults=None, packs=(), plugins=(), app_settings=None):
    """Pure byte composer; comments/order and unrelated/channel keys survive."""
    try:
        config = json.loads(before) if before.strip() else {}
        json_format = True
    except ValueError:
        config = yaml_load(before, CONFIG)
        json_format = False
    if not isinstance(config, dict): raise ValueError('CONFIG_INVALID')
    missing_merge(config, defaults or {})
    section = config.setdefault('plugins', {})
    enabled = section.setdefault('enabled', [])
    disabled = section.get('disabled', [])
    if not isinstance(enabled, list) or not isinstance(disabled, list): raise ValueError('CONFIG_INVALID')
    for name in plugins:
        if name not in disabled and name not in enabled: enabled.append(name)
    entries = section.setdefault('entries', {})
    for name in ('team-kit', 'team-delegation'):
        if not packs and not app_settings: continue
        plugin = entries.setdefault(name, {})
        plugin.setdefault('enabled', True)
        settings = plugin.setdefault('settings', {})
        chosen = settings.setdefault('packs', {}).setdefault('enabled', [])
        if not isinstance(chosen, list): raise ValueError('CONFIG_INVALID')
        for pack in packs:
            if pack not in chosen: chosen.append(pack)
        for key, value in (app_settings or {}).get(name, {}).items(): settings[key] = deepcopy(value)
    if app_settings:
        toolsets = config.setdefault('platform_toolsets', {})
        if not isinstance(toolsets, dict): raise ValueError('CONFIG_INVALID')
        for platform in ('slack', 'photon'):
            chosen = toolsets.setdefault(platform, [])
            if not isinstance(chosen, list): raise ValueError('CONFIG_INVALID')
            for name in plugins:
                if name not in chosen: chosen.append(name)
    routes = (defaults or {}).get('platforms', {}).get('slack', {}).get('common_router_thread_routes', {})
    if routes.get('profiles'):
        chosen = config['platforms']['slack']['common_router_thread_routes'].setdefault('profiles', [])
        for profile in routes['profiles']:
            if profile not in chosen: chosen.append(profile)
    return (json.dumps(config, ensure_ascii=False, indent=2) + '\n').encode() if json_format else yaml_bytes(config, CONFIG)


def assemble_manifest(before, default_tools, app_tools, *, required=None):
    """Tool declarations are the base policy plus capabilities chosen in the roster."""
    value=yaml_load(before,CONFIG)
    if not isinstance(default_tools,list) or not isinstance(app_tools,list):raise ValueError('MANIFEST_INVALID')
    combined=list(dict.fromkeys([*default_tools,*app_tools]))
    if any(not isinstance(t,str) or not t for t in combined):raise ValueError('MANIFEST_INVALID')
    changed=value.get('provides_tools',[])!=combined
    if changed:value['provides_tools']=combined
    for field,names in (required or {}).items():
        if not isinstance(names,list):raise ValueError('MANIFEST_INVALID')
        current=value.get(field,[])
        if not isinstance(current,list):raise ValueError('MANIFEST_INVALID')
        merged=list(dict.fromkeys([*current,*names]))
        if current!=merged:value[field]=merged;changed=True
    if not changed:return before
    return yaml_bytes(value,CONFIG)


def app_manifests(root,home,profile,tools):
    """Return transaction bytes; never write files from the composer.

    Base permissions migrate once to policy. Original manifest bytes/CAS are
    recovery metadata in the locker, not another grant or tool policy.
    """
    root=Path(root).resolve();home=Path(home).resolve()
    policy_path=checked_path(root,'owner/policy.yaml')
    policy=yaml_load(policy_path.read_bytes()) if policy_path.exists() else {}
    defaults=policy.setdefault('app_tool_defaults',{}).setdefault(profile,{})
    state_path=checked_path(root,str((home/'state/connections/manifest-bases.json').relative_to(root)))
    state=json.loads(state_path.read_bytes()) if state_path.exists() else {}
    desired={};changed=False
    from hermes_facility import plugin_store as store
    links_path=checked_path(root,'plugin-store/links.json')
    links=store.read_links(root)
    for plugin in store.PLUGINS:
        canonical=root/'plugin-store'/plugin/'plugin.yaml'
        source_manifest=yaml_load(canonical.read_bytes(),CONFIG);declared=source_manifest.get('provides_tools',[])
        host=store.host_path(root,str((home/'plugins'/plugin).relative_to(root)))
        before_host=store.snapshot(root,host)
        before=(host/'plugin.yaml').read_bytes() if (host/'plugin.yaml').exists() else None
        name=str(host.relative_to(root))
        entry=next((e for e in links['entries'] if e['path']==name),None)
        baseline=state.get(plugin)
        if baseline:
            if store.fingerprint(before)!=baseline['after']:raise ValueError('UNDO_CONFLICT')
            template=bytes.fromhex(baseline['before'])
            original_host=baseline.get('host')
            if original_host is None:
                # Journals created before host management only saved manifest bytes.
                if not baseline.get('existed',True):original_host=dict(kind='plugin_host',entries=None)
                elif 'link' in before_host:original_host=before_host
                else:
                    original_host=deepcopy(before_host)
                    original_host['entries']['plugin.yaml']=dict(file=template.hex())
        else:
            template=before if before is not None else canonical.read_bytes()
            original_host=before_host
        initial=yaml_load(template,CONFIG).get('provides_tools',[]) if (baseline and baseline.get('existed',True) or not baseline and before is not None) else []
        if not isinstance(initial,list):raise ValueError('MANIFEST_INVALID')
        if baseline and not baseline.get('existed',True) and 'host' not in baseline and defaults.get(plugin)==yaml_load(template,CONFIG).get('provides_tools',[]):
            defaults[plugin]=[]  # Earlier assembly inferred store-wide tools for a host that never existed.
        defaults.setdefault(plugin,list(initial))
        additions=[t for t in tools if t in declared]
        if plugin=='team-delegation':
            from hermes_packs.files_docs import files
            additions=[t for t in additions if t not in files.HANDLERS]
        required={k:source_manifest.get(k,[]) for k in ('provides_hooks','provides_middleware')} if additions else None
        body=assemble_manifest(template,defaults[plugin],additions,required=required)
        # No tools for this plugin means no new host. Removing the last app
        # restores the exact pre-connection topology, including full-store links.
        if not additions:
            after_host=original_host
            body=bytes.fromhex(original_host['entries']['plugin.yaml']['file']) if original_host.get('entries') else (canonical.read_bytes() if 'link' in original_host else None)
        elif body==before and 'link' in before_host:
            after_host=before_host
        else:after_host=store.overlay(root,host,body)
        original_entry=baseline['entry'] if baseline and 'entry' in baseline else deepcopy(entry)
        if baseline and 'entry' not in baseline and original_entry and original_entry['overlay']:
            original_entry['manifest_sha']=store.fingerprint(template)
        if baseline and not additions:
            restored_entry=original_entry
        elif after_host.get('entries') is None and 'link' not in after_host:
            restored_entry=None
        else:
            restored_entry=dict(path=name,plugin=plugin,overlay='link' not in after_host,manifest_sha=store.fingerprint(body))
        if entry!=restored_entry:
            if entry is not None:
                index=links['entries'].index(entry)
                if restored_entry is None:links['entries'].pop(index)
                else:links['entries'][index]=restored_entry
            elif restored_entry is not None:links['entries'].append(restored_entry)
        state[plugin]=dict(before=template.hex(),existed=baseline.get('existed',True) if baseline else before is not None,
                           after=store.fingerprint(body),host=original_host,
                           entry=original_entry)
        if after_host!=before_host:
            desired[host]=after_host;changed=True
    desired[links_path]=(json.dumps(links,ensure_ascii=False,indent=2)+'\n').encode()
    desired[policy_path]=yaml_bytes(policy)
    desired[state_path]=(json.dumps(state,ensure_ascii=False,indent=2)+'\n').encode()
    return desired,changed


def checked_path(root, name):
    """Reject escaping names and linked components before reading a transaction file."""
    root = Path(root).resolve()
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts: raise ValueError('UNSAFE_PATH')
    path = root
    for part in relative.parts:
        path = path / part
        if path.is_symlink() or path.parent.is_symlink(): raise ValueError('UNSAFE_PATH')
    return path


@contextmanager
def locked(path):
    path = Path(path)
    if path.parent.is_symlink(): raise ValueError('UNSAFE_PATH')
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('LOCKED') from None
        yield
    finally:
        os.close(fd)


def atomic_write(path, data):
    path = Path(path)
    if path.is_symlink() or path.parent.is_symlink(): raise ValueError('UNSAFE_PATH')
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
