"""Staff-locker files of the check: run state (watch.json), captures, and their retention."""
import contextlib
import fcntl
import json
import os
import shutil
import tempfile
from datetime import timedelta
from pathlib import Path


def folder(home):
    return Path(home) / 'state' / 'cctv'


def captures(home, day):
    return folder(home) / 'captures' / day


def reference_folder(home):
    return folder(home) / 'reference'


@contextlib.contextmanager
def locked(home, *, wait=False):
    """Exclusive run lock; yields False when another run holds it and wait is off."""
    folder(home).mkdir(parents=True, exist_ok=True)
    with (folder(home) / 'watch.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        yield True


def read(home):
    """Read the stored state without applying the daily lifetime rule."""
    try:
        return json.loads((folder(home) / 'watch.json').read_text(encoding='utf-8'))
    except FileNotFoundError:
        return {}


def load(home, day):
    """watch.json, with all daily judgments and counters reset when the day changes."""
    data = read(home)
    if data.get('day') != day:
        data = {'version': 1, 'day': day, 'last_slot': None, 'consecutive_unread': 0, 'alerts': []}
    return data


def save(home, data):
    path = folder(home) / 'watch.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.watch-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(data, stream, ensure_ascii=False, indent=1)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prune(home, keep_days, today):
    """Delete capture folders older than keep_days; reference photos are never touched."""
    root = folder(home) / 'captures'
    if not root.is_dir():
        return []
    cutoff = (today - timedelta(days=keep_days)).isoformat()
    removed = []
    for child in sorted(root.iterdir()):
        if child.is_dir() and len(child.name) == 10 and child.name < cutoff:
            shutil.rmtree(child)
            removed.append(child.name)
    return removed
