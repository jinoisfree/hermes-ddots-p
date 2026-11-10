"""Native-dispatch authority for app packs, separate from caller-controlled tool input."""
from contextvars import ContextVar
from contextlib import contextmanager
import hashlib
import json
import os
from hermes_governance import write_policy

_NATIVE = ContextVar('app_tool_native_dispatch', default=None)
_SOURCE = ContextVar('app_tool_source', default=None)


@contextmanager
def source(values):
    token = _SOURCE.set(dict(values))
    try: yield
    finally: _SOURCE.reset(token)


def env(key, default=''):
    if _SOURCE.get() is not None: return _SOURCE.get().get(key, default)
    from gateway.session_context import get_session_env
    return get_session_env(key, default) or os.environ.get(key, default)


def conversation():
    return {key.lower(): env('HERMES_SESSION_' + key) for key in ('PLATFORM', 'SCOPE_ID', 'CHAT_ID', 'THREAD_ID', 'USER_ID')}


@contextmanager
def host_source(home):
    """Reuse authenticated button identity for existing native handler checks."""
    from gateway.session_context import set_session_vars,clear_session_vars
    from hermes_facility.app_registry import profile_of
    who=conversation()
    tokens=set_session_vars(platform=who['platform'],user_id=who['user_id'],chat_id=who['chat_id'],
        thread_id=who['thread_id'],scope_id=who['scope_id'],profile=profile_of(home),cron_session=False)
    try:yield
    finally:clear_session_vars(tokens)


def signature(tool, args):
    return hashlib.sha256(json.dumps([tool, args, conversation()], sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def authorized(tool, args): return _NATIVE.get() == signature(tool, args)


@contextmanager
def native(tool, args):
    token = _NATIVE.set(signature(tool, args))
    try: yield
    finally: _NATIVE.reset(token)


def register(ctx, home, name, schema, handler, approval=None):
    ctx.register_tool(name=name, toolset='team-kit', schema=schema, handler=lambda args, **kw: handler(home, args, **kw))
    def gate(tool_name='', args=None, **context):
        if tool_name != name: return None
        if approval is not None: return approval(home, args or {})
        return write_policy.gate(name, args or {}, owner=write_policy.owner_chat(home, env),
                                 unattended=write_policy.background(env))
    def execution(tool_name, args, next_call, **context):
        if tool_name != name: return next_call(args)
        kind = write_policy.classify(name, args)
        if kind != write_policy.READ and not write_policy.owner_chat(home, env):
            return json.dumps({'ok': False, 'error': 'APP_OWNER_CHAT_REQUIRED'})
        # This middleware is entered by the native dispatcher after its approval gate.
        with native(name, args): return next_call(args)
    ctx.register_hook('pre_tool_call', gate)
    ctx.register_middleware('tool_execution', execution)
