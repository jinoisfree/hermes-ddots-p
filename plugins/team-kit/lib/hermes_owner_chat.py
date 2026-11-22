"""Authenticated owner conversation transports, not unattended execution contexts.

Transport membership does not replace each caller's chat/user, role, background,
account-scope or provenance checks. hejo's paired gateway emits user_id=owner.
"""
OWNER_CHAT_PLATFORMS = frozenset({'slack', 'photon', 'hejo'})


def authenticated_owner(env, *, legacy_owner):
    """Keep each legacy transport's existing owner proof; authenticate hejo centrally."""
    import os
    flags = ('HERMES_CRON_SESSION', 'HERMES_SINGLE_QUERY_SESSION', 'HERMES_KANBAN_TASK')
    if os.environ.get('HERMES_KANBAN_TASK') or any(
            str(env(key, '')).lower() not in ('', '0', 'false') for key in flags):
        return False
    from tools.skill_provenance import is_background_review
    if is_background_review():
        return False
    platform = str(env('HERMES_SESSION_PLATFORM', '')).lower()
    user = env('HERMES_SESSION_USER_ID', '')
    if platform == 'hejo':
        return user == 'owner' and bool(env('HERMES_SESSION_CHAT_ID', ''))
    return platform in {'slack', 'photon'} and bool(user) and legacy_owner(user)


def current_owner_message(env):
    """Read the current hejo ingress through the public adapter; never transcript content."""
    import asyncio
    if env('HERMES_SESSION_PLATFORM', '') != 'hejo' or not authenticated_owner(env, legacy_owner=lambda _: False):
        return None
    from hermes_reply.plugin import current_hejo_turn
    binding = current_hejo_turn()
    if not binding:
        return None
    adapter, event, loop = binding
    source = event.source
    fields = {key: env('HERMES_SESSION_' + key, '') for key in
              ('PROFILE', 'CHAT_ID', 'THREAD_ID', 'MESSAGE_ID')}
    if (event.internal or event.user_id != 'owner' or source.user_id != 'owner'
            or not all(fields.values()) or source.platform.value != 'hejo'
            or fields['PROFILE'] != source.profile or fields['CHAT_ID'] != source.chat_id
            or fields['THREAD_ID'] != source.thread_id or fields['MESSAGE_ID'] != event.message_id):
        return None
    try:
        active = asyncio.get_running_loop()
    except RuntimeError:
        active = None
    query = getattr(adapter, 'owner_message', None)
    if not callable(query) or active is loop or loop.is_closed() or not loop.is_running():
        return None
    future = None
    try:
        future = asyncio.run_coroutine_threadsafe(query(fields['PROFILE'], fields['CHAT_ID'],
                                                       fields['THREAD_ID'], fields['MESSAGE_ID']), loop)
        result = future.result(timeout=5)
        if (not isinstance(result, dict) or result.get('msg_id') != fields['MESSAGE_ID']
                or result.get('chat_id') != fields['CHAT_ID'] or result.get('thread_id') != fields['THREAD_ID']
                or not isinstance(result.get('text'), str) or not result['text'].strip()):
            return None
        return dict(result)
    except Exception:
        if future is not None:
            future.cancel()
        return None


def answered_employee_message(env):
    """Bind a clicked employee post to the current, publicly verified owner ingress."""
    import asyncio
    owner = current_owner_message(env)
    if not owner:
        return None
    from hermes_reply.plugin import current_hejo_turn
    adapter, event, loop = current_hejo_turn()
    profile = env('HERMES_SESSION_PROFILE', '')
    query = getattr(adapter, 'employee_message' if owner.get('answer_to') else 'latest_employee_message', None)
    if not callable(query):
        return None
    future = None
    try:
        future = asyncio.run_coroutine_threadsafe(query(profile, owner['chat_id'],
                                                       owner['thread_id'], owner.get('answer_to') or owner['msg_id']), loop)
        result = future.result(timeout=5)
        if (not isinstance(result, dict) or result.get('employee') != profile
                or not result.get('msg_id')
                or (owner.get('answer_to') and result.get('msg_id') != owner['answer_to'])
                or result.get('chat_id') != owner['chat_id'] or result.get('thread_id') != owner['thread_id']
                or not isinstance(result.get('text'), str) or not result['text'].strip()):
            return None
        return dict(result)
    except Exception:
        if future is not None:
            future.cancel()
        return None


def current_owner_message_in_session(home, session_id, env):
    """Prove a persisted turn by its user-row transport id, never a process session-id fallback."""
    import sqlite3
    from pathlib import Path
    if not session_id:
        return None
    message = current_owner_message(env)
    if message is None:
        return None
    try:
        with sqlite3.connect((Path(home) / 'state.db').resolve().as_uri() + '?mode=ro', uri=True) as db:
            db.execute('PRAGMA query_only=ON')
            columns = {row[1] for row in db.execute('PRAGMA table_info(messages)')}
            summary = ' AND COALESCE(_compressed_summary,0)=0' if '_compressed_summary' in columns else ''
            row = db.execute("SELECT id FROM messages WHERE session_id=? AND role='user' "
                             "AND platform_message_id=?" + summary + " ORDER BY id DESC LIMIT 1",
                             (session_id, message['msg_id'])).fetchone()
        return (message, row[0]) if row else None
    except (OSError, sqlite3.Error):
        return None
