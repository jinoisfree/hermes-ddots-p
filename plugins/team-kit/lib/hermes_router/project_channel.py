"""Slack channel admission with opt-in project-thread continuity."""
import logging

logger = logging.getLogger(__name__)


async def channel_gate_allows(
    self, *, channel_id: str, routing_text: str, bot_uid: str, is_mentioned: bool,
    is_thread_reply: bool, event_thread_ts, user_id: str, team_id: str, is_dm: bool,
    force_process: bool) -> bool:
    """Channel/MPIM gate: respond in a free-response channel (still gated by
    ``thread_require_mention``), when @mentioned, or when a wake check passes. Always silent
    outside ``allowed_channels`` or when addressed to another user, except for an opt-in solo
    channel; ``force_process`` retains its existing channel and mention rules."""
    from hermes_router.solo_channel import is_solo, yields_to_listener

    solo = not force_process and await is_solo(self, channel_id, team_id)
    allowed_channels = self._slack_allowed_channels()
    if not solo and allowed_channels and channel_id not in allowed_channels:
        logger.debug("[Slack] Ignoring message in non-allowed channel: %s", channel_id)
        return False
    self_uids = {u for u in (bot_uid, self._bot_user_id) if u}
    if (
        self._slack_ignore_other_user_mentions()
        and not self._slack_message_mentions_self(routing_text, self_uids)
        and self._slack_message_addressed_to_other_user(routing_text, self_uids)):
        logger.debug(
            "[Slack] Ignoring message addressed to another user in channel %s", channel_id)
        return False
    if solo:
        return not yields_to_listener(self, routing_text)
    if not force_process and channel_id in set(self.config.extra.get("report_channels") or ()):
        # Shared owner report room: only an explicit @mention summons a bot (wake-word patterns do
        # not, so one bot's report thread never pulls in another). An un-mentioned reply wakes only
        # the bot whose report (or earlier conversation) owns the thread; top-level chatter wakes none.
        if routing_text and any(f"<@{uid}" in routing_text for uid in self_uids):
            return True
        if not is_thread_reply:
            return False
        return await self._should_wake_on_unmentioned_message(
            event_thread_ts=event_thread_ts, channel_id=channel_id, user_id=user_id,
            team_id=team_id, is_thread_reply=is_thread_reply,
            chat_type="dm" if is_dm else "group")
    project_channel = channel_id == self.config.extra.get("project_hub_channel_id")
    thread_gated = self._slack_thread_require_mention() and is_thread_reply and not is_mentioned and not project_channel
    if force_process:
        return True
    free_channel = self._slack_is_free_channel(channel_id)
    if not free_channel and self._slack_strict_mention() and not is_mentioned:
        return False  # Strict mode: ignore until @-mentioned again
    if thread_gated:
        logger.debug(
            "[Slack] Ignoring thread reply without mention "
            "(thread_require_mention=true): channel=%s thread_ts=%s", channel_id,
            event_thread_ts)
        return False
    if free_channel:
        return True
    if not is_mentioned:
        return await self._should_wake_on_unmentioned_message(
            event_thread_ts=event_thread_ts, channel_id=channel_id, user_id=user_id,
            team_id=team_id, is_thread_reply=is_thread_reply,
            chat_type="dm" if is_dm else "group")
    return True
