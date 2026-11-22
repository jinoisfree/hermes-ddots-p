"""One spelling rule for folder paths that people, apps and the disk write differently.

Hangul can be stored composed (NFC) or decomposed (NFD): a settings screen saves one form, a disk
listing or a pasted path gives the other, and the two look identical. Paths are compared by this
rule everywhere a folder scope is checked or saved. The path that is returned or opened is never
rewritten except for the part that names a configured root, which takes the root's own spelling."""
from __future__ import annotations

from pathlib import Path
import unicodedata


def normal(value) -> str:
    """The single spelling used to compare and save paths: composed Hangul (NFC)."""
    return unicodedata.normalize('NFC', str(value))


def _match(path, roots):
    """(root, its normal form) for the deepest root that equals or contains ``path`` by ``normal``, else None."""
    target = Path(normal(path))
    hits = [(root, Path(normal(root))) for root in roots]
    hits = [(root, base) for root, base in hits if base == target or base in target.parents]
    return max(hits, key=lambda hit: len(hit[1].parts), default=None)


def anchored(path, roots) -> Path | None:
    """``path`` with the part that names a root spelled like that root; the rest untouched.

    None when ``path`` is outside every root. Equal spelling gives back an equal path."""
    path = Path(path)
    hit = _match(path, roots)
    if hit is None:
        return None
    root, base = hit
    return Path(root, *path.parts[len(base.parts):])


def below(path, base) -> Path | None:
    """The part of ``path`` under ``base`` (``Path('.')`` when equal), comparing by ``normal``; None when outside."""
    path = Path(path)
    hit = _match(path, [base])
    return None if hit is None else Path(*path.parts[len(hit[1].parts):])


def listed(path, roots) -> bool:
    """True when ``path`` is one of ``roots`` (not below it), comparing by ``normal``."""
    return any(normal(path) == normal(root) for root in roots)
