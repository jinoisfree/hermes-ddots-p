"""Owner values that the router contract (``gateway.common_router``) does not store itself.

The default responder for a new conversation comes from the employee roster (role ``responder``),
and the staff Slack user IDs of the project hub come from the owner vault (``slack.staff_user_ids``).
The contract keeps only routing rules, so each value has one source.
"""
from __future__ import annotations

from typing import Any, Mapping


def default_responder(roster: Mapping[str, Mapping[str, Any]], members=None) -> str | None:
    """The ``responder`` employee, else ``default``, else the first employee (roster order).

    ``members`` narrows the choice to employees that exist somewhere (for example ones with a home)."""
    ids = [p for p in roster if members is None or p in members]
    for profile in ids:
        if "responder" in tuple(roster[profile].get("roles") or ()):
            return profile
    if "default" in ids:
        return "default"
    return ids[0] if ids else None


def fill(contract: Mapping[str, Any] | None, roster: Mapping[str, Mapping[str, Any]], staff: Any) -> dict:
    """The contract with the roster's default responder and the vault's staff IDs filled in.

    An empty roster or vault (missing or unreadable file) leaves the contract's own value,
    so a broken owner file never leaves new conversations without a responder."""
    result = dict(contract or {})
    responder = default_responder(roster)
    if responder:
        result["profiles"] = {**(result.get("profiles") or {}), "fallback": responder}
    if isinstance(staff, Mapping) and staff:
        result["project_hub"] = {**(result.get("project_hub") or {}),
                                 "staff_user_ids": {str(k): str(v) for k, v in staff.items()}}
    return result


def solo_settings(settings: Mapping[str, Any] | None, staff: Any) -> dict:
    """``solo_channel`` settings with Slack bot IDs taken from the vault's staff IDs.

    Every staff bot is a team bot; ``listener_profiles`` (employee ids) name the bots that only
    listen. IDs written directly in the settings are kept only while the vault has none."""
    result = dict(settings or {})
    ids = {str(k): str(v) for k, v in staff.items()} if isinstance(staff, Mapping) else {}
    if not ids:
        return result
    result["team_bots"] = sorted(set(ids.values()))
    if "listener_profiles" in result:
        result["listener_bots"] = sorted({ids[str(p)] for p in result.get("listener_profiles") or () if str(p) in ids})
    return result


def resolved(contract: Mapping[str, Any] | None) -> dict:
    """``fill`` with the running owner's roster and vault."""
    if not contract:
        return dict(contract or {})
    from hermes_facility import owner_vault, team_registry
    return fill(contract, team_registry.roster(), owner_vault.get("slack.staff_user_ids"))
