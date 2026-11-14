"""The file-drop engine's single policy reader/writer and capability table.

The UI keeps no selection: every read and every suggestion resolves this policy.
Only an explicit local UI action or authenticated relay action calls write().
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import date, datetime, timezone
import hashlib
from io import StringIO
import json
import os
from pathlib import Path
import sys
import time

LIBRARY = Path(__file__).resolve().parent.parent
if str(LIBRARY) not in sys.path:
    sys.path.insert(0, str(LIBRARY))
from hermes_facility.config_assembly import atomic_write, locked, checked_path

MODELS = {"fable": "claude-fable-5-1", "opus": "claude-opus-5-5",
          "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-4-5-20251001"}
EFFORTS = (None, "low", "medium", "high", "xhigh", "max")
# Synthetic PNG, three real CLI rounds per combination; see implementation evidence.
BUDGETS = {
    'fable': {None: (15, 800), 'low': (15, 800), 'medium': (15, 800), 'high': (15, 800), 'xhigh': (15, 800), 'max': (25, 4096)},
    'opus': {None: (15, 800), 'low': (15, 800), 'medium': (15, 800), 'high': (15, 800), 'xhigh': (20, 4096), 'max': (120, 4096)},
    'sonnet': {None: (15, 800), 'low': (15, 800), 'medium': (15, 800), 'high': (15, 800), 'xhigh': (15, 800), 'max': (40, 4096)},
    'haiku': {None: (20, 800), 'low': (20, 800), 'medium': (20, 800), 'high': (15, 800), 'xhigh': (15, 800), 'max': (20, 800)},
}

SECTION = "file_drop_engine"


def validate(model, effort):
    if not isinstance(model, str) or model not in MODELS or effort not in EFFORTS:
        raise ValueError("engine_invalid")
    if effort not in BUDGETS[model]:
        raise ValueError("engine_unsupported")


def engine(model="sonnet", effort=None):
    validate(model, effort)
    seconds, tokens = BUDGETS[model][effort]
    revision = hashlib.sha256(json.dumps([model, effort]).encode()).hexdigest()[:12]
    return dict(model=model, effort=effort, seconds=seconds, revision=revision,
                tokens=tokens)


def document(data):
    from ruamel.yaml import YAML
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 10000
    value = yaml.load(data) if data else {}
    if value is None:
        value = {}
    if not isinstance(value, dict):
        raise ValueError("policy_invalid")
    return yaml, value


def selection(value):
    if SECTION not in value:
        return engine()
    block = value[SECTION]
    if not isinstance(block, dict) or set(block) != {"decision", "model", "effort"}:
        raise ValueError("engine_invalid")
    if not isinstance(block["decision"], (str, date)):
        raise ValueError("engine_invalid")
    date.fromisoformat(str(block["decision"]))
    return engine(block["model"], block["effort"])


def read(home):
    try:
        return selection(document((Path(home) / "owner/policy.yaml").read_bytes())[1])
    except (OSError, ValueError, TypeError, KeyError):
        return engine()
    except Exception as exc:
        from ruamel.yaml.error import YAMLError
        if isinstance(exc, YAMLError):
            return engine()
        raise


def describe(home):
    return dict(read(home), choices=[dict(model=model, efforts=list(table))
                                    for model, table in BUDGETS.items()])


def outside(value):
    return {key: item for key, item in value.items() if key != SECTION}


def comments(data):
    # Include inline comments as well as whole comment lines, in original order.
    from ruamel.yaml import YAML
    from ruamel.yaml.tokens import CommentToken
    result = []
    for token in YAML().scan(data):
        for group in getattr(token, "comment", None) or []:
            for comment in (group if isinstance(group, list) else [group]):
                if isinstance(comment, CommentToken):
                    result.append(comment.value)
    return result


def without_block(data, value):
    """Compare byte layout outside the changed top-level node."""
    if SECTION not in value:
        return data.rstrip(b"\n")
    lines = data.splitlines(keepends=True)
    start = value.lc.key(SECTION)[0]
    following = [value.lc.key(key)[0] for key in value if key != SECTION
                 and value.lc.key(key)[0] > start]
    end = min(following) if following else len(lines)
    return b"".join(lines[:start] + lines[end:]).rstrip(b"\n")


def compose_policy(before, yaml, value):
    """A flow root (including JSON layout) must never be globally reformatted.

    Round-trip just this value and splice its exact node span. Unrelated bytes,
    including the root's indentation and trailing comments, never pass a dumper.
    """
    root = yaml.compose(before) if before else None
    if root is not None and root.flow_style:
        yaml.default_flow_style = True
        stream = StringIO()
        yaml.dump(value[SECTION], stream)
        fragment = stream.getvalue().rstrip("\n")
        original = before.decode("utf-8")
        for key, node in root.value:
            if key.value == SECTION:
                return (original[:node.start_mark.index] + fragment + original[node.end_mark.index:]).encode(), True
        # Keep a pre-existing trailing comma. Tokenization excludes comments.
        tokens = list(yaml.scan(before))
        trailing_comma = len(tokens) >= 3 and type(tokens[-3]).__name__ == "FlowEntryToken"
        separator = ", " if root.value and not trailing_comma else ""
        position = root.end_mark.index - 1
        return (original[:position] + separator + SECTION + ": " + fragment + original[position:]).encode(), True
    stream = StringIO()
    yaml.dump(value, stream)
    return stream.getvalue().encode(), False


@contextmanager
def writer_lock(path):
    # The shared lock is nonblocking. Contention is transient and bounded here.
    until = time.monotonic() + 4
    while True:
        manager = locked(path)
        try:
            manager.__enter__()
            break
        except ValueError as exc:
            if str(exc) != "LOCKED" or time.monotonic() >= until:
                raise
            time.sleep(.01)
    try:
        yield
    finally:
        manager.__exit__(None, None, None)


def write(home, model, effort, *, source):
    """Write only this policy block, with preservation checks before any replace."""
    validate(model, effort)
    home = Path(home)
    policy = checked_path(home, "owner/policy.yaml")
    state = checked_path(home, "state/ddots-file-drop/engine")
    # App connection assembly also writes this policy. Use its existing owner
    # lock so changing an unrelated block cannot race this read/replace.
    with writer_lock(checked_path(home, "owner/.app-connect.lock")):
        for temporary in policy.parent.glob(".policy.yaml-*"):
            if temporary.is_file() and not temporary.is_symlink():
                temporary.unlink()
        before = policy.read_bytes() if policy.exists() else b""
        yaml, value = document(before)
        previous = selection(value)  # malformed existing blocks cannot be overwritten
        if SECTION not in value:
            value[SECTION] = {}
        value[SECTION].update(decision=date.today().isoformat(), model=model, effort=effort)
        after, spliced = compose_policy(before, yaml, value)
        _, reread = document(after)
        _, original = document(before)
        selected = selection(reread)
        if (outside(original) != outside(reread) or comments(before) != comments(after)
                or not spliced and without_block(before, original) != without_block(after, reread)):
            raise ValueError("policy_preservation_failed")
        atomic_write(state / "before-policy.yaml", before)
        atomic_write(policy, after)
        record = dict(at=datetime.now(timezone.utc).isoformat(), source=str(source)[:100],
                      before={key: previous[key] for key in ("model", "effort")},
                      after={key: selected[key] for key in ("model", "effort")},
                      before_sha256=hashlib.sha256(before).hexdigest(),
                      after_sha256=hashlib.sha256(after).hexdigest())
        log = state / "writes.jsonl"
        fd = os.open(log, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")
            stream.flush(); os.fsync(stream.fileno())
        return describe(home)


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, required=True)
    args = parser.parse_args()
    try:
        request = json.loads(input())
        if request.get("mode") == "write":
            result = write(args.home, request.get("model"), request.get("effort"),
                           source=request.get("source", "local"))
        else:
            result = describe(args.home)
        print(json.dumps(result, ensure_ascii=False))
    except Exception:
        print(json.dumps({"error": "engine_save_failed"}))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
