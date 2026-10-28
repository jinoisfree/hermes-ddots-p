"""Best-effort secret read hints for ordinary tools, not a security boundary.

Shell/code tokenization cannot understand indirect reads, encodings, glob expansion or
subprocess semantics. Dedicated credential tools and existing approval gates still apply.
Never inspect file contents or log a command/code body here.
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
import stat
from datetime import datetime, timezone
from pathlib import Path

TOOLS = frozenset({"read_file", "search_files", "terminal", "execute_code"})
MESSAGE = "비밀 파일은 직접 읽지 않는다. 그 파일을 쓰는 전용 도구를 쓴다. 다시 시도해도 같다."
BLOCK = {"action": "block", "message": MESSAGE}
BASENAMES = ("google_token.json", "*client_secret*.json", "auth.json", "auth.lock",
             ".anthropic_oauth.json", ".env", ".env.*", ".envrc", ".netrc",
             "id_rsa*", "id_ed25519*", "*.pem", "*.p12")
HOME_PATHS = (".ssh", ".aws", ".gnupg", ".codex", ".claude/.credentials.json", "Library/Keychains")
TOKEN_SPLIT = str.maketrans({c: " " for c in "|;&,()[]{}<>'\""})


def forms(value, cwd=None):
    expanded = os.path.expandvars(os.path.expanduser(value))
    absolute = os.path.abspath(os.path.join(str(cwd or os.getcwd()), expanded))
    return absolute, str(Path(absolute).resolve(strict=False))


def path_rule(value, cwd=None):
    for path in forms(value, cwd):
        folded = path.casefold()
        name = os.path.basename(folded)
        if name != ".env.example":
            for pattern in BASENAMES:
                if fnmatch.fnmatchcase(name, pattern):
                    return path, pattern
        for suffix in HOME_PATHS:
            for base in forms(str(Path.home() / suffix)):
                base = base.casefold()
                if folded == base or fnmatch.fnmatchcase(folded, base + "/**"):
                    return path, "~/" + suffix + "/**"
        for directory in ("mcp-tokens", "browser-profile"):
            if directory in Path(folded).parts:
                return path, "**/" + directory + "/**"
    return None


def tokens(text):
    for token in text.translate(TOKEN_SPLIT).split():
        if (token.startswith(("~", "/", "."))
                or any(fnmatch.fnmatchcase(token.casefold(), p) for p in BASENAMES)):
            yield token


def inspect(tool, args, cwd=None):
    cwd = args.get("workdir") or cwd
    if cwd:
        match = path_rule(str(cwd))
        if match:
            return match
    if tool in {"read_file", "search_files"}:
        match = path_rule(args.get("path") or ".", cwd)
        if match:
            return match
        if tool == "read_file":
            return None
        # Search arguments may name an exact sensitive file even when path is a directory.
        texts = [args.get("pattern", ""), args.get("file_glob", "")]
    else:
        texts = [args.get("command" if tool == "terminal" else "code", "")]
    for text in texts:
        if not isinstance(text, str):
            raise TypeError("invalid tool text")
        if re.search(r"\bsecurity\s+find-(?:generic|internet)-password\b", text, re.I):
            return "keychain-password", "keychain-password"
        for token in tokens(text):
            match = path_rule(token, cwd)
            if match:
                return match
    return None


def record(home, tool, target, rule):
    # A logging failure also blocks the read. No content, command, or exception text.
    directory = Path(home) / "logs"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "secret_guard.jsonl"
    if directory.is_symlink() or path.is_symlink():
        raise ValueError("symlink audit log")
    target = target.replace(str(Path.home()), "~")
    event = {"ts": datetime.now(timezone.utc).isoformat(), "tool": tool, "target": target, "rule": rule}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("nonregular audit log")
        stream.write(json.dumps(event, ensure_ascii=False) + "\n")


def guard(home, *, tool_name="", args=None, configured=None, cwd=None):
    if tool_name not in TOOLS:
        return None
    try:
        if isinstance(configured, dict) and configured.get("enabled", True) is False:
            return None
        match = inspect(tool_name, args if isinstance(args, dict) else {}, cwd)
        if match is None:
            return None
        record(home, tool_name, *match)
    except Exception:
        try:
            record(home, tool_name, "secret-guard-error", "secret-guard-error")
        except Exception:
            pass
    return dict(BLOCK)
