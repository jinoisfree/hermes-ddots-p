"""One atomic file write for team-kit state: temp file beside the target, fsync, rename.

Readers never see half a file, and two writers never share a temp name (several modules used a
fixed ``<name>.tmp``, so writers started at the same minute raced on it). The temp file is created
0600 by mkstemp; ``mode`` forces other bits onto the result."""
from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
from typing import Any


def write_text(path, text: str, *, mode: int | None = None, fsync_dir: bool = False,
               prefix: str | None = None, encoding: str = 'utf-8') -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=prefix or '.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding=encoding) as stream:
            if mode is not None:
                os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        if fsync_dir:
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_json(path, data: Any, *, indent: int | None = None, newline: bool = True, **options) -> None:
    write_text(path, json.dumps(data, ensure_ascii=False, indent=indent) + ('\n' if newline else ''), **options)
