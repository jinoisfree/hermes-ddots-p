"""Portable linked-work text and per-task deadlines, without service access."""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import json
from pathlib import Path
import re
import os
import tempfile
import unicodedata
import difflib

import deadline_time as dates

TASK = re.compile(r'^\s*(?:[-*]\s*)?(?:(\[[ xX]\])|([☐☑✅]))\s*(.+)$')


def normalized(value):
    return ''.join(c for c in unicodedata.normalize('NFKC', str(value)).casefold() if c.isalnum())


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()


def rich_text(block):
    return ''.join(t.get('plain_text', t.get('text', {}).get('content', ''))
                   for t in block.get('rich_text', []))


def task(text, *, done=False, identifier=None, now=None):
    parts = str(text).strip().split(' | ', 1)
    name = parts[0].strip()
    due_text = parts[1] if len(parts) > 1 else name
    try:
        due = dates.extract(due_text, now=now, required=False)
        ambiguous = False
    except ValueError:
        due, ambiguous = None, True
    if len(parts) == 1 and due:
        name = dates.DEADLINE.sub('', name).strip(' :：,|까지') or parts[0].strip()
    return {'text': name, 'due': due, 'done': bool(done),
            **({'source_id': identifier} if identifier else {}), **({'ambiguous': True} if ambiguous else {})}


def semantic(content):
    return {'title': str(content.get('title') or '').strip(),
            'body': str(content.get('body') or '').strip(),
            'tasks': [{k: row.get(k) for k in ('text', 'due', 'done', 'ambiguous') if k in row}
                      for row in content.get('tasks', [])]}


def from_text(title, text, *, now=None, due=None):
    tasks, body = [], []
    for line in str(text or '').splitlines():
        match = TASK.match(line)
        if match:
            tasks.append(task(match[3], done=match[1] in {'[x]', '[X]'} or match[2] in {'☑', '✅'}, now=now))
        elif line.startswith('다음 마감:'):
            due = dates.extract(line, now=now, required=False)
        elif line not in {'[업무 본문]', '[할 일]'}:
            body.append(line)
    if len(tasks) == 1 and not tasks[0].get('due') and due:
        tasks[0]['due'] = dates.canonical(due)
    return semantic({'title': title, 'tasks': tasks, 'body': '\n'.join(body)})


def render(content):
    rows = ['[업무 본문]', content.get('body') or '', '[할 일]']
    for row in content.get('tasks', []):
        rows.append(('[x] ' if row['done'] else '[ ] ') + row['text'] +
                    (' | ' + row['due'] if row.get('due') else ''))
    return '\n'.join(rows)


def next_due(content):
    return min((r['due'] for r in content.get('tasks', []) if r.get('due') and not r.get('done')), default=None)


def reconcile(previous, incoming, *, reserved=()):
    """Keep task identity across edits; an unmatched replacement keeps its old positional identity."""
    out = [dict(row) for row in incoming]
    by_id = {r['source_id']: r['key'] for r in previous if r.get('source_id') and r.get('key')}
    for row in out:
        if row.get('source_id') in by_id:
            row['key'] = by_id[row['source_id']]
    old_names = [normalized(row['text']) for row in previous]
    new_names = [normalized(row['text']) for row in out]
    matcher = difflib.SequenceMatcher(a=old_names, b=new_names, autojunk=False)
    for opcode, i, j, k, end in matcher.get_opcodes():
        if opcode == 'equal' or (opcode == 'replace' and j-i == end-k):
            for old, new in zip(previous[i:j], out[k:end]):
                if old.get('key') and not new.get('key'):
                    new['key'] = old['key']
    used = {r.get('key') for r in previous} | set(reserved)
    for index, row in enumerate(out):
        if 'key' not in row:
            key = digest([row['text'], index, sorted(k for k in used if k)])[:24]
            row['key'] = key
            used.add(key)
    return out


def save(path, data):
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError('sync_state_symlink')
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.work-sync-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, ensure_ascii=False, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextmanager
def ledger(home, name):
    folder = Path(home)/'state'
    path, lock = folder/(name+'.json'), folder/(name+'.lock')
    if any(p.is_symlink() for p in (folder, path, lock)):
        raise ValueError('sync_state_symlink')
    folder.mkdir(parents=True, exist_ok=True)
    with lock.open('a') as stream:
        os.chmod(lock, 0o600)
        fcntl.flock(stream, fcntl.LOCK_EX)
        state = json.loads(path.read_text()) if path.exists() else {'version': 1, 'works': {}}
        if state.get('version') != 1 or not isinstance(state.get('works'), dict):
            raise ValueError('sync_state_corrupt')
        yield path, state
