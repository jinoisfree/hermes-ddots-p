"""Opt-in channel ownership from Slack membership, excluding listener bots."""
import logging
import re
import time

logger = logging.getLogger(__name__)


def _settings(adapter):
    extra = getattr(getattr(adapter, "config", None), "extra", {})
    settings = extra.get("solo_channel", {}) if isinstance(extra, dict) else {}
    if not isinstance(settings, dict):
        return {}
    # Slack bot IDs live in the owner vault; the settings name employees, not IDs.
    from hermes_facility import owner_vault
    from hermes_router.owner_contract import solo_settings
    return solo_settings(settings, owner_vault.get("slack.staff_user_ids"))


def _eligible(adapter, channel_id):
    if _settings(adapter).get("enabled") is not True or not channel_id or channel_id.startswith("D"):
        return False
    extra = adapter.config.extra
    return not (
        adapter._is_ignored_channel(channel_id)
        or channel_id == extra.get("project_hub_channel_id")
        or channel_id in (extra.get("report_channels") or ())
    )


def cached_is_solo(adapter, channel_id):
    """Read a still-valid decision without issuing an API request."""
    if not _eligible(adapter, channel_id):
        return False
    cached = getattr(adapter, "_slack_solo_channel_cache", {}).get(channel_id)
    return bool(cached and cached[0] > time.monotonic() and cached[1])


async def is_solo(adapter, channel_id, team_id):
    """Only the receiving team bot may own a channel; unavailable membership denies it."""
    if not _eligible(adapter, channel_id):
        return False
    cache = getattr(adapter, "_slack_solo_channel_cache", None)
    if cache is None:
        cache = adapter._slack_solo_channel_cache = {}
    cached = cache.get(channel_id)
    if cached and cached[0] > time.monotonic():
        return cached[1]
    settings = _settings(adapter)
    solo = False
    cache_seconds = 300
    try:
        cache_seconds = max(0, float(settings.get("cache_seconds", 300)))
        client = adapter._get_client(channel_id, team_id=team_id)
        members = set()
        cursor = ""
        seen_cursors = set()
        while True:
            response = await client.conversations_members(channel=channel_id, limit=200, cursor=cursor)
            if response.get("ok") is False:
                raise ValueError("Slack membership request was rejected")
            members.update(response.get("members") or ())
            cursor = (response.get("response_metadata") or {}).get("next_cursor", "").strip()
            if not cursor:
                break
            if cursor in seen_cursors:
                raise ValueError("Slack membership pagination repeated a cursor")
            seen_cursors.add(cursor)
        bot_uid = (getattr(adapter, "_team_bot_user_ids", {}) or {}).get(team_id) or adapter._bot_user_id
        speakers = (members & set(settings.get("team_bots") or ())) - set(settings.get("listener_bots") or ())
        solo = bool(bot_uid and speakers == {bot_uid})
    except Exception as exc:
        # Do not log client/exception details: they may contain credential-bearing request data.
        logger.warning("[Slack] Solo channel membership unavailable: channel=%s error=%s", channel_id, type(exc).__name__)
    cache[channel_id] = (time.monotonic() + cache_seconds, solo)
    return solo


def yields_to_listener(adapter, text):
    """An explicit listener call keeps the channel's ordinary speaker silent."""
    settings = _settings(adapter)
    text = text or ""
    if any(re.search(r"<@" + re.escape(uid) + r"(?:\|[^>]*)?>", text)
           for uid in settings.get("listener_bots") or ()):
        return True
    for pattern in settings.get("yield_patterns") or ():
        try:
            if re.search(pattern, text, re.IGNORECASE):
                return True
        except re.error:
            logger.warning("[Slack] Invalid solo channel listener pattern; yielding")
            return True
    return False
