"""The one place that remembers parsed files and the installed-app list.

A result is reused only while what it was built from is unchanged: the stamp stored with it must
equal the stamp of the call (the file's own bytes, or the size and modification time of every file it
was built from). So a save, an app connect or disconnect, or any edit is seen by the very next call,
and nothing here is a second copy of the data: forgetting an entry only costs one more read.
Standard library only.
"""
from collections import OrderedDict
from copy import deepcopy
import hashlib
import threading

LIMIT = 128
_lock = threading.Lock()
_entries: OrderedDict = OrderedDict()


def remembered(key, stamp, compute, *, share=False):
    """compute()'s value, recomputed only when ``stamp`` differs from the one it was stored under.

    The caller gets a private copy unless ``share`` is set; share only for a caller that never
    changes the result."""
    with _lock:
        hit = _entries.get(key)
        if hit is not None and hit[0] == stamp:
            _entries.move_to_end(key)
            return hit[1] if share else deepcopy(hit[1])
    value = compute()
    with _lock:
        _entries[key] = (stamp, value)
        _entries.move_to_end(key)
        while len(_entries) > LIMIT:
            _entries.popitem(last=False)
    return value if share else deepcopy(value)


def parsed(kind, data, parse, *, share=False):
    """parse(data), remembered under the digest of ``data`` itself: the same bytes always parse to the
    same value, so this can never be stale."""
    raw = data if isinstance(data, bytes) else data.encode('utf-8')
    return remembered((kind, hashlib.sha256(raw).digest()), None, lambda: parse(data), share=share)


def stat_stamp(paths):
    """Size and modification time of every path (a missing path is part of the stamp)."""
    stamp = []
    for path in paths:
        try:
            info = path.stat()
            stamp.append((str(path), info.st_mtime_ns, info.st_size))
        except OSError:
            stamp.append((str(path), None, None))
    return tuple(stamp)


def forget():
    with _lock:
        _entries.clear()
