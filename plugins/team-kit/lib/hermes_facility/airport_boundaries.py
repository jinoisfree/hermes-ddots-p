"""Airport boundary findings only; policy and baseline decisions belong to callers."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re

RESERVED_PROFILE_NAMES = frozenset({'default'})

SUFFIXES = {'.py', '.json', '.js', '.mjs', '.swift', '.applescript', '.yaml', '.yml', '.plist', '.sb', '.sh'}
SKIP_PARTS = {'tests', 'Tests', '__pycache__', '.git', '.build', 'node_modules', '.pytest_cache'}
PATTERNS = {
    'slack_id': re.compile(r'(?<![A-Za-z0-9_])[CDUTW]0[A-Z0-9]{8,}(?![A-Za-z0-9_])'),
    'email': re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    'absolute_path': re.compile(r'/(?:Users|Volumes)/'),
    'fixed_home': re.compile(r"""(?:Path\.home\(\)\s*/\s*["']\.hermes["']|["']~/?\.hermes|\$(?:HOME|\{HOME\})/\.hermes|expanduser\(["']~["']\)\s*[/+]\s*["']/?\.hermes)"""),
    # A complete 12-digit token, including inside a prompt; longer hashes are excluded.
    'reservation_id': re.compile(r'(?<![A-Za-z0-9_])[0-9a-f]{12}(?![A-Za-z0-9_])'),
}


def read_source(path):
    """Missing source means an unconfigured installation, malformed input is an error."""
    path = Path(path)
    if not path.exists():
        return {}
    text = path.read_text(encoding='utf-8')
    try:
        return json.loads(text)
    except ValueError:
        from ruamel.yaml import YAML
        return YAML(typ='safe').load(text)


def roster_words(roster):
    words = set()
    for identifier, member in (roster or {}).get('agents', {}).items():
        if identifier not in RESERVED_PROFILE_NAMES:
            words.update((identifier, identifier.replace('-', '_')))
        for key in ('name', 'label'):
            if isinstance(member.get(key), str):
                words.add(member[key])
        words.update(a for a in member.get('aliases', []) if isinstance(a, str))
    return {w for w in words if w}


def vault_words(vault):
    if isinstance(vault, str):
        if len(vault) <= 16 and re.fullmatch(r'[a-z][a-z0-9_-]*', vault):
            return set()
        return {vault} if len(vault) >= 3 else set()
    if isinstance(vault, dict):
        return set().union(set(), *(vault_words(v) for v in vault.values()))
    if isinstance(vault, list):
        return set().union(set(), *(vault_words(v) for v in vault))
    return set()


def word_pattern(words):
    # ASCII identifiers need boundaries; Korean aliases also occur within sentences.
    parts = []
    for word in sorted(words, key=lambda w: (-len(w), w)):
        escaped = re.escape(word)
        if re.fullmatch(r'[A-Za-z0-9_-]+', word):
            escaped = r'(?<![A-Za-z0-9_])' + escaped + r'(?![A-Za-z0-9_])'
        parts.append(escaped)
    return re.compile('|'.join(parts)) if parts else None


def scan(roots, roster=None, vault=None, patterns=True):
    """Return (kind, relative path, fingerprint) tuples, never source lines or values.

    Each root is a (logical relative path, physical path) pair. Overlapping aliases
    resolve to one physical file, keeping the first logical name given by the caller.
    """
    checks = {'roster': word_pattern(roster_words(roster)), 'vault': word_pattern(vault_words(vault))}
    if patterns:
        checks.update(PATTERNS)
    findings, seen = [], set()
    for prefix, root in roots:
        root = Path(root)
        for path in sorted(root.rglob('*')):
            relative = path.relative_to(root)
            if not path.is_file() or path.suffix not in SUFFIXES or SKIP_PARTS.intersection(relative.parts):
                continue
            physical = path.resolve()
            if physical in seen:
                continue
            seen.add(physical)
            logical = (Path(prefix) / relative).as_posix()
            for line in path.read_text(encoding='utf-8').splitlines():
                normalized = ' '.join(line.split())
                for kind, pattern in checks.items():
                    if pattern is not None and pattern.search(line):
                        fingerprint = hashlib.sha256(f'{kind}|{logical}|{normalized}'.encode()).hexdigest()[:16]
                        findings.append((kind, logical, fingerprint))
    return findings
