"""Bind owner report controls to one Slack adapter through the platform factory."""
from __future__ import annotations

from contextvars import ContextVar
from functools import wraps
import inspect
import logging

from . import reply_buttons as rb

logger = logging.getLogger(__name__)


def register(ctx):
    config = ctx.get_config('reply_buttons_plugin', {}) or {}
    if not config.get('enabled', False):
        return

    def reply_buttons_factory(native, adapter):
        install(adapter, native)

    reply_buttons_factory.__qualname__ = 'hermes_reply.reply_buttons_factory.slack'
    ctx.register_platform_handler('slack', reply_buttons_factory)


def _plain(content):
    text, checks = rb.extract_checklist(content)
    text, labels = rb.extract(text)
    return rb._refused(text, checks or labels) if checks or labels else text


def _compatible(adapter):
    contracts = {
        'send': ('chat_id', 'content', 'reply_to', 'metadata'),
        'edit_message': ('chat_id', 'message_id', 'content', 'finalize', 'metadata'),
        '_post_chunks': ('chat_id', 'team_id', 'content', 'formatted', 'thread_ts'),
        '_call_with_block_fallback': ('client_fn', 'method', 'kwargs', 'verb'),
        '_commit_stream': ('key', 'stream', 'text', 'metadata', 'delta', 'replace'),
        '_peer_bot_drop': ('event', 'user_id', 'bot_uid', 'channel_id', 'team_id', 'is_mentioned'),
        '_maybe_blocks': ('content',),
    }
    for name, parameters in contracts.items():
        fn = getattr(adapter, name, None)
        if not callable(fn) or not set(parameters).issubset(inspect.signature(fn).parameters):
            return False
    return all(callable(getattr(adapter, name, None)) for name in (
        '_get_client', '_early_reject_unauthorized', '_handle_slack_message',
        '_extra_flag', '_append_feedback_block', '_resolve_thread_ts', '_metadata_team_id'))


def _install_plain(adapter):
    """An upstream seam changed: send the choices as words, never broken controls."""
    for name in ('send', 'edit_message'):
        original = getattr(adapter, name, None)
        if not callable(original):
            continue
        signature = inspect.signature(original)
        if 'content' not in signature.parameters:
            continue

        def wrapper_for(fn, sig):
            @wraps(fn)
            async def plain(*args, **kwargs):
                bound = sig.bind(*args, **kwargs)
                if isinstance(bound.arguments.get('content'), str):
                    bound.arguments['content'] = _plain(bound.arguments['content'])
                return await fn(*bound.args, **bound.kwargs)
            return plain

        setattr(adapter, name, wrapper_for(original, signature))


def install(adapter, native=None):
    if getattr(adapter, '_hermes_reply_installed', False) is True:
        if native is not None:
            rb.register(adapter, native)
        return True
    try:
        compatible = _compatible(adapter)
        from .layout import render_blocks, report_sections
        from .blocks import sanitize_blocks
        from gateway.platforms.base import SendResult
    except (ImportError, AttributeError, TypeError, ValueError):
        compatible = False
    if not compatible:
        logger.warning('reply buttons: adapter contract changed; choices will be sent as text')
        _install_plain(adapter)
        return False

    # Each adapter owns its ContextVars: concurrent threads and other profiles never share a frame.
    delivery = ContextVar('reply_delivery', default=None)
    send_meta = ContextVar('reply_send_metadata', default=None)
    stream_probe = ContextVar('reply_stream_probe', default=False)
    original = {name: getattr(adapter, name) for name in (
        'send', 'edit_message', '_post_chunks', '_call_with_block_fallback',
        '_commit_stream', '_maybe_blocks', '_peer_bot_drop')}

    def controls(content):
        text, checks = rb.extract_checklist(content)
        text, buttons = rb.extract(text)
        return text, checks or buttons, bool(checks)

    def track(frame, ts):
        if not ts or not frame['thread']:
            return
        if frame['labels']:
            rb.remember_question(adapter, frame['chat'], frame['team'], frame['thread'], ts)
        elif frame['final']:
            rb.close_working(adapter, channel_id=frame['chat'], team_id=frame['team'],
                             thread_ts=frame['thread'])

    @wraps(original['send'])
    async def send(chat_id, content, reply_to=None, metadata=None):
        token = send_meta.set(metadata or {})
        try:
            return await original['send'](chat_id, content, reply_to, metadata)
        finally:
            send_meta.reset(token)

    @wraps(original['_post_chunks'])
    async def post_chunks(chat_id, team_id, content, formatted, thread_ts):
        text, labels, checklist = controls(content)
        if text != content:
            formatted = adapter.format_message(text)
        if not formatted or not formatted.strip():
            return None
        metadata = send_meta.get() or {}
        frame = dict(chat=chat_id, team=team_id, thread=thread_ts, labels=labels,
                     checklist=checklist, final=not (metadata.get('_interim_send') or metadata.get('expect_edits')),
                     remaining=len(adapter.truncate_message(formatted, adapter.MAX_MESSAGE_LENGTH)))
        token = delivery.set(frame)
        try:
            result = await original['_post_chunks'](chat_id, team_id, text, formatted, thread_ts)
            track(frame, result.get('ts') if result else None)
            return result
        finally:
            delivery.reset(token)

    @wraps(original['edit_message'])
    async def edit(chat_id, message_id, content, *, finalize=False, metadata=None):
        text, labels, checklist = controls(content) if finalize else (content, [], False)
        frame = dict(chat=chat_id, team=adapter._metadata_team_id(metadata),
                     thread=adapter._resolve_thread_ts(None, metadata), labels=labels,
                     checklist=checklist, final=finalize, remaining=1)
        state = rb._message_state(adapter, chat_id, message_id)
        async with state['lock']:
            if state['answered']:
                return SendResult(success=True, message_id=message_id)
            token = delivery.set(frame if finalize else None)
            try:
                result = await original['edit_message'](chat_id, message_id, text,
                                                        finalize=finalize, metadata=metadata)
                if finalize and result.success:
                    track(frame, message_id)
                return result
            finally:
                delivery.reset(token)

    @wraps(original['_call_with_block_fallback'])
    async def call(client_fn, method, kwargs, verb):
        frame = delivery.get()
        if frame and method in ('chat_postMessage', 'chat_update'):
            kwargs = dict(kwargs)
            blocks, attachments = kwargs.get('blocks'), kwargs.get('attachments')
            if blocks and adapter._extra_flag('report_sections'):
                laid = report_sections(blocks)
                if laid:
                    blocks, attachments = laid
            frame['remaining'] -= 1
            if frame['labels'] and frame['remaining'] == 0:
                blocks, attachments = rb.question_layout(
                    blocks, attachments, kwargs.get('text', ''), frame['labels'], checklist=frame['checklist'])
            if blocks:
                kwargs['blocks'] = blocks
                if attachments:
                    kwargs['attachments'] = attachments
        return await original['_call_with_block_fallback'](client_fn, method, kwargs, verb)

    @wraps(original['_maybe_blocks'])
    def maybe_blocks(content):
        # The core stream finalizer asks whether a final edit is needed. A marker requires that
        # edit even with rich blocks off; this probe is never sent to Slack.
        if stream_probe.get() and controls(content)[0] != content:
            return [{'type': 'section', 'text': {'type': 'mrkdwn', 'text': ' '}}]
        if (adapter._extra_flag('report_sections') and adapter._extra_flag('rich_blocks')
                and not (adapter._extra_flag('markdown_blocks') and adapter._markdown_block_payload(content))):
            return sanitize_blocks(adapter._append_feedback_block(
                render_blocks(content, mrkdwn_fn=adapter.format_message, arrows=True)))
        return original['_maybe_blocks'](content)

    @wraps(original['_commit_stream'])
    async def commit(key, stream, text, metadata, delta='', replace=False):
        token = stream_probe.set(True)
        try:
            result = await original['_commit_stream'](key, stream, text, metadata, delta, replace)
            if result is not None and result.success and not controls(text)[1]:
                rb.close_working(adapter, channel_id=key[1], team_id=key[0], thread_ts=key[2])
            return result
        finally:
            stream_probe.reset(token)

    @wraps(original['_peer_bot_drop'])
    async def peer_drop(event, user_id, bot_uid, channel_id, team_id, is_mentioned):
        dropped = await original['_peer_bot_drop'](event, user_id, bot_uid, channel_id, team_id, is_mentioned)
        root = event.get('thread_ts')
        if not dropped and root and root != event.get('ts') and user_id and not event.get('_hermes_force_process'):
            rb.note_typed_answer(adapter, channel_id=channel_id, team_id=team_id,
                                 root_ts=str(root), user_id=user_id, bot_uid=bot_uid)
        return dropped

    for name, wrapper in (('send', send), ('edit_message', edit), ('_post_chunks', post_chunks),
                          ('_call_with_block_fallback', call), ('_maybe_blocks', maybe_blocks),
                          ('_commit_stream', commit), ('_peer_bot_drop', peer_drop)):
        setattr(adapter, name, wrapper)
    adapter._hermes_reply_installed = True
    if native is not None:
        rb.register(adapter, native)
    return True
