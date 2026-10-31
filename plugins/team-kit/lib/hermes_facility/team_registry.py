"""Role roster lookup from private owner/team.yaml; missing roles stay disabled."""
from __future__ import annotations

import logging
import os
from pathlib import Path

logger = logging.getLogger(__name__)

ROLES = ("personal", "work", "doctor", "wiki", "customers", "sns", "standby", "responder")
_CACHE: dict[str, tuple] = {}
_WARNED: set[tuple] = set()


def root_home() -> Path:
    """루트 홈. 프로필 홈(<루트>/profiles/<id>)에서 불러도 같은 루트를 돌려준다."""
    try:
        from hermes_constants import get_hermes_home
        home = Path(get_hermes_home())
    except Exception:
        home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    return home.parent.parent if home.parent.name == "profiles" else home


def team_file() -> Path:
    configured = os.environ.get("HERMES_TEAM_FILE")
    return Path(configured) if configured else root_home() / "owner" / "team.yaml"


def _warn(path: Path, reason: str) -> None:
    key = (str(path), reason)
    if key not in _WARNED:
        _WARNED.add(key)
        logger.warning("team registry %s: %s; running with an empty roster (role features stay off)", path, reason)


def _parse(text: str):
    try:
        import hermes_yaml
        return hermes_yaml.safe_load(text)
    except ImportError:
        from ruamel.yaml import YAML
        return YAML(typ="safe").load(text)


def _read(path: Path) -> dict[str, dict]:
    try:
        data = _parse(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _warn(path, "file not found")
        return {}
    except Exception as exc:
        _warn(path, f"unreadable ({type(exc).__name__})")
        return {}
    agents = data.get("agents") if isinstance(data, dict) else None
    if not isinstance(agents, dict) or not agents:
        _warn(path, "no agents listed")
        return {}
    roster: dict[str, dict] = {}
    for key, value in agents.items():
        profile = str(key).strip()
        if not profile:
            continue
        value = value if isinstance(value, dict) else {}
        roles = value.get("roles")
        roles = tuple(str(r).strip() for r in roles if str(r).strip()) if isinstance(roles, (list, tuple)) else ()
        name = str(value.get("name") or "").strip() or profile
        aliases = value.get("aliases")
        aliases = tuple(str(a).strip() for a in aliases if str(a).strip()) if isinstance(aliases, (list, tuple)) else ()
        roster[profile] = {"name": name, "label": str(value.get("label") or "").strip() or name, "roles": roles,
                           "aliases": aliases}
    return roster


def roster() -> dict[str, dict]:
    """명부 전체(파일 수정 시각이 바뀔 때만 다시 읽는다)."""
    path = team_file()
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


def profiles() -> tuple[str, ...]:
    """직원 id 전체(명부 순서)."""
    return tuple(roster())


def profiles_sorted() -> tuple[str, ...]:
    """직원 id 전체: default(루트)가 맨 앞, 나머지는 이름순(점검·보고서 목록용)."""
    return tuple(sorted(roster(), key=lambda p: (p != "default", p)))


def agents_with(role: str) -> tuple[str, ...]:
    return tuple(p for p, v in roster().items() if role in v["roles"])


def first_with(role: str):
    found = agents_with(role)
    return found[0] if found else None


def has_role(profile, *roles: str) -> bool:
    """profile이 roles 중 하나라도 가지면 참. 명부에 없는 id는 항상 거짓."""
    entry = roster().get(str(profile or "").strip())
    return bool(entry) and any(role in entry["roles"] for role in roles)


def roles_of(profile) -> tuple[str, ...]:
    entry = roster().get(str(profile or "").strip())
    return entry["roles"] if entry else ()


def name_of(profile) -> str:
    """사람에게 보이는 표시 이름. 명부에 없으면 id 그대로."""
    entry = roster().get(str(profile or "").strip())
    return entry["name"] if entry else str(profile or "")


def label_of(profile) -> str:
    """보고서·목록에 쓰는 이름(label이 없으면 name)."""
    entry = roster().get(str(profile or "").strip())
    return entry["label"] if entry else str(profile or "")


def pick(table: dict, profile, *default):
    """직책 이름을 키로 가진 표에서 profile이 가진 첫 직책의 값. 없으면 default(주면) 아니면 KeyError."""
    for role, value in table.items():
        if has_role(profile, role):
            return value
    if default:
        return default[0]
    raise KeyError(profile)


def mentioned(text: str) -> list[str]:
    """글 속에 별칭(aliases)이 들어 있는 직원 id들(명부 순서)."""
    text = str(text or "")
    return [p for p, v in roster().items() if any(a in text for a in v["aliases"])]


def home_of(profile: str, root=None) -> Path:
    """default는 루트 홈, 나머지는 <루트>/profiles/<id>."""
    base = Path(root) if root is not None else root_home()
    return base if profile == "default" else base / "profiles" / profile


def home_of_role(role: str, root=None) -> Path:
    """직책 담당자의 홈. 담당자가 없으면 존재하지 않는 자리 표시 경로(읽기·쓰기가 모두 실패하도록)."""
    profile = first_with(role)
    if profile is None:
        base = Path(root) if root is not None else root_home()
        return base / "profiles" / f"(no-{role}-agent)"
    return home_of(profile, root)


def profile_of_home(home) -> str | None:
    """홈 경로의 직원 id. 폴더 이름이 명부의 id이면 그것, 루트 홈이면 default, 아니면 None."""
    if not home:
        return None
    path = Path(home)
    agents = roster()
    if path.name != "default" and path.name in agents:
        return path.name
    if "default" in agents:
        try:
            if path.resolve() == root_home().resolve():
                return "default"
        except OSError:
            pass
    return None


def home_has_role(home, *roles: str) -> bool:
    return has_role(profile_of_home(home), *roles)
