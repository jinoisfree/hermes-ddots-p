"""Common Router admission, run by team-kit ahead of the adapter's session keying.

Moved out of the gateway core (``gateway/run_common_router.py`` and the Slack adapter's
thread-owner gate): the plugin wraps each Slack/Photon adapter's ``handle_message`` and Slack's
``_channel_gate_allows`` so exactly one profile answers, with the same order as before.
"""
from __future__ import annotations

import asyncio
import contextvars
import copy
import json
import logging
import re
import time
from dataclasses import replace
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

# The gate sees Slack's raw routing text (mentions intact); the handle_message wrapper needs it to
# annotate the built event. Both run in the same per-message task, so a context variable carries it.
_SLACK_ROUTING: contextvars.ContextVar = contextvars.ContextVar("hermes_router_slack_routing", default=None)


def route_event(runner: Any, event: Any, adapter: Any = None, *, store_class: Any = None) -> bool:
    """Select and claim exactly one profile before adapter session keying."""
    contract = (getattr(getattr(runner, "config", None), "common_router", None)
                or getattr(adapter, "_hermes_router_contract", None) or {})
    if not contract.get("enabled") or bool(getattr(event, "internal", False)):
        return True

    source = getattr(event, "source", None)
    platform = str(getattr(getattr(source, "platform", None), "value", "") or "").lower()
    if platform not in {"slack", "photon", "bluebubbles"}:
        return True

    from hermes_router.project_threads import project_routing_input, routing_contract
    contract = routing_contract(contract, platform, str(getattr(source, "chat_id", "") or ""))
    routing_text, has_attachments = project_routing_input(event, contract)

    from hermes_router.common_router import ClaimStore, claim_key

    primary = str(getattr(runner, "_primary_profile_name", None) or "default")
    transport_profile = str(getattr(adapter, "_owner_profile", None) or primary)
    metadata = getattr(event, "metadata", None)
    if not isinstance(metadata, dict):
        metadata = {}
        event.metadata = metadata
    explicit_profile = str(metadata.get("common_router_explicit_profile") or "").strip() or None
    is_slack_dm = platform == "slack" and str(getattr(source, "chat_type", "") or "") == "dm"
    if is_slack_dm:
        explicit_profile = transport_profile
    # A reply button belongs to the bot that posted it: only that bot's app receives the click,
    # so classifying the label ("모두 배우기", "승인") by content would hand it to a profile
    # that never sees it and the click would vanish.
    raw = getattr(event, "raw_message", None)
    if platform == "slack" and isinstance(raw, dict) and raw.get("_hermes_button"):
        explicit_profile = transport_profile
    # A channel dedicated to one profile has no other owner to classify between.
    dedicated_profile = ((contract.get("dedicated_channels") or {}).get(platform) or {}).get(
        str(getattr(source, "chat_id", "") or "")
    )
    if dedicated_profile:
        explicit_profile = str(dedicated_profile)
    store = (store_class or ClaimStore)(
        contract["claim_database_path"],
        retention_seconds=int(contract.get("claim_retention_seconds") or 604800),
    )
    thread_id = str(getattr(source, "thread_id", None) or "").strip()
    thread_profile = None
    route_issue = None
    if thread_id:
        try:
            thread_profile, route_issue = store.resolve_thread(
                platform=platform,
                scope_id=getattr(source, "scope_id", None),
                chat_id=str(getattr(source, "chat_id", "") or ""),
                thread_id=thread_id,
                valid_profiles={
                    str(profile) for profile in (contract.get("profiles") or {}).values()
                },
                retention_seconds=int(
                    contract.get("thread_route_retention_seconds") or 2592000
                ),
            )
            if route_issue:
                logger.warning(
                    "Common Router ignored %s thread route: platform=%s chat=%s thread=%s",
                    route_issue,
                    platform,
                    getattr(source, "chat_id", ""),
                    thread_id,
                )
        except Exception:
            logger.warning(
                "Common Router thread route lookup failed; using fresh classification",
                exc_info=True,
            )
            thread_profile = None
            route_issue = "lookup_failed"
    elif platform in {"photon", "bluebubbles"}:
        # iMessage has no threads: a recent exchange in this chat plays the thread's role.
        try:
            thread_profile = store.recent_conversation_owner(
                platform=platform,
                scope_id=getattr(source, "scope_id", None),
                chat_id=str(getattr(source, "chat_id", "") or ""),
                valid_profiles={
                    str(profile) for profile in (contract.get("profiles") or {}).values()
                },
            )
        except Exception:
            logger.warning("Common Router recent-owner lookup failed", exc_info=True)
            thread_profile = None

    message_ref = str(
        getattr(event, "message_id", None) or getattr(source, "message_id", None) or ""
    ).strip()
    is_command = event.is_command()
    if is_command:
        if is_slack_dm or dedicated_profile:
            explicit_profile = transport_profile
        elif not explicit_profile:
            explicit_profile = (
                thread_profile
                if platform == "slack" and thread_id and thread_id != message_ref and thread_profile
                else transport_profile
            )

    pending_profile = None
    pending_issue = None
    if not explicit_profile:
        try:
            pending_profile, pending_issue = store.resolve_pending_owner(
                routing_text,
                platform=platform,
                scope_id=getattr(source, "scope_id", None),
                chat_id=str(getattr(source, "chat_id", "") or ""),
                thread_id=getattr(source, "thread_id", None),
                valid_profiles={
                    str(profile) for profile in (contract.get("profiles") or {}).values()
                },
            )
            if pending_issue:
                logger.warning(
                    "Common Router ignored %s pending approval route: platform=%s chat=%s",
                    pending_issue,
                    platform,
                    getattr(source, "chat_id", ""),
                )
        except Exception:
            logger.warning(
                "Common Router pending approval lookup failed; using normal routing",
                exc_info=True,
            )
            pending_profile = None
            pending_issue = "lookup_failed"

    from hermes_router.project_threads import select_project_profile
    from hermes_router.project_alerts import thread_hint
    thread_profile = thread_hint(contract, metadata, thread_profile)
    # A Slack thread stays with its owner; another staff member joins only when called.
    thread_locked = bool(
        platform == "slack" and thread_profile and thread_id and thread_id != message_ref
    )
    decision = select_project_profile(
        source,
        routing_text,
        contract,
        has_attachments=has_attachments,
        explicit_profile=explicit_profile,
        pending_profile=pending_profile,
        thread_profile=thread_profile,
        thread_locked=thread_locked,
    )
    if is_command:
        # A control command may target another bot without handing over the conversation.
        decision = replace(decision, persist_thread=False)
    if platform == "slack" and decision.profile != transport_profile:
        logger.debug(
            "Common Router dropped non-owner Slack delivery: selected=%s transport=%s",
            decision.profile,
            transport_profile,
        )
        return False

    _apply_mobile_profile(source, platform, decision.profile)

    message_id = str(
        getattr(event, "message_id", None)
        or getattr(source, "message_id", None)
        or ""
    ).strip()
    try:
        key = claim_key(
            platform=platform,
            scope_id=getattr(source, "scope_id", None),
            chat_id=str(getattr(source, "chat_id", "") or ""),
            thread_id=getattr(source, "thread_id", None),
            message_id=message_id,
        )
        claimed = store.claim(
            key=key,
            decision=decision,
            platform=platform,
            scope_id=getattr(source, "scope_id", None),
            chat_id=str(getattr(source, "chat_id", "") or ""),
            thread_id=getattr(source, "thread_id", None),
            message_id=message_id,
        )
    except Exception:
        logger.error("Common Router claim failed closed", exc_info=True)
        return False
    if not claimed:
        logger.info(
            "Common Router dropped duplicate inbound message: platform=%s message_id=%s",
            platform,
            message_id,
        )
        return False
    metadata["common_router"] = {
        "profile": decision.profile,
        "reason": decision.reason,
        "claim_key": key,
        "thread_profile": thread_profile,
        "thread_route_issue": route_issue,
    }
    if pending_profile or pending_issue:
        metadata["common_router"]["pending_profile"] = pending_profile
        metadata["common_router"]["pending_route_issue"] = pending_issue
    return True


def _apply_mobile_profile(source, platform, profile):
    if platform in {"photon", "bluebubbles"}:
        from gateway.session_identity import clear_identity
        clear_identity(source)
        source.profile = profile


def thread_owner(adapter: Any, *, channel_id: str, team_id: str, thread_ts: str) -> Optional[str]:
    """Return a saved owner only for a configured, allowed Router thread."""
    config = adapter.config.extra.get("common_router_thread_routes", {})
    if not isinstance(config, dict) or not config.get("enabled") or not thread_ts:
        return None
    allowed_channels = adapter._slack_allowed_channels()
    if allowed_channels and channel_id not in allowed_channels:
        return None
    try:
        from hermes_router.common_router import ClaimStore

        profile, issue = ClaimStore(str(config["database_path"])).resolve_thread(
            platform="slack",
            scope_id=team_id,
            chat_id=channel_id,
            thread_id=thread_ts,
            valid_profiles={str(value) for value in config.get("profiles", [])},
            retention_seconds=int(config.get("retention_seconds") or 2592000),
        )
        if issue:
            logger.warning(
                "[Slack] Common Router ignored %s thread route: channel=%s thread=%s",
                issue,
                channel_id,
                thread_ts,
            )
        return profile
    except Exception:
        logger.warning(
            "[Slack] Common Router thread route lookup failed: channel=%s thread=%s",
            channel_id,
            thread_ts,
            exc_info=True,
        )
        return None


async def slack_gate(adapter: Any, **kwargs: Any) -> bool:
    """Slack channel gate: the saved thread owner answers an unmentioned reply; else channel rules."""
    routing_text = kwargs.get("routing_text") or ""
    _SLACK_ROUTING.set((str(kwargs.get("channel_id") or ""), routing_text, kwargs.get("bot_uid")))
    if kwargs.get("is_thread_reply") and not re.search(r"<@[^>]+>", routing_text):
        owner = thread_owner(
            adapter,
            channel_id=kwargs.get("channel_id"),
            team_id=kwargs.get("team_id"),
            thread_ts=str(kwargs.get("event_thread_ts") or ""),
        )
        if owner == str(getattr(adapter, "_owner_profile", None) or "default"):
            return True
    from hermes_router.project_channel import channel_gate_allows
    return await channel_gate_allows(adapter, **kwargs)


def _routing_for(event: Any) -> Optional[tuple]:
    value = _SLACK_ROUTING.get()
    _SLACK_ROUTING.set(None)
    source = getattr(event, "source", None)
    if not value or value[0] != str(getattr(source, "chat_id", "") or ""):
        return None
    return value


class _DryClaimStore:
    """Shadow mode: real lookups, no claim or thread-route write."""

    def __new__(cls, *args, **kwargs):
        from hermes_router.common_router import ClaimStore

        class Dry(ClaimStore):
            def claim(self, **_kwargs):
                return True

        return Dry(*args, **kwargs)


def _shadow_copy(event: Any) -> Any:
    clone = copy.copy(event)
    clone.source = copy.copy(event.source)
    clone.metadata = dict(getattr(event, "metadata", None) or {})
    return clone


def _decision_view(event: Any, accepted: bool) -> dict:
    routed = (getattr(event, "metadata", None) or {}).get("common_router") or {}
    return {
        "accepted": bool(accepted and routed),
        "profile": routed.get("profile"),
        "reason": routed.get("reason"),
        "explicit": (getattr(event, "metadata", None) or {}).get("common_router_explicit_profile"),
        "origin": bool((getattr(event, "metadata", None) or {}).get("project_origin")),
        "source_profile": getattr(getattr(event, "source", None), "profile", None),
    }


def _write_shadow(home: Path, row: dict) -> None:
    try:
        path = Path(home) / "logs" / "router_shadow.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    except Exception:
        logger.debug("router shadow row not written", exc_info=True)


def install(adapter: Any, platform: str, *, shadow: bool, home: Path, contract=None) -> None:
    """Wrap one adapter; idempotent (every profile's team-kit offers the same factory)."""
    if getattr(adapter, "_hermes_router_installed", False):
        return
    adapter._hermes_router_installed = True
    if contract is not None:
        adapter._hermes_router_contract = contract
    if platform == "slack" and not shadow:
        async def gate(**kwargs):
            return await slack_gate(adapter, **kwargs)

        adapter._channel_gate_allows = gate
    original = adapter.handle_message

    async def handle_message(event):
        if not getattr(adapter, "_message_handler", None):
            return await original(event)
        if shadow:
            return await _shadow_handle(adapter, platform, original, event, home)
        if platform == "slack":
            routing = _routing_for(event)
            if routing:
                from hermes_router.project_alerts import annotate
                await annotate(adapter, event, routing[1], routing[2])
        if event.allow_gateway_control:
            from gateway.platforms.base import coerce_plaintext_gateway_command
            coerce_plaintext_gateway_command(event)
        try:
            admitted = await asyncio.to_thread(route_event, adapter.gateway_runner, event, adapter)
        except Exception:
            logger.error("[%s] Common Router failed closed before session admission",
                         getattr(adapter, "name", platform), exc_info=True)
            admitted = False
        if not admitted:
            event._gateway_accepted = False
            return None
        return await original(event)

    adapter.handle_message = handle_message


async def _shadow_handle(adapter: Any, platform: str, original: Any, event: Any, home: Path) -> Any:
    plugin = None
    try:
        clone = _shadow_copy(event)
        clone.metadata.pop("common_router", None)
        if event.allow_gateway_control:
            from gateway.platforms.base import coerce_plaintext_gateway_command
            coerce_plaintext_gateway_command(clone)
        accepted = await asyncio.to_thread(
            route_event, adapter.gateway_runner, clone, adapter, store_class=_DryClaimStore)
        plugin = _decision_view(clone, accepted)
    except Exception as exc:
        plugin = {"error": type(exc).__name__}
    result = await original(event)
    source = getattr(event, "source", None)
    _write_shadow(home, {
        "at": time.time(),
        "platform": platform,
        "transport": str(getattr(adapter, "_owner_profile", None) or "default"),
        "chat_id": str(getattr(source, "chat_id", "") or ""),
        "thread_id": str(getattr(source, "thread_id", "") or ""),
        "message_id": str(getattr(event, "message_id", "") or ""),
        "plugin": plugin,
        "core": _decision_view(event, True),
    })
    return result
