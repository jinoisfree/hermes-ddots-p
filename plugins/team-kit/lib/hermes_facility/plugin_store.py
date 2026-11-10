"""Shared plugin host topology; manifests and link ledger join caller transactions."""
import hashlib
import json
import os
from pathlib import Path
import shutil
from hermes_facility.config_assembly import atomic_write, checked_path

PLUGINS = ('team-kit', 'team-delegation')
SKIP = {'__pycache__', '.pytest_cache', '.DS_Store'}


def relative_link(target, path):
    path.symlink_to(os.path.relpath(target, path.parent), target_is_directory=target.is_dir())


def overlay_children(source, path, link=relative_link):
    for child in source.iterdir():
        if child.name not in SKIP and child.name != 'plugin.yaml':
            link(child, path / child.name)


def host_path(root, name):
    relative = Path(name)
    valid = (relative.parts in [('plugins', p) for p in PLUGINS] or
             len(relative.parts) == 4 and relative.parts[0] == 'profiles' and
             relative.parts[2] == 'plugins' and relative.parts[3] in PLUGINS)
    if not valid or relative.is_absolute() or '..' in relative.parts:
        raise ValueError('UNSAFE_PATH')
    parent = checked_path(root, str(relative.parent))
    return parent / relative.name


def snapshot(root, path):
    """Only the managed root link or flat overlay is mutable; never follow code links."""
    path = host_path(root, str(path.relative_to(root)))
    source = root / 'plugin-store' / path.name
    if path.is_symlink():
        if path.resolve() != source.resolve(): raise ValueError('UNSAFE_PATH')
        return dict(kind='plugin_host', link=os.readlink(path))
    if not path.exists(): return dict(kind='plugin_host', entries=None)
    if not path.is_dir(): raise ValueError('UNSAFE_PATH')
    entries = {}
    for child in path.iterdir():
        if child.name in SKIP: continue
        if child.is_symlink():
            if child.name == 'plugin.yaml' or child.resolve() != (source / child.name).resolve():
                raise ValueError('UNSAFE_PATH')
            entries[child.name] = dict(link=os.readlink(child))
        elif child.name == 'plugin.yaml' and child.is_file():
            entries[child.name] = dict(file=child.read_bytes().hex())
        else: raise ValueError('UNSAFE_PATH')
    return dict(kind='plugin_host', entries=entries)


def overlay(root, path, manifest):
    source = root / 'plugin-store' / path.name
    if not (source / '__init__.py').is_file(): raise ValueError('PLUGIN_SOURCE_MISSING')
    entries = {'plugin.yaml': dict(file=manifest.hex())}
    for child in source.iterdir():
        if child.name not in SKIP and child.name != 'plugin.yaml':
            entries[child.name] = dict(link=os.path.relpath(child, path))
    return dict(kind='plugin_host', entries=entries)


def validate_host(root, path, value):
    if value.get('kind') != 'plugin_host':raise ValueError('UNSAFE_PATH')
    source = root / 'plugin-store' / path.name
    if 'link' in value:
        if (path.parent / value['link']).resolve() != source.resolve():raise ValueError('UNSAFE_PATH')
        return
    if value['entries'] is None:return
    for name,item in value['entries'].items():
        if Path(name).name != name or name in ('.','..') or name in SKIP:raise ValueError('UNSAFE_PATH')
        if 'file' in item:
            if name != 'plugin.yaml':raise ValueError('UNSAFE_PATH')
            bytes.fromhex(item['file'])
        elif name == 'plugin.yaml' or Path(os.path.normpath(str(path / item['link']))).resolve() != (source/name).resolve():
            raise ValueError('UNSAFE_PATH')


def restore_host(root, path, value):
    """Idempotent restoration also handles a process dying midway through an overlay."""
    snapshot(root, path)
    validate_host(root,path,value)
    if path.is_symlink():path.unlink()
    elif path.exists():shutil.rmtree(path)
    path.parent.mkdir(parents=True,exist_ok=True)
    if 'link' in value:path.symlink_to(value['link'],target_is_directory=True)
    elif value['entries'] is not None:
        path.mkdir()
        for name,item in value['entries'].items():
            child=path/name
            if 'file' in item:atomic_write(child,bytes.fromhex(item['file']))
            else:child.symlink_to(item['link'],target_is_directory=(root/'plugin-store'/path.name/name).is_dir())


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def current(root, path, host=False):
    return snapshot(root, path) if host else (path.read_bytes() if path.exists() else None)


def fingerprint(value):
    if value is None: return None
    return hashlib.sha256(encode(value) if isinstance(value, dict) else value).hexdigest()


def write(root, path, value):
    if isinstance(value, dict): restore_host(root, path, value)
    elif value is None: path.unlink(missing_ok=True)
    else: atomic_write(path, value)


def decode(value):
    return value if isinstance(value, dict) or value is None else bytes.fromhex(value)


def journal_value(value):
    return value if isinstance(value, dict) or value is None else value.hex()


def in_transition(actual, before, after):
    """A torn host contains only untouched or intended entries, never foreign edits."""
    if actual in (before, after): return True
    if 'link' in actual: return False
    current = actual.get('entries') or {}
    allowed = [v.get('entries') or {} for v in (before, after)]
    return all(any(entries.get(name) == item for entries in allowed) for name, item in current.items())


def check(root):
    store = root / 'plugin-store'
    data = json.loads((store / 'links.json').read_text())
    if data.get('version') != 1:
        raise ValueError('unsupported link manifest')
    declared = set()
    for item in data['entries']:
        relative = Path(item['path'])
        valid_path = (relative.parts == ('plugins', item['plugin']) or
                      len(relative.parts) == 4 and relative.parts[0] == 'profiles' and
                      relative.parts[2:] == ('plugins', item['plugin']))
        if not valid_path or relative.is_absolute() or '..' in relative.parts or item['plugin'] not in PLUGINS:
            raise ValueError('invalid managed path')
        path = root / relative
        target = store / item['plugin']
        declared.add(path)
        if item['overlay']:
            if path.is_symlink() or not path.is_dir():
                raise ValueError(f'manifest overlay missing: {path}')
            expected = {child.name for child in target.iterdir() if child.name not in SKIP}
            actual = {child.name for child in path.iterdir() if child.name not in SKIP}
            if actual != expected:
                raise ValueError(f'overlay entries differ: {path}')
            for child in target.iterdir():
                if child.name in SKIP or child.name == 'plugin.yaml':
                    continue
                alias = path / child.name
                if not alias.is_symlink() or alias.resolve() != child.resolve():
                    raise ValueError(f'overlay code link differs: {alias}')
            if hashlib.sha256((path / 'plugin.yaml').read_bytes()).hexdigest() != item['manifest_sha']:
                raise ValueError(f'profile tool manifest changed: {path}')
        elif not path.is_symlink() or path.resolve() != target.resolve():
            raise ValueError(f'plugin link differs: {path}')
    discovered = {root / 'plugins' / name for name in PLUGINS}
    discovered.update(path for name in PLUGINS for path in root.glob(f'profiles/*/plugins/{name}'))
    if discovered != declared:
        raise ValueError('installed plugin set differs from link manifest')
    return data




def read_links(root):
    """Index an existing public installation once in the caller's transaction."""
    path=checked_path(root,'plugin-store/links.json')
    if path.exists():
        value=json.loads(path.read_bytes())
        if value.get('version')!=1:raise ValueError('MANIFEST_INVALID')
        return value
    entries=[]
    for plugin in PLUGINS:
        hosts=[root/'plugins'/plugin,*sorted(root.glob('profiles/*/plugins/'+plugin))]
        for host in hosts:
            node=snapshot(root,host)
            if node.get('entries') is None and 'link' not in node:continue
            manifest=host/'plugin.yaml'
            if not manifest.is_file():raise ValueError('MANIFEST_INVALID')
            entries.append(dict(path=str(host.relative_to(root)),plugin=plugin,overlay='link' not in node,
                                manifest_sha=fingerprint(manifest.read_bytes())))
    return dict(version=1,entries=entries)
