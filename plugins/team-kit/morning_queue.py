"""Durable maintenance notices: locked atomic writes, acknowledge only a sent prefix.

2026-10-28 사용자 결정: 00:00~08:29 KST에는 진단담당 명의 글이 Slack에 올라가지 않는다(``quiet``).
그 시간의 보고는 ``hold``로 모아 두고 08:30 아침 시스템 보고가 원래 채널에 올린다.
"""
from contextlib import contextmanager
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import stat
import tempfile
import time
from zoneinfo import ZoneInfo

KST = ZoneInfo('Asia/Seoul')


def quiet(now=None):
    """00:00~08:29 KST: 새벽 알림 금지 시간 (2026-10-28 사용자 결정)."""
    now = datetime.fromtimestamp(time.time() if now is None else now, KST)
    return (now.hour, now.minute) < (8, 30)


@contextmanager
def locked(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError('symlink queue/state')
    fd = os.open(path.with_suffix('.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('nonregular lock')
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def atomic_write(path, text):
    fd, name = tempfile.mkstemp(prefix='.morning-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read(path):
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError('symlink queue')
    return path.read_text() if path.exists() else ''


def append(path, *, level, title, body, at=None):
    path = Path(path)
    row = {'at': at or datetime.now(ZoneInfo('Asia/Seoul')).isoformat(),
           'level': level, 'title': title, 'body': body}
    with locked(path):
        text = read(path)
        if text and not text.endswith('\n'):
            raise ValueError('incomplete queue')
        atomic_write(path, text + json.dumps(row, ensure_ascii=False) + '\n')


def snapshot(path):
    text = read(Path(path))
    rows = [json.loads(line) for line in text.splitlines() if line.strip()]
    for row in rows:
        if not isinstance(row, dict) or any(not isinstance(row.get(k), str) for k in ('at', 'level', 'title', 'body')):
            raise ValueError('invalid queue entry')
    return text, rows


def acknowledge(path, sent):
    if not sent:
        return
    path = Path(path)
    with locked(path):
        current = read(path)
        if not current.startswith(sent):
            raise ValueError('queue prefix changed; preserved')
        # Notices appended while Slack was sending remain for the next report.
        atomic_write(path, current[len(sent):])


def held_path(home):
    return Path(home) / 'watcher-state/held-posts.jsonl'


def hold(home, channel, text, at=None, *, topic=None):
    """Keep a quiet-hours post (channel, text) for the 08:30 morning flush."""
    path = held_path(home)
    row = {'at': at or datetime.now(KST).isoformat(), 'channel': channel, 'text': text}
    if topic: row['topic'] = topic
    with locked(path):
        current = read(path)
        if current and not current.endswith('\n'):
            raise ValueError('incomplete queue')
        atomic_write(path, current + json.dumps(row, ensure_ascii=False) + '\n')


def flush_held(home, post):
    """Post held rows in order with ``post(channel, text)``; a failure keeps the rest for the next run."""
    path = held_path(home)
    sent = 0
    with locked(path):
        rows = [json.loads(line) for line in read(path).splitlines() if line.strip()]
        remaining = list(rows)
        try:
            for row in rows:
                if memory_row(row):
                    continue  # The learning producer owns these receipts, not the system DM.
                post(row['channel'], row['text'])
                remaining.remove(row)
                sent += 1
        finally:
            atomic_write(path, ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in remaining))
    return sent


def memory_row(row):
    return row.get('topic') == 'memory_tidy' or row.get('text', '').startswith(('*🟢 새벽 기억 정리', '*🟡 새벽 기억 정리'))


def learning_appendices(home, channel):
    path = held_path(home)
    with locked(path):
        return [r for r in (json.loads(line) for line in read(path).splitlines() if line.strip())
                if memory_row(r) and r.get('channel') == channel]


def acknowledge_appendices(home, delivered):
    path = held_path(home)
    with locked(path):
        rows = [json.loads(line) for line in read(path).splitlines() if line.strip()]
        for row in delivered:
            if row in rows: rows.remove(row)
        atomic_write(path, ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
