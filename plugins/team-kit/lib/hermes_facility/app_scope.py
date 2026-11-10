"""Live app scope binding. Values come from vault; grants only from team.yaml.

The binding is internal execution context, never a tool argument. Native readers
receive the exact allowed container ids before they read content.
"""
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from hermes_facility import app_registry as registry

_BOUND = ContextVar('app_scope_binding', default=None)
_SOURCE = ContextVar('app_notes_source', default=None)


def bound_home(): return _BOUND.get()


def note_source(): return _SOURCE.get()


def resolve_notes(home, requested=None):
    choices = {'com.apple.Notes':'apple_notes', 'service:obsidian-notes':'obsidian'}
    root = registry.root_of(home); profile = registry.profile_of(home)
    if requested is not None and requested not in choices.values(): raise ValueError('APP_SOURCE_INVALID')
    if not registry.explicit(root, profile):
        if requested is not None: raise ValueError('APP_SOURCE_REQUIRES_CONNECTION')
        return None
    available = [choices[b] for b in registry.ordered_grants(root, profile) if b in choices]
    if requested is not None and requested not in available: raise ValueError('APP_NOT_CONNECTED')
    return requested or (available[0] if available else None)


def selection(home, scope):
    root = registry.root_of(home); profile = registry.profile_of(home)
    if not registry.explicit(root, profile): return None
    from hermes_packs.mac_apps.catalog import load_catalog
    table = registry.capabilities(registry.grants(root, profile)); saved = registry.values(root, profile)
    selected = []
    for bundle in sorted(registry.grants(root, profile)):
        if table.get(bundle, {}).get('scope') != scope: continue
        for value in saved.get(bundle, {}).get('scope', []):
            if value not in selected: selected.append(value)
    return selected


def current(scope):
    home = _BOUND.get()
    return selection(home, scope) if home is not None else None


@contextmanager
def bind(home, source=None):
    backend = resolve_notes(home, source)
    token = _BOUND.set(Path(home)); source_token = _SOURCE.set(backend)
    try: yield
    finally:
        _SOURCE.reset(source_token); _BOUND.reset(token)


@contextmanager
def unbound():
    token = _BOUND.set(None)
    try: yield
    finally: _BOUND.reset(token)


def mutation(td, domain, args, context):
    if domain not in ('notes','calendar'): return None
    if domain == 'notes' and note_source() == 'obsidian':
        from hermes_packs.notes import obsidian_notes
        store = obsidian_notes.disk.Store()
        if args.get('note_id'): store.read(args['note_id'])
        result = dict(args)
        if result.get('folder'): result['folder'] = store.folder(result['folder'])
        elif args.get('action') == 'create': raise ValueError('APP_SCOPE_REQUIRED')
        return result
    kind = {'notes': 'note_folders', 'calendar': 'calendars'}[domain]
    allowed = current(kind)
    if allowed is None: return None
    if not allowed: raise ValueError('APP_SCOPE_REQUIRED')
    cfg = td.personal_scopes.config(td)
    if cfg and cfg.get('invalid'): raise ValueError('APP_SCOPE_UNVERIFIED')
    metadata = td.personal_scopes.native_metadata(td, domain, args, context)
    field = 'id' if domain == 'notes' else 'identifier'
    rows = metadata['folders' if domain == 'notes' else 'calendars']
    original = metadata.get('current')
    if args.get('action') != 'create':
        if not original or original.get(field) not in allowed: raise ValueError('APP_OUT_OF_SCOPE')
    key = 'folder' if domain == 'notes' else 'calendar_id'
    named = args.get(key)
    if isinstance(named, str) and named.startswith('id:'): named = named[3:]
    if named:
        matched = [r for r in rows if r.get(field) == named or (domain == 'notes' and r.get('name') == named)]
    elif args.get('action') == 'create':
        if domain == 'calendar':
            root = registry.root_of(_BOUND.get()); profile = registry.profile_of(_BOUND.get())
            defaults = [v.get('default') for v in registry.values(root, profile).values() if v.get('default') in allowed]
            matched = [r for r in rows if r.get(field) in defaults]
        else: matched = []  # No implicit Notes folder.
    else: matched = [original] if original else []
    if len(matched) != 1 or matched[0].get(field) not in allowed: raise ValueError('APP_OUT_OF_SCOPE')
    if cfg and td.personal_scopes.current(td) in td.personal_scopes.OWNERS:
        owner = td.personal_scopes.OWNERS[td.personal_scopes.current(td)]
        for row in [matched[0]] + ([original] if original else []):
            if td.personal_scopes.scope_of(cfg, domain, row) != owner: raise ValueError('APP_ACCOUNT_OUT_OF_SCOPE')
    result = dict(args)
    result[key] = ('id:' if domain == 'notes' else '') + matched[0][field]
    return result


def require_selected(scope):
    selected = current(scope)
    if selected is not None and not selected: raise ValueError('APP_SCOPE_REQUIRED')
    return selected


def mail_allowed(home, args):
    selected = selection(home, 'mail_accounts')
    if selected is None: return None
    account = str(args.get('account') or '').casefold()
    return bool(account) and account in {str(a).casefold() for a in selected}


def notion_request(method, path, body, send):
    """Enforce chosen page ancestry before a content operation, including raw API calls."""
    import re
    selected = require_selected('notion_pages')
    if selected is None: return send(method, path, body)
    allowed = {str(v).replace('-', '').lower() for v in selected}
    def ident(value):
        value = str(value).replace('-', '').lower()
        if not re.fullmatch(r'[0-9a-f]{32}', value): raise ValueError('APP_SCOPE_UNVERIFIED')
        return value
    def member(kind, value):
        seen = set()
        for _ in range(20):
            value = ident(value)
            if value in allowed: return True
            if value in seen: return False
            seen.add(value)
            with unbound(): data = send('GET', kind + '/' + value, None)
            parent = data.get('parent') or {}; parent_kind = parent.get('type')
            kind = {'page_id': 'pages', 'block_id': 'blocks', 'database_id': 'databases',
                    'data_source_id': 'data_sources'}.get(parent_kind)
            if not kind: return False
            value = parent.get(parent_kind)
        return False
    route = path.lstrip('/').split('?')[0].split('/')
    if route[0] == 'search':
        rows = []
        for value in sorted(allowed):
            with unbound(): row = send('GET', 'pages/' + value, None)
            query = str((body or {}).get('query') or '').casefold()
            if not query or query in __import__('json').dumps(row.get('properties', {}), ensure_ascii=False).casefold(): rows.append(row)
        return dict(object='list', results=rows, has_more=False, next_cursor=None)
    if route[0] == 'users': return send(method, path, body)
    if len(route) > 1 and route[0] in ('pages', 'blocks', 'databases', 'data_sources'):
        if not member(route[0], route[1]): raise ValueError('APP_OUT_OF_SCOPE')
    elif method == 'POST' and route[0] in ('pages', 'databases', 'data_sources'):
        parent = (body or {}).get('parent') or {}
        kinds = {'page_id': 'pages', 'database_id': 'databases', 'data_source_id': 'data_sources'}
        key = next((k for k in kinds if parent.get(k)), None)
        if not key or not member(kinds[key], parent[key]): raise ValueError('APP_OUT_OF_SCOPE')
    else: raise ValueError('APP_SCOPE_UNVERIFIED')
    return send(method, path, body)
