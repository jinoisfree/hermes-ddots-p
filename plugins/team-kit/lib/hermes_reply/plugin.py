"""Bind owner report controls to one Slack adapter through the platform factory."""
from __future__ import annotations

from contextvars import ContextVar
from functools import wraps
import inspect
import logging
import re
import sys

from . import reply_buttons as rb

logger = logging.getLogger(__name__)

# A reply that is several independent items (one owner-facing post per mail or event; scheduled reports
# 2026-11-05, conversation replies 2026-11-06) puts this line between them. A send splits on it, at the
# top level or in a thread: every piece then goes through the normal marker, policy and colour path as a
# post of its own, so its buttons belong to that piece alone. Sends that cannot be several messages keep
# one post and only lose the line (see ``splittable``).
SPLIT_MARKER = '[[글 나누기]]'
_SPLIT_LINE = re.compile(r'^[ \t]*' + re.escape(SPLIT_MARKER) + r'[ \t]*$\n?', re.M)


def _without_split_lines(content):
    return _SPLIT_LINE.sub('', content) if isinstance(content, str) and SPLIT_MARKER in content else content


def _pieces(content):
    return [piece.strip() for piece in _SPLIT_LINE.split(content) if piece.strip()]


def register(ctx):
    config = ctx.get_config('reply_buttons_plugin', {}) or {}
    if not config.get('enabled', False):
        return

    def reply_buttons_factory(native, adapter):
        install(adapter, native)

    reply_buttons_factory.__qualname__ = 'hermes_reply.reply_buttons_factory.slack'
    ctx.register_platform_handler('slack', reply_buttons_factory)


def _plain(content):
    content = _without_split_lines(content)
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
        content = _without_split_lines(content)
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

    async def post(chat_id, content, reply_to, metadata):
        token = send_meta.set(metadata or {})
        try:
            return await original['send'](chat_id, content, reply_to, metadata)
        finally:
            send_meta.reset(token)

    async def post_pieces(chat_id, pieces, reply_to, metadata):
        """One post per piece (top level or in the thread), in order. A piece that fails does not stop the others (each is its
        own item); a failure after something was posted is reported as a partial delivery so the caller
        never re-sends the whole text."""
        results = []
        for piece in pieces:
            try:
                results.append(await post(chat_id, piece, reply_to, metadata))
            except Exception as exc:
                logger.error('reply split: piece %d of %d failed: %s', len(results) + 1, len(pieces), exc)
                results.append(SendResult(success=False, error=str(exc)))
        done = [r for r in results if r.success]
        failed = [r for r in results if not r.success]
        ids = tuple(r.message_id for r in done if r.message_id)
        if not failed:
            return SendResult(success=True, message_id=ids[-1] if ids else None, raw_response=done[-1].raw_response,
                              continuation_message_ids=ids[:-1])
        if not done:
            return failed[0]
        logger.error('reply split: %d of %d posts delivered, then failed: %s', len(done), len(pieces), failed[0].error)
        return SendResult(success=False, message_id=ids[-1] if ids else None,
                          error=f'{len(done)}/{len(pieces)} posts delivered: {failed[0].error}',
                          raw_response={'partial_overflow': True, 'delivered_chunks': len(done),
                                        'total_chunks': len(pieces)},
                          continuation_message_ids=ids[:-1])

    def splittable(chat_id, metadata):
        """Split a reply into posts only where each piece can be its own message: not an interim or
        editable send, not while a native stream is open (its text is edited in place), and never for a
        slash reply (the first piece is private; the rest would be public)."""
        md = metadata or {}
        if md.get('_interim_send') or md.get('expect_edits'):
            return False
        slash = getattr(sys.modules.get(type(adapter).__module__), '_slash_user_id', None)
        if slash is not None and slash.get():
            return False
        streams = getattr(adapter, '_active_streams', None)
        key = adapter._stream_key(chat_id, md) if streams and callable(getattr(adapter, '_stream_key', None)) else None
        stream = streams.get(key) if key else None
        # The waiting placeholder is the first piece's message; a real native stream is not.
        return not (stream and not stream.get('eager_response_animation'))

    @wraps(original['send'])
    async def send(chat_id, content, reply_to=None, metadata=None):
        if isinstance(content, str) and SPLIT_MARKER in content:
            pieces = _pieces(content)
            if len(pieces) > 1 and splittable(chat_id, metadata):
                return await post_pieces(chat_id, pieces, reply_to, metadata)
            content = _without_split_lines(content)
        return await post(chat_id, content, reply_to, metadata)

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

    build_original = getattr(adapter, '_build_message_event', None)
    if callable(build_original) and {'event', 'channel_context'}.issubset(inspect.signature(build_original).parameters):
        @wraps(build_original)
        async def build_message_event(event, **kwargs):
            """A button click says which message it pressed: lead the turn with that message so the agent
            handles that item only. The click text stays the bare label (script handlers read it)."""
            message = await build_original(event, **kwargs)
            pressed = rb.clicked_context(event.get('_hermes_button')) if isinstance(event, dict) else ''
            if pressed:
                message.channel_context = pressed + (message.channel_context or '')
            return message
        adapter._build_message_event = build_message_event
    else:
        logger.warning('reply buttons: adapter has no usable _build_message_event; clicks will not name their message')

    prefilter_original = getattr(adapter, '_prefilter_inbound', None)
    if callable(prefilter_original) and {'event', 'payload'}.issubset(inspect.signature(prefilter_original).parameters):
        @wraps(prefilter_original)
        async def prefilter_inbound(event, payload):
            """A button answered from ddots arrives as an owner message naming the post it pressed."""
            return await prefilter_original(await rb.adopt_click(adapter, event) if isinstance(event, dict) else event, payload)
        adapter._prefilter_inbound = prefilter_inbound
    else:
        logger.warning('reply buttons: adapter has no usable _prefilter_inbound; ddots clicks stay ordinary messages')

    for name, wrapper in (('send', send), ('edit_message', edit), ('_post_chunks', post_chunks),
                          ('_call_with_block_fallback', call), ('_maybe_blocks', maybe_blocks),
                          ('_commit_stream', commit), ('_peer_bot_drop', peer_drop)):
        setattr(adapter, name, wrapper)
    adapter._hermes_reply_installed = True
    if native is not None:
        rb.register(adapter, native)
    return True
