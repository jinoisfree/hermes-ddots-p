"""One private, locked app undo ledger per employee; legacy journals migrate once."""
from contextlib import contextmanager
from contextvars import ContextVar
from copy import deepcopy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import threading
import time
import uuid

RETENTION = 86400
IMMEDIATE = 1800
MAX_ENTRIES = 100
_ACTIVE = ContextVar('app_undo_transaction', default=None)
_LOCK = threading.RLock()


class LedgerError(ValueError): pass


def path_for(home): return Path(home) / 'state/app-undo.json'


def legacy_paths(home):
    from hermes_facility.app_registry import root_of
    from hermes_facility.app_registry import read_team, profile_of
    from hermes_facility.config_assembly import yaml_load
    paths = [Path(home) / 'state/notion-rollback.json', Path(home) / 'state/personal-work-rollback.json']
    cfg_path = Path(home) / 'config.yaml'
    cfg = yaml_load(cfg_path.read_bytes()) if cfg_path.exists() else {}
    roles_on = cfg.get('plugins', {}).get('entries', {}).get('team-delegation', {}).get('settings', {}).get('personal_roles', {}).get('enabled') is True
    role = 'work' if roles_on else 'personal'
    agents = read_team(root_of(home)).get('agents', {})
    if role in agents.get(profile_of(home), {}).get('roles', []):
        paths.append(root_of(home) / 'shared/personal-work-rollback.json')
    return paths


def _parse(data, default_kind):
    if not isinstance(data, dict) or data.get('version') not in (1, 2, 3) or not isinstance(data.get('entries'), list):
        raise LedgerError('APP_UNDO_INVALID')
    entries = []
    for raw in data['entries']:
        if not isinstance(raw, dict) or not isinstance(raw.get('created_at'), (int, float)):
            raise LedgerError('APP_UNDO_INVALID')
        row = deepcopy(raw)
        row.setdefault('journal_kind', default_kind)
        if not isinstance(row['journal_kind'], str): raise LedgerError('APP_UNDO_INVALID')
        entries.append(row)
    return entries


def _read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream: return json.load(stream)


@contextmanager
def ledger(path, *, legacy=(), clock=None):
    """Hold the lock through mutation and snapshot publication; nested calls share it."""
    clock = clock or time.time
    path = Path(path)
    if path.is_symlink() or path.parent.is_symlink(): raise OSError('APP_UNDO_UNSAFE')
    key = str(path.absolute())
    active = _ACTIVE.get()
    if active and key == active[0]:
        yield active[1], active[2]
        return
    with _LOCK:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        lock = None
        try:
            lock = os.open('app-undo.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            fcntl.flock(lock, fcntl.LOCK_EX)
            if path.exists():
                raw = _read(path)
                default = 'personal' if raw.get('version') == 2 else 'notion'
                entries = _parse(raw, default)
                migrations = raw.get('migrations', {})
                if not isinstance(migrations, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k,v in migrations.items()):
                    raise LedgerError('APP_UNDO_INVALID')
                migrations = dict(migrations)
                baselines=raw.get('baselines',{})
                if not isinstance(baselines,dict):raise LedgerError('APP_UNDO_INVALID')
            else: entries = []; migrations = {}; baselines={}
            # Validate every source before publishing or deleting any old file.
            sources = []
            for old in dict.fromkeys(Path(p) for p in legacy):
                if old == path or not (old.exists() or old.is_symlink()): continue
                if old.is_symlink() or old.parent.is_symlink(): raise OSError('APP_UNDO_UNSAFE')
                value = _read(old)
                kind = 'notion' if old.name.startswith('notion-') else 'personal'
                if old.name=='google-calendar-original-colors.json':
                    if not isinstance(value,dict) or any(not isinstance(k,str) or not isinstance(v,dict) or
                        not isinstance(v.get('at'),str) or any(v.get(f) is not None and not isinstance(v[f],str)
                        for f in ('colorId','backgroundColor','foregroundColor')) for k,v in value.items()):
                        raise LedgerError('APP_UNDO_INVALID')
                    colors=baselines.setdefault('calendar_colors',{})
                    if not isinstance(colors,dict):raise LedgerError('APP_UNDO_INVALID')
                    for cid,original in value.items():colors.setdefault(cid,deepcopy(original))
                    imported=[]  # first-ever colors are retained independently of the undo window
                else:imported = _parse(value, kind)
                stamp = hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
                if migrations.get(str(old)) != stamp: entries.extend(imported)
                migrations[str(old)] = stamp
                sources.append((old, old.read_bytes()))
            now = clock()
            entries = [e for e in entries if 0 <= now - e['created_at'] < RETENTION]
            data = {'version': 3, 'entries': entries[-MAX_ENTRIES:], 'migrations': migrations,'baselines':baselines}
            def save():
                now = clock()
                data['entries'] = [e for e in data['entries'] if 0 <= now - e['created_at'] < RETENTION][-MAX_ENTRIES:]
                temp = 'app-undo.tmp-' + uuid.uuid4().hex
                try:
                    fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=directory)
                    with os.fdopen(fd, 'w') as stream:
                        json.dump(data, stream, ensure_ascii=False); stream.flush(); os.fsync(stream.fileno())
                    os.replace(temp, path.name, src_dir_fd=directory, dst_dir_fd=directory)
                    os.fsync(directory)
                finally:
                    try: os.unlink(temp, dir_fd=directory)
                    except FileNotFoundError: pass
            if sources:
                # Keep a durable import identity if a crash interrupts source deletion.
                # On an ordinary failure restore every old file before refusing startup.
                save()
                try:
                    for old, original in sources: old.unlink()
                except OSError:
                    from hermes_facility.config_assembly import atomic_write
                    for old, original in sources:
                        if not old.exists(): atomic_write(old, original)
                    raise
            token = _ACTIVE.set((key, data, save))
            try: yield data, save
            finally: _ACTIVE.reset(token)
        finally:
            if lock is not None: os.close(lock)
            os.close(directory)


@contextmanager
def component(path, slot, publish):
    """A composite operation owns its child changes inside the same locked row."""
    active=_ACTIVE.get()
    if active is None or active[0]!=str(Path(path).absolute()):raise LedgerError('APP_UNDO_LOCK_REQUIRED')
    data={'version':3,'entries':slot.setdefault('changes',[]),
          'baselines':active[1]['baselines'],'migrations':active[1]['migrations']}
    def save():
        slot['changes']=data['entries'];publish()
    token=_ACTIVE.set((active[0],data,save))
    try:yield
    finally:
        _ACTIVE.reset(token)


@contextmanager
def partition(path, kind, *, legacy=(), clock=None):
    with ledger(path, legacy=legacy, clock=clock) as (all_data, publish):
        selected = [dict(e) for e in all_data['entries'] if e['journal_kind'] == kind]
        for e in selected: e.pop('journal_kind', None)
        data = {'version': 2 if kind == 'personal' else 1, 'scopes': {}, 'entries': selected}
        def save():
            other = [e for e in all_data['entries'] if e['journal_kind'] != kind]
            all_data['entries'] = other + [dict(e, journal_kind=kind) for e in data['entries']]
            publish()
        yield data, save


def authorization(entry, conversation, *, approved=False, clock=None):
    age = (clock or time.time)() - entry['created_at']
    if entry.get('app_conversation',entry.get('conversation')) != conversation: return 'OTHER_CONVERSATION'
    if age < 0 or age >= RETENTION or entry.get('consumed'): return 'UNDO_EXPIRED'
    return 'OK' if age < IMMEDIATE or approved else 'UNDO_APPROVAL_REQUIRED'


def append(home, entry, *, kind, clock=None):
    with partition(path_for(home), kind, legacy=legacy_paths(home), clock=clock) as (data, save):
        added=dict(key=uuid.uuid4().hex,created_at=(clock or time.time)(),consumed=False,**entry)
        data['entries'].append(added)
        save()
        return added


def progress(home,entry,**fields):
    with ledger(path_for(home),legacy=legacy_paths(home)) as (data,save):
        stored=next((row for row in data['entries'] if row.get('key')==entry['key']),None)
        if stored is None:raise LedgerError('APP_UNDO_RECORD_MISSING')
        entry.update(fields);stored.update(fields);save()
