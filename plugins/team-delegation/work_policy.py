"""Work publication scope, independent of secretary account ownership (personal_scopes)."""
import json
import os
from pathlib import Path
import sqlite3

ERROR = 'PRIVATE_WORK_NOTION_REFUSED'


def shared_pages(common_id,path=None):
    path=Path(path or os.environ.get('HERMES_COMMON_WORK_DB') or Path.home()/'.hermes/shared/common-work-links.sqlite3')
    if not path.exists():return []
    with sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True) as conn:
        if 'scope' not in {r[1] for r in conn.execute('PRAGMA table_info(common_work)')}:return []
        return [r[0] for r in conn.execute("SELECT k.external_id FROM knowledge_refs k JOIN common_work w USING(common_id) WHERE w.common_id=? AND w.scope='shared' AND k.ref_type='notion_page' AND k.unlinked_at IS NULL",(common_id,))]


def permitted(item):
    if item.get('scope') == 'private':
        return {**item,'knowledge_refs':[r for r in item.get('knowledge_refs',[]) if r['ref_type']!='notion_page']}
    return item


def notion_problem(args, path=None):
    """Read-only guard, before reads, uploads or any network write. Includes detached private pages."""
    path = Path(path or os.environ.get('HERMES_COMMON_WORK_DB') or Path.home()/'.hermes/shared/common-work-links.sqlite3')
    if not path.exists():return None
    with sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True) as conn:
        if 'scope' not in {r[1] for r in conn.execute('PRAGMA table_info(common_work)')}:return None
        private = {r[0] for r in conn.execute("SELECT common_id FROM common_work WHERE scope='private'")}
        pages = {r[0].replace('-','').lower() for r in conn.execute("SELECT k.external_id FROM knowledge_refs k JOIN common_work w USING(common_id) WHERE w.scope='private' AND k.ref_type='notion_page' AND (k.unlinked_at IS NULL OR k.unlink_reason='owner_scope_private')")}
        notes = {r[0] for r in conn.execute("SELECT s.source_id FROM source_links s JOIN common_work w USING(common_id) WHERE w.scope='private' AND s.domain='notes'")}
    raw=json.dumps(args,ensure_ascii=False,sort_keys=True)
    compact=raw.replace('-','').lower()
    if any(cid in raw for cid in private) or any(pid in compact for pid in pages) or any(sid in raw or (sid.startswith('obsidian:') and sid[9:] in raw) for sid in notes):
        return ERROR
    return None
