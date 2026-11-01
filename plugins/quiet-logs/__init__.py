"""Keep known-harmless third-party and core log lines out of the gateway error log.

Lives here rather than in hermes-agent so the core checkout carries no change for it. Loggers are
process-wide, so enabling this for the default profile covers every profile the gateway serves.
"""
from __future__ import annotations

import logging
from functools import wraps

# logger name -> message fragment to drop
SILENCED = {
    # Logged on every Slack connect, once per profile. Hermes builds the Bolt app from a client that
    # already carries the token, and Bolt also reads SLACK_BOT_TOKEN, so no caller change avoids it.
    "slack_bolt.AsyncApp": "`token` will be unused",
    # Background memory/skill review inherits the completed turn's usage ledger; its later
    # events do not indicate missing usage from the user's completed response.
    "agent.turn_metrics": "late usage event after task footer finalized",
}


class MessageFilter(logging.Filter):
    def __init__(self, fragment: str) -> None:
        super().__init__()
        self.fragment = fragment

    def filter(self, record: logging.LogRecord) -> bool:
        return self.fragment not in record.getMessage()


def install_chat_notice_filter() -> None:
    """Preserve the legacy Slack-only, translated full-message home-hint filter."""
    try:
        from agent.i18n import t
        from gateway.config import Platform
        from gateway.run_notifications import GatewayNotificationsMixin
    except ImportError:
        logging.getLogger(__name__).warning('Slack home-channel hint filter is unavailable in this Hermes version.')
        return
    original = getattr(GatewayNotificationsMixin, '_deliver_platform_notice', None)
    if not callable(original):
        logging.getLogger(__name__).warning('Slack home-channel hint delivery hook is unavailable in this Hermes version.')
        return
    if getattr(original, '_moyo_home_hint_filter', False):
        return

    @wraps(original)
    async def deliver(self, source, content):
        if getattr(source, 'platform', None) == Platform.SLACK and content == t(
            'gateway.notify.no_home_channel', platform='Slack', sethome_cmd='/hermes sethome',
        ):
            return None
        return await original(self, source, content)

    deliver._moyo_home_hint_filter = True
    GatewayNotificationsMixin._deliver_platform_notice = deliver


def register(ctx) -> None:
    for name, fragment in SILENCED.items():
        target = logging.getLogger(name)
        if not any(getattr(existing, "fragment", None) == fragment for existing in target.filters):
            target.addFilter(MessageFilter(fragment))
    install_chat_notice_filter()
