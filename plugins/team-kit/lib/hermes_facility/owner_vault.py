"""Private owner vault lookup; missing required values disable operations."""
from __future__ import annotations

import logging
import os
import re
from pathlib import Path

logger = logging.getLogger(__name__)

_CACHE: dict[str, tuple] = {}
_WARNED: set[tuple] = set()
_PLACEHOLDER = re.compile(r"\{([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*)\}")


class VaultError(ValueError):
    """금고에 필요한 값이 없을 때(사람이 읽을 수 있는 설명을 담는다)."""


def root_home() -> Path:
    """루트 홈. 프로필 홈(<루트>/profiles/<id>)에서 불러도 같은 루트를 돌려준다."""
    try:
        from hermes_constants import get_hermes_home
        home = Path(get_hermes_home())
    except Exception:
        home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    return home.parent.parent if home.parent.name == "profiles" else home


def vault_file() -> Path:
    configured = os.environ.get("HERMES_VAULT_FILE")
    return Path(configured) if configured else root_home() / "owner" / "vault.yaml"


def _warn(path: Path, reason: str) -> None:
    key = (str(path), reason)
    if key not in _WARNED:
        _WARNED.add(key)
        logger.warning("owner vault %s: %s; running with an empty vault (features that need owner values stay off)",
                       path, reason)


def _parse(text: str):
    try:
        import hermes_yaml
        return hermes_yaml.safe_load(text)
    except ImportError:
        from ruamel.yaml import YAML
        return YAML(typ="safe").load(text)


def _read(path: Path) -> dict:
    try:
        data = _parse(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _warn(path, "file not found")
        return {}
    except Exception as exc:
        _warn(path, f"unreadable ({type(exc).__name__})")
        return {}
    if not isinstance(data, dict) or not data:
        _warn(path, "empty or not a mapping")
        return {}
    return data


def data() -> dict:
    """금고 전체(파일 수정 시각이 바뀔 때만 다시 읽는다)."""
    path = vault_file()
    try:
        stat = path.stat()
        stamp = (stat.st_mtime_ns, stat.st_size)
    except OSError:
        stamp = None
    cached = _CACHE.get(str(path))
    if cached and cached[0] == stamp:
        return cached[1]
    value = _read(path)
    _CACHE[str(path)] = (stamp, value)
    return value


def get(key: str, default=None):
    """점으로 이어 쓴 키의 값. 없거나 비어 있으면 default."""
    node = data()
    for part in str(key).split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    if node is None or node == "" or node == [] or node == {}:
        return default
    return node


def text(key: str, default: str = "") -> str:
    """문자열 값(숫자도 문자열로). 없으면 default."""
    value = get(key)
    return default if value is None or isinstance(value, (dict, list)) else str(value).strip() or default


def require(key: str):
    """get과 같지만 값이 없으면 어떤 키를 금고에 채워야 하는지 말하는 VaultError."""
    value = get(key)
    if value is None:
        raise VaultError(f"owner vault value '{key}' is not set in {vault_file()}")
    return value


def path(key: str):
    """경로 값(~ 확장). 없으면 None."""
    value = text(key)
    return Path(value).expanduser() if value else None


def expand(obj):
    """문자열 속 ``{channels.reports}`` 같은 자리표시를 금고 값으로 바꾼 사본(목록·사전 안까지).
    금고에 없는 키는 자리표시 그대로 남겨 비교·검사가 어긋나게 한다(조용히 빈 값이 되지 않는다)."""
    if isinstance(obj, str):
        def fill(match):
            value = get(match.group(1))
            return match.group(0) if value is None or isinstance(value, (dict, list)) else str(value)
        return _PLACEHOLDER.sub(fill, obj)
    if isinstance(obj, list):
        return [expand(item) for item in obj]
    if isinstance(obj, dict):
        return {key: expand(value) for key, value in obj.items()}
    return obj
