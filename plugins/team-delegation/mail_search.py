"""Bounded, incremental local search of Mail.app bodies and attachment names.

Metadata is always searched in full. The private cache contains no executable instructions;
it is outside sync's allowlist, never a source of memory/learning and never sent as a body.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import sqlite3
import time

INDEX_SECONDS = 10
DETAIL_TIMEOUT = 3
MAX_DETAILS = 24
RETRY_SECONDS = 300
TIMEOUT_RETRY_SECONDS = 7 * 24 * 3600


def is_timeout(error):
    return bool(error and ('TimeoutExpired' in error or 'AppleEventTimeout' in error))


class SearchResults(list):
    def __init__(self, items, coverage):
        super().__init__(items)
        self.coverage = coverage


def query_parts(query):
    """AND words/phrases, OR groups and common explicit fields; reject unknown operators."""
    groups, since = [[]], 0
    fields = {'from': 'from', 'subject': 'subject', 'body': 'body', 'filename': 'attachment_name'}
    try:
        tokens = shlex.split(str(query or ''))
    except ValueError as exc:
        raise ValueError('MAIL_APP_QUERY_INVALID_QUOTES') from exc
    for token in tokens:
        if token == 'AND':
            continue
        if token == 'OR':
            if not groups[-1]:
                raise ValueError('MAIL_APP_QUERY_INVALID_OR')
            groups.append([])
            continue
        if token.startswith('newer_than:'):
            import re
            match = re.fullmatch(r'newer_than:(\d{1,3})([dhmy])', token)
            if not match:
                raise ValueError('MAIL_APP_QUERY_UNSUPPORTED_OPERATOR')
            since = int(time.time()) - int(match[1]) * {'h': 3600, 'd': 86400, 'm': 30*86400, 'y': 365*86400}[match[2]]
            continue
        if token.lower() == 'in:inbox':
            continue
        if token.startswith('-') or token.startswith('(') or token.endswith(')'):
            raise ValueError('MAIL_APP_QUERY_UNSUPPORTED_OPERATOR')
        field, sep, word = token.partition(':')
        if sep:
            if field not in fields or not word:
                raise ValueError('MAIL_APP_QUERY_UNSUPPORTED_OPERATOR')
            groups[-1].append((fields[field], word.casefold()))
        elif token:
            groups[-1].append(('any', token.casefold()))
    if len(groups) > 1 and not groups[-1]:
        raise ValueError('MAIL_APP_QUERY_INVALID_OR')
    return groups, since


def matched_fields(row, cached, groups):
    values = {'from': row.get('from', ''), 'subject': row.get('subject', '')}
    if cached:
        values.update(body=cached['body'], attachment_name='\n'.join(cached['attachments']))
    values = {k: str(v).casefold() for k, v in values.items()}
    matched = set()
    for group in groups:
        found = set()
        for field, term in group:
            hits = {k for k, text in values.items() if (field == 'any' or field == k) and term in text}
            if not hits:
                break
            found |= hits
        else:
            matched |= found
            if not group:
                return []
    return sorted(matched) if matched else None


def signature(row, account_id):
    return hashlib.sha256(json.dumps([account_id, row['id'], row['ts'], row.get('from'), row.get('subject')],
                                     ensure_ascii=False).encode()).hexdigest()


@contextmanager
def index_lock(root, account):
    """One index writer per account; readers and Mail's read-only watch never wait."""
    root = _cache_root(root)
    fd = os.open(root / (_stem(account) + '.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def _stem(account):
    return hashlib.sha256(account.casefold().encode()).hexdigest()[:24]


def _cache_root(root):
    root = Path(root)
    if root.is_symlink():
        raise ValueError('MAIL_APP_SEARCH_CACHE_UNSAFE')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    return root


@contextmanager
def cache_db(root, account):
    root = _cache_root(root)
    db = None
    try:
        path = root / (_stem(account) + '.sqlite3')
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
        os.close(fd)
        db = sqlite3.connect(path, timeout=0.1)
        db.execute('PRAGMA journal_mode=DELETE')
        db.execute('CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, signature TEXT NOT NULL, '
                   'body TEXT, attachments TEXT, retry_after REAL NOT NULL DEFAULT 0, error TEXT)')
        if 'error' not in {r[1] for r in db.execute('PRAGMA table_info(messages)')}:
            db.execute('ALTER TABLE messages ADD COLUMN error TEXT')
        # Persist the applied interval so old timeout rows migrate exactly once.
        if 'retry_seconds' not in {r[1] for r in db.execute('PRAGMA table_info(messages)')}:
            db.execute('ALTER TABLE messages ADD COLUMN retry_seconds REAL NOT NULL DEFAULT 300')
        db.execute("UPDATE messages SET retry_after=retry_after+?-retry_seconds, retry_seconds=? "
                   "WHERE body IS NULL AND retry_seconds=? AND "
                   "(instr(error, 'TimeoutExpired')>0 OR instr(error, 'AppleEventTimeout')>0)",
                   (TIMEOUT_RETRY_SECONDS, TIMEOUT_RETRY_SECONDS, RETRY_SECONDS))
        db.commit()
        yield db, path
    finally:
        if db is not None:
            db.close()


def inventory_rows(data):
    rows = data.get('items')
    if (not isinstance(rows, list) or any(not isinstance(r, dict) or not isinstance(r.get('id'), str)
            or type(r.get('ts')) is not int for r in rows)):
        raise ValueError('MAIL_APP_INVALID_RESPONSE')
    rows = list({r['id']: r for r in sorted(rows, key=lambda r: r['ts'])}.values())
    return sorted(rows, key=lambda r: (-r['ts'], r['id']))


def _stored(db):
    return {r[0]: r[1:] for r in db.execute('SELECT id,signature,body,attachments,retry_after,error FROM messages')}


def _cached(rows, stored, account_id):
    return {r['id']: {'body': p[1], 'attachments': json.loads(p[2])} for r in rows
            if (p := stored.get(r['id'])) and p[0] == signature(r, account_id) and p[1] is not None}


def _index(account, rows, account_id, detail, root, deadline, max_details, groups=None, since=0):
    attempted, fetched, error, busy = 0, 0, None, False
    try:
        with index_lock(root, account), cache_db(root, account) as (db, _):
            stored = _stored(db)
            live = {r['id'] for r in rows}
            db.executemany('DELETE FROM messages WHERE id=?', [(mid,) for mid in stored if mid not in live])
            db.commit()
            pending = []
            for row in rows:
                sig, prior = signature(row, account_id), stored.get(row['id'])
                if prior and prior[0] == sig and (prior[1] is not None or prior[3] > time.time()):
                    continue
                if not since or row['ts'] >= since:
                    failed = bool(prior and prior[0] == sig and prior[1] is None)
                    pending.append((row, sig, failed, prior[3] if failed else 0))
            # Unattempted/new mail precedes failed mail, so a bad message cannot starve the backlog.
            pending.sort(key=lambda p: (p[2], p[3], matched_fields(p[0], None, groups or [[]]) is None, -p[0]['ts']))
            # Commit each message, and take small batches until the total deadline is reached.
            for start in range(0, len(pending), MAX_DETAILS):
                for row, sig, _, _ in pending[start:start + MAX_DETAILS]:
                    remaining = deadline - time.monotonic()
                    if remaining < 0.5 or (max_details is not None and attempted >= max_details):
                        return {'attempted': attempted, 'indexed_this_call': fetched, 'index_error': error, 'index_busy': False}
                    attempted += 1
                    try:
                        item = detail(row['id'], min(DETAIL_TIMEOUT, remaining))
                        if (item.get('id') != row['id'] or not isinstance(item.get('body'), str)
                                or not isinstance(item.get('attachments'), list)
                                or not all(isinstance(n, str) for n in item['attachments'])):
                            raise ValueError('MAIL_APP_INVALID_RESPONSE')
                        db.execute('INSERT OR REPLACE INTO messages (id,signature,body,attachments,retry_after,error) VALUES (?,?,?,?,0,NULL)',
                                   (row['id'], sig, item['body'], json.dumps(item['attachments'], ensure_ascii=False)))
                        fetched += 1
                    except (ValueError, OSError) as exc:
                        error = str(exc) if isinstance(exc, ValueError) else 'MAIL_APP_SEARCH_CACHE_UNAVAILABLE'
                        retry = TIMEOUT_RETRY_SECONDS if is_timeout(error) else RETRY_SECONDS
                        db.execute('INSERT OR REPLACE INTO messages (id,signature,body,attachments,retry_after,error,retry_seconds) VALUES (?,?,NULL,NULL,?,?,?)',
                                   (row['id'], sig, time.time() + retry, error, retry))
                    db.commit()
                    if is_timeout(error):
                        # Killing osascript does not cancel the event already executing in Mail.
                        # Do not queue a whole batch behind a stalled content read.
                        return {'attempted': attempted, 'indexed_this_call': fetched, 'index_error': error, 'index_busy': False}
    except BlockingIOError:
        busy = True
    except (OSError, sqlite3.Error, ValueError):
        error = 'MAIL_APP_SEARCH_CACHE_UNAVAILABLE'
    return {'attempted': attempted, 'indexed_this_call': fetched, 'index_error': error, 'index_busy': busy}


def fill(account, inventory, detail, *, cache_root, seconds=45):
    """Read-only bounded fill. The total budget includes inventory; individual reads stay <=3s."""
    if isinstance(seconds, bool) or not 1 <= seconds <= 60:
        raise ValueError('MAIL_APP_INDEX_INVALID_BUDGET')
    start = time.monotonic()
    data = inventory(min(10, seconds))
    rows = inventory_rows(data)
    account_id = data.get('account_id', account)
    stats = _index(account, rows, account_id, detail, cache_root, start + seconds, None)
    cached, unconfirmed = {}, []
    try:
        with cache_db(cache_root, account) as (db, _):
            stored = _stored(db)
            cached = _cached(rows, stored, account_id)
            for row in rows:
                if row['id'] not in cached:
                    prior = stored.get(row['id'])
                    failed = prior and prior[0] == signature(row, account_id) and prior[1] is None
                    unconfirmed.append({'id': row['id'], 'error': (prior[4] or 'MAIL_APP_PREVIOUS_READ_FAILED') if failed else 'not_indexed',
                                        'retry_after': prior[3] if failed else 0})
    except (OSError, sqlite3.Error, ValueError):
        stats['index_error'] = 'MAIL_APP_SEARCH_CACHE_UNAVAILABLE'
    return {**stats, 'total': len(rows), 'indexed': len(cached), 'unknown': len(rows) - len(cached),
            'complete': len(cached) == len(rows), 'unconfirmed': unconfirmed,
            'elapsed_seconds': round(time.monotonic() - start, 3)}


def search(account, query, limit, inventory, detail, hydrate, *, cache_root=None):
    groups, since = query_parts(query)
    data = inventory()
    rows = inventory_rows(data)
    total, cached, cache_error, fetched = len(rows), {}, None, 0
    eligible = [r for r in rows if not since or r['ts'] >= since]
    if cache_root is not None:
        stats = _index(account, rows, data.get('account_id', account), detail, cache_root,
                       time.monotonic() + INDEX_SECONDS, MAX_DETAILS, groups, since)
        fetched, cache_error = stats['indexed_this_call'], stats['index_error']
        try:
            with cache_db(cache_root, account) as (db, path):
                cached = _cached(rows, _stored(db), data.get('account_id', account))
        except (OSError, sqlite3.Error, ValueError):
            cache_error = 'MAIL_APP_SEARCH_CACHE_UNAVAILABLE'
    hits = []
    for row in eligible:
        fields = matched_fields(row, cached.get(row['id']), groups)
        if fields is not None:
            hits.append({**row, 'matched_fields': fields})
    chosen = hits[:limit]
    # Fetch References/RFC IDs only for the messages returned to the caller.
    header_error = None
    details = {}
    if cache_root is not None and stats['index_busy']:
        # Mail serializes Apple Events. Keep an ongoing backfill from turning a successful
        # cached search into a timeout while fetching optional References for 20 results.
        header_error = 'MAIL_APP_INDEXING_REFERENCES_DEFERRED'
    elif chosen:
        try:
            details = {r['id']: r for r in hydrate([r['id'] for r in chosen])}
        except (ValueError, OSError):
            header_error = 'MAIL_APP_REFERENCES_UNAVAILABLE'
    result = [{**r, **details.get(r['id'], {}), 'matched_fields': r['matched_fields']} for r in chosen]
    if header_error:
        result = [{**r, 'references_unknown': True} for r in result]
    checked = sum(r['id'] in cached for r in eligible)
    needs_content = any(field in {'any', 'body', 'attachment_name'} for g in groups for field, _ in g)
    coverage = {'metadata_checked': total, 'metadata_total': total,
                'body_checked': checked, 'attachment_names_checked': checked, 'content_total': len(eligible),
                'complete': not needs_content or checked == len(eligible), 'matched_count': len(hits),
                'matched_count_exact': not needs_content or checked == len(eligible),
                'returned_count': len(result), 'has_more': len(hits) > limit, 'indexed_this_call': fetched,
                'method': 'mail_app_local_cache' if cache_root is not None else 'metadata_only',
                'coverage_text': f'제목·보낸 사람 {total}/{total}통, 본문·첨부 이름 검색 범위 {checked}/{len(eligible)}통'}
    if cache_root is not None and stats['index_busy']:
        coverage['index_busy'] = True
    coverage['headers_complete'] = header_error is None
    if header_error:
        coverage['header_error'] = header_error
    if cache_error:
        coverage['index_error'] = cache_error
    if not coverage['complete']:
        coverage['limitation'] = '본문·첨부 이름 미확인 메일이 남아 있다. 결과만으로 전체 메일에 없다고 단정하지 말고 lookup을 이어 검색 범위를 늘린다.'
    return SearchResults(result, coverage)
