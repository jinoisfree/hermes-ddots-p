"""Optional profile-local task skill routing; absent settings preserve assistant behavior."""

# Owner-specific text is rendered from private policy; public source stays generic.
from pathlib import Path as _OwnerPath
import sys as _owner_sys
_owner_library = str((_OwnerPath(__file__).resolve().parent / '..').resolve())
if _owner_library not in _owner_sys.path:
    _owner_sys.path.insert(0, _owner_library)
from hermes_facility.owner_text import render as _owner_text

from pathlib import Path
from collections import OrderedDict
import threading

_CONFIG = OrderedDict()
_LOCK = threading.RLock()

DEFAULTS = {"personal": _owner_text("<<personal_skill_prefix>>-personal-work"), "web": _owner_text("<<personal_skill_prefix>>-web-research"),
            "mail": _owner_text("<<personal_skill_prefix>>-mail"), "work": _owner_text("<<personal_skill_prefix>>-task-workflow"), "learn": _owner_text("<<personal_skill_prefix>>-learning")}


def settings(home):
    from ruamel.yaml import YAML
    path = Path(home).resolve() / "config.yaml"
    with _LOCK:
        try:
            stat = path.stat()
            signature = (stat.st_mtime_ns, stat.st_ctime_ns, stat.st_size, stat.st_ino)
        except FileNotFoundError:
            signature = None
        previous = _CONFIG.get(path)
        if previous is not None and previous[0] == signature:
            _CONFIG.move_to_end(path)
            return previous[1]
        config = (YAML(typ="safe").load(path.read_text()) or {}) if signature is not None else {}
        result = config.get("plugins", {}).get("entries", {}).get("team-kit", {}).get("settings", {}).get("learning", {})
        _CONFIG[path] = (signature, result)
        while len(_CONFIG) > 16:
            _CONFIG.popitem(last=False)
        return result


def mapping(config=None):
    config = config or {}
    if "task_skills" not in config:
        return dict(DEFAULTS)
    value = config["task_skills"]
    if not isinstance(value, dict):
        raise ValueError("learning.task_skills must be a role-to-skill map.")
    if any(role not in DEFAULTS or not isinstance(name, str) or not name.strip()
           for role, name in value.items()):
        raise ValueError("learning.task_skills needs known roles and nonempty skill names.")
    return dict(value)
