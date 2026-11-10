"""work-assistant's bounded company-mail tools. Approval previews freeze message IDs.

The dispatcher enters execution() only AFTER its native approval hook succeeds.
An approved=True model argument never grants permission to a direct handler.
"""

# Owner-specific text is rendered from private policy; public source stays generic.
from pathlib import Path as _OwnerPath
import sys as _owner_sys
_owner_library = str((_OwnerPath(__file__).resolve().parent / '../..').resolve())
if _owner_library not in _owner_sys.path:
    _owner_sys.path.insert(0, _owner_library)
from hermes_facility.owner_text import render as _owner_text

from contextlib import contextmanager
from contextvars import ContextVar
import hashlib
import json
import re
import threading
import time
from hermes_facility import team_registry as team

BASIC = frozenset({'label_create','label_apply','inbox_restore','filter_create','filter_delete','mail_organize'})
MAIL_READS = frozenset({'mailboxes', 'rules_list'})
MAIL_WRITES = frozenset({'mailbox_create', 'mail_move', 'mail_mark', 'mail_trash',
    'rule_create', 'rule_delete', 'mail_app_organize'})
GMAIL_WRITES = frozenset({'trash', 'untrash', 'modify', 'label_delete', 'label_rename', 'draft_create'})
COMPOSE = frozenset({'reply', 'forward'})
WRITES = MAIL_WRITES | GMAIL_WRITES | COMPOSE
ACTIONS = WRITES | MAIL_READS
EXECUTION = ContextVar('full_mail_native_dispatch', default='')
SNAPSHOTS, LOCK = {}, threading.RLock()
COMMON = {'action', 'account', 'approved', 'request_plan'}
FIELDS = {
    'label_create':{'label_name'},
    'filter_create':{'criteria','label_id','skip_inbox','mark_read'},
    'filter_delete':{'filter_id'},
    'mail_organize':{'rules','delete_filter_ids','restore_inbox_queries'},
    'label_apply': {'query','label_id','skip_inbox'}, 'inbox_restore': {'query'},
    'mailboxes': set(), 'rules_list': set(), 'mailbox_create': {'mailbox'},
    'mail_move': {'ids', 'mail_conditions', 'match', 'source_mailbox', 'mailbox'},
    'mail_mark': {'ids', 'mail_conditions', 'match', 'source_mailbox', 'read', 'flagged'},
    'mail_trash': {'ids', 'mail_conditions', 'match', 'source_mailbox'},
    'rule_create': {'rule_name', 'mail_conditions', 'match', 'mailbox', 'mark_read'},
    'rule_delete': {'rule_name'},
    'mail_app_organize': {'rule_name', 'mail_conditions', 'match', 'mailbox', 'mark_read'},
    'trash': {'ids', 'query'}, 'untrash': {'ids', 'query'},
    'modify': {'ids', 'query', 'read', 'starred', 'archive', 'spam', 'add_label_ids', 'remove_label_ids'},
    'label_delete': {'label_id'}, 'label_rename': {'label_id', 'label_name'},
    **{a: {'message_id', 'to', 'cc', 'subject', 'body', 'attachments'}
       for a in ('send', 'reply', 'forward', 'draft_create')},
}


def account(td, args):
    cfg = td.personal_scopes.config(td)
    if args.get('action') in BASIC:
        chosen=td.personal_scopes.mailbox(td,args,cfg) if cfg is not None else args.get('account') or td._gmail_account()
        return td.personal_scopes.normalize_mail_account(td,chosen,cfg)
    return td.personal_scopes.normalize_mail_account(td,
        args.get('account') or (cfg or {}).get('company', {}).get('gmail') or td._gmail_account(), cfg)


def app_grant(td):
    from hermes_facility.app_registry import tool_granted
    from hermes_constants import get_hermes_home
    return tool_granted(get_hermes_home(), 'gmail_direct') is True


def is_mail(td, args):
    from hermes_facility.app_scope import selection
    from hermes_constants import get_hermes_home
    selected = selection(get_hermes_home(), 'mail_accounts')
    if selected is not None:
        return str(args.get('account') or '').casefold() in {str(v).casefold() for v in selected}
    cfg = td.personal_scopes.config(td) or {}
    return account(td, args) in {str(x).casefold() for x in cfg.get('company', {}).get('mail_accounts', [])}


def handles(td, args):
    return args.get('action') in ACTIONS | BASIC or (args.get('action') == 'send' and is_mail(td, args))


def problem(td, args):
    if p := td.personal_scopes.role_problem(td, 'gmail_direct', args):
        return p
    if args.get('action') in BASIC and (denied:=td._personal_owner_error('gmail_direct')):
        return json.loads(denied).get('error','APP_OWNER_CHAT_REQUIRED')
    if td.personal_scopes.background(td):
        return 'PERSONAL_SCOPE_BACKGROUND_REFUSED: 새 메일 쓰기·폴더·규칙 조회는 소유자 대화에서만 가능하다.'
    if args.get('action') in BASIC:
        if td.get_session_env('HERMES_SESSION_PLATFORM','') not in {'slack','photon'} or not td.get_session_env('HERMES_SESSION_USER_ID','') or not td.get_session_env('HERMES_SESSION_CHAT_ID',''):
            return 'PERSONAL_SCOPE_OWNER_CHAT_REQUIRED'
        if is_mail(td,args):return 'MAIL_BACKEND_ACTION_MISMATCH'
        return None
    cfg = td._PLUGIN_CONTEXT.get_config('gmail', {}) if td._PLUGIN_CONTEXT else {}
    scopes = td.personal_scopes.config(td) or {}
    if not (app_grant(td) and is_mail(td, args)) and (not team.has_role(td.personal_roles.profile(td), 'work') or cfg.get('full_mail_tools') is not True
            or not scopes.get('enabled') or scopes.get('invalid')):
        return _owner_text('FULL_MAIL_TOOLS_DISABLED: <<work_name>> 회사 메일 전용이다.')
    if (td.get_session_env('HERMES_SESSION_PLATFORM', '') not in {'slack', 'photon'}
            or not td.get_session_env('HERMES_SESSION_CHAT_ID', '')
            or not td.get_session_env('HERMES_SESSION_USER_ID', '')):
        return 'PERSONAL_SCOPE_OWNER_CHAT_REQUIRED'
    if is_mail(td, args) and cfg.get('mail_app_accounts_enabled') is False:
        return 'MAIL_APP_ACCOUNTS_DISABLED'
    action = args.get('action')
    if (action in MAIL_READS | MAIL_WRITES and not is_mail(td, args)) or (
            action in GMAIL_WRITES and is_mail(td, args)):
        return 'MAIL_BACKEND_ACTION_MISMATCH'
    return None


def validate(args, mail=False):
    action = args.get('action')
    if action not in FIELDS or set(args) - COMMON - FIELDS[action]:
        raise ValueError('MAIL_UNSUPPORTED_FIELDS_OR_ACTION')
    if action in BASIC:
        from . import gmail_rules
        gmail_rules.validate_operation(action,args)
    for field in ('read', 'flagged', 'starred', 'archive', 'spam', 'mark_read'):
        if field in args and type(args[field]) is not bool:
            raise ValueError('MAIL_INVALID_BOOLEAN')
    for field in ('mailbox', 'rule_name', 'label_id', 'label_name'):
        if field in args and (not isinstance(args[field], str) or not args[field].strip() or len(args[field]) > 240):
            raise ValueError('MAIL_INVALID_' + field.upper())
    if action in {'mailbox_create', 'mail_move', 'rule_create', 'mail_app_organize'}:
        path = str(args.get('mailbox') or '')
        if not path or any(p in {'', '.', '..'} for p in path.split('/')):
            raise ValueError('MAIL_MAILBOX_REQUIRED')
    conditions = args.get('mail_conditions')
    if conditions is not None:
        if (not isinstance(conditions, list) or not 1 <= len(conditions) <= 10 or any(
                not isinstance(c, dict) or set(c) != {'field', 'contains'} or c['field'] not in {'from', 'to', 'subject'}
                or not isinstance(c['contains'], str) or not c['contains'].strip() or len(c['contains']) > 300 for c in conditions)):
            raise ValueError('MAIL_INVALID_CONDITIONS')
    if args.get('match', 'all') not in {'all', 'any'}:
        raise ValueError('MAIL_INVALID_MATCH')
    if action in {'rule_create', 'mail_app_organize'} and (not conditions or not args.get('rule_name')):
        raise ValueError('MAIL_RULE_FIELDS_REQUIRED')
    if action == 'rule_delete' and not str(args.get('rule_name') or '').startswith('Hermes:'):
        raise ValueError('MAIL_RULE_DELETE_HERMES_ONLY')
    selection = action in {'mail_move', 'mail_mark', 'mail_trash', 'trash', 'untrash', 'modify'}
    if selection:
        ids = args.get('ids')
        if bool(ids) == bool(conditions if mail else args.get('query')):
            raise ValueError('MAIL_EXACTLY_ONE_SELECTOR_REQUIRED')
        if ids is not None and (not isinstance(ids, list) or not 1 <= len(ids) <= 500 or any(
                not isinstance(x, str) or not re.fullmatch(r'm[0-9]{1,18}' if mail else r'[0-9a-fA-F]{1,32}', x) for x in ids)):
            raise ValueError('MAIL_INVALID_IDS_OR_LIMIT')
        if not mail and not ids and (not isinstance(args.get('query'), str) or not args['query'].strip()):
            raise ValueError('MAIL_QUERY_REQUIRED')
    if action == 'mail_mark' and not {'read', 'flagged'} & args.keys():
        raise ValueError('MAIL_MARK_FIELDS_REQUIRED')
    if action == 'modify' and not {'read', 'starred', 'archive', 'spam', 'add_label_ids', 'remove_label_ids'} & args.keys():
        raise ValueError('GMAIL_MODIFY_FIELDS_REQUIRED')
    for field in ('add_label_ids', 'remove_label_ids'):
        if field in args and (not isinstance(args[field], list) or len(args[field]) > 100 or any(
                not isinstance(x, str) or not x for x in args[field])):
            raise ValueError('GMAIL_INVALID_LABEL_IDS')
    if action in {'label_delete', 'label_rename'} and not args.get('label_id'):
        raise ValueError('GMAIL_USER_LABEL_REQUIRED')
    if action == 'label_rename' and not args.get('label_name'):
        raise ValueError('GMAIL_LABEL_NAME_REQUIRED')
    if action in {'reply', 'forward'} and not re.fullmatch(r'm[0-9]{1,18}' if mail else r'[0-9a-fA-F]{1,32}', str(args.get('message_id') or '')):
        raise ValueError('MAIL_INVALID_MESSAGE_ID')
    if action in {'send', 'reply', 'forward', 'draft_create'}:
        if not isinstance(args.get('body'), str) or not args['body'].strip():
            raise ValueError('MAIL_BODY_REQUIRED')
        if action != 'reply' and not str(args.get('to') or '').strip():
            raise ValueError('MAIL_RECIPIENT_REQUIRED')
        if action in {'send', 'draft_create'} and not str(args.get('subject') or '').strip():
            raise ValueError('MAIL_SUBJECT_REQUIRED')


def key(td, args, context=None):
    from tools.approval_context import _approval_session_id, _approval_turn_id
    context = context or {}
    identity = [td.personal_roles.profile(td), td.get_session_env('HERMES_SESSION_USER_ID', ''),
                td.get_session_env('HERMES_SESSION_CHAT_ID', ''), td.get_session_env('HERMES_SESSION_THREAD_ID', ''),
                context.get('session_id') or _approval_session_id.get(), context.get('turn_id') or _approval_turn_id.get()]
    canonical = {k: v for k, v in args.items() if k not in {'approved', 'request_plan'}}
    canonical['account'] = account(td, args)
    return hashlib.sha256(json.dumps([identity, canonical],
                                    ensure_ascii=False, sort_keys=True).encode()).hexdigest()


def prepare(td, args, runner=None, mail_runner=None):
    if p := problem(td, args):
        raise ValueError(p)
    mail = is_mail(td, args)
    validate(args, mail)
    request = {k: v for k, v in args.items() if k not in {'approved', 'request_plan'}}
    request['account'] = account(td, args)
    if args['action'] in {'send', 'reply', 'forward', 'draft_create'}:
        paths, error = td._mail_send_files(args.get('attachments'))
        if error:
            raise ValueError(error)
        request['attachments'] = [str(p) for p in paths]
        for field in ('to', 'cc'):
            if args.get(field):
                td.mail_app.recipients(args[field])
    if request['action'] in {'filter_create','mail_organize'}:
        if failed:=td._gmail_scope_preflight(request,runner):raise ValueError(json.dumps(failed,ensure_ascii=False))
    if mail:
        result = td.mail_app.full_tools(request, preview=True, runner=mail_runner)
    else:
        result, error = api(td,{'op':'full_preview',**request},runner)
        if error:
            raise ValueError(error)
    if not isinstance(result, dict) or result.get('ok') is not True:
        raise ValueError(json.dumps(result, ensure_ascii=False))
    return request, result


def api(td,request,runner=None,**kwargs):
    token=td.personal_scopes.MAIL_ACCOUNT.set(request['account'])
    try:return td._gmail_extra(request,runner,**kwargs)
    finally:td.personal_scopes.MAIL_ACCOUNT.reset(token)


def approval(td, args, context=None):
    try:
        request, preview = prepare(td, args)
    except ValueError as exc:
        return {'action': 'block', 'message': str(exc)}
    with LOCK:
        for k, row in list(SNAPSHOTS.items()):
            if time.monotonic() - row[0] > 3600:
                SNAPSHOTS.pop(k, None)
        # Concurrent identical calls must not replace the selection already on an approval card.
        row = SNAPSHOTS.setdefault(key(td, args, context), (time.monotonic(), request, preview))
        _, request, preview = row
    from hermes_constants import get_hermes_home
    from hermes_governance import write_policy
    decision=write_policy.gate('gmail_direct',request,owner=write_policy.owner_chat(get_hermes_home(),td.get_session_env),
        unattended=td.personal_scopes.background(td),state=preview)
    if decision is None or decision['action']=='block':return decision
    plan=td._gmail_mutation_plan(request) if request['action'] in BASIC else '승인하면 아래 메일 작업을 한 번 실행합니다.\n계정: '+request['account']+'\n계획: '+json.dumps(request,ensure_ascii=False)
    return {'action': 'approve', 'rule_key': 'full-mail:' + key(td, args, context),
            'message': plan +
            '\n대상·확인: ' + json.dumps({k:v for k,v in preview.items() if not k.startswith('_')}, ensure_ascii=False) +
            '\n부분·미확인 결과는 자동 재실행하지 않습니다.'}


@contextmanager
def execution(td, args):
    token = EXECUTION.set(key(td, args))
    try:
        yield
    finally:
        EXECUTION.reset(token)


def run(td, args, runner=None, mail_runner=None):
    if p := problem(td, args):
        return td._error(p, mutation_calls=0)
    try:
        validate(args, is_mail(td, args))
        if args['action'] in MAIL_READS:
            result = td.mail_app.full_tools({**args, 'account': account(td, args)}, preview=True, runner=mail_runner)
        else:
            if EXECUTION.get() != key(td, args):
                return td._error('MAIL_NATIVE_APPROVAL_REQUIRED', mutation_calls=0)
            with LOCK:
                row = SNAPSHOTS.pop(key(td, args), None)
            if row is None or time.monotonic() - row[0] > 3600:
                return td._error('MAIL_APPROVAL_SNAPSHOT_MISSING', mutation_calls=0)
            _, request, preview = row
            frozen = {**request, '_snapshot': preview}
            from hermes_governance import mail_undo
            result = mail_undo.execute(td,frozen,runner,mail_runner)
        result={key:value for key,value in result.items() if not key.startswith('_')}
        if args.get('action') in BASIC and type(result.get('ok')) is bool:
            receipt=json.loads(td._gmail_success_receipt(args['action'],{'response':result}))
            result={**receipt,**result,'approved':preview.get('inverse_ready') is not True}
        return json.dumps({'action': args['action'], 'account': account(td, args),
                           'authority': 'Mac Mail app' if is_mail(td, args) else 'Gmail API via Hermes local OAuth',
                           'fallback_used': False, **result}, ensure_ascii=False)
    except ValueError as exc:
        return td._error(str(exc), mutation_calls=None if EXECUTION.get() else 0, modified_count=None, verified=None)


def extend_schema(schema):
    schema['description'] += (_owner_text(' <<work_profile_title>> full_mail_tools: mailboxes/mailbox_create(mailbox path), '
        'mail_move/mail_mark/mail_trash(ids OR mail_conditions, source_mailbox=INBOX); rules_list, '
        'rule_create/rule_delete(Hermes: rule_name), mail_app_organize(rule + existing INBOX move). '
        'Gmail trash/untrash/modify(ids OR query, max500), label_delete/label_rename(user labels only), '
        'reply/forward(message_id, body, optional subject, to required for forward), draft_create(to,subject,body). '
        'Verified reversible state changes run in the owner conversation and offer confirm/undo; deletion and outgoing actions need native approval. No permanent deletion, background writes or automatic retries. '
        'Approval shows exact frozen IDs/sample, destinations and complete outgoing text. Mail account must accompany every call.'))
    props = schema['parameters']['properties']
    props['action']['enum'] += sorted(ACTIONS)
    props['account']['description'] = _owner_text('Company Gmail or registered company Mail app address; unique single-address company Mail account names (case-insensitive, e.g. <<company_name_title>>) also resolve to that registered address. Required for Mail app actions; keep lookup account with m-ID. Company cron permits lookup/read/thread only.')
    props['approved']['description'] = 'Compatibility field only; never grants approval. Call once and use native 승인·거절 buttons.'
    props['ids']['description'] = 'Examined IDs for ack (max1000); new mail writes require ids OR conditions/query (max500).'
    props.update({
        **{k: {'type': 'string'} for k in ('mailbox', 'source_mailbox', 'rule_name')},
        'match': {'type': 'string', 'enum': ['all', 'any'], 'default': 'all'},
        'mail_conditions': {'type': 'array', 'minItems': 1, 'maxItems': 10, 'items': {
            'type': 'object', 'required': ['field', 'contains'], 'additionalProperties': False,
            'properties': {'field': {'type': 'string', 'enum': ['from', 'to', 'subject']},
                           'contains': {'type': 'string', 'minLength': 1}}}},
        **{k: {'type': 'boolean'} for k in ('read', 'flagged', 'starred', 'archive', 'spam')},
        **{k: {'type': 'array', 'maxItems': 100, 'items': {'type': 'string'}} for k in ('add_label_ids', 'remove_label_ids')},
    })


def profile_schema(td, schema, profile):
    from copy import deepcopy
    result = deepcopy(schema)
    settings = td._PLUGIN_CONTEXT.get_config('gmail', {}) if td._PLUGIN_CONTEXT else {}
    if not app_grant(td) and (not team.has_role(profile, 'work') or settings.get('full_mail_tools') is not True):
        props = result['parameters']['properties']
        props['action']['enum'] = [a for a in props['action']['enum'] if a not in ACTIONS]
        for name in ('mailbox', 'source_mailbox', 'rule_name', 'match', 'mail_conditions', 'read', 'flagged',
                     'starred', 'archive', 'spam', 'add_label_ids', 'remove_label_ids'):
            props.pop(name, None)
        result['description'] = result['description'].split(_owner_text(' <<work_profile_title>> full_mail_tools:'))[0]
    return result
