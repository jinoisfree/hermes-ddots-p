"""Compare actual current read receipts and inspect Gmail reply candidates."""

# Owner-specific text is rendered from private policy; public source stays generic.
from pathlib import Path as _OwnerPath
import sys as _owner_sys
_owner_library = str((_OwnerPath(__file__).resolve().parent / '..').resolve())
if _owner_library not in _owner_sys.path:
    _owner_sys.path.insert(0, _owner_library)
from hermes_facility.owner_text import render as _owner_text

from datetime import datetime
import json
from pathlib import Path
import subprocess
from zoneinfo import ZoneInfo
import importlib.util as _ilu, pathlib as _pl, sys as _sys
team = _sys.modules.get('hermes_team_registry')
if team is None:
    _spec = _ilu.spec_from_file_location('hermes_team_registry', _pl.Path(__file__).with_name('team_registry.py'))
    team = _sys.modules['hermes_team_registry'] = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(team)
vault = _sys.modules.get('hermes_owner_vault')
if vault is None:
    _spec = _ilu.spec_from_file_location('hermes_owner_vault', _pl.Path(__file__).with_name('owner_vault.py'))
    vault = _sys.modules['hermes_owner_vault'] = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(vault)

# 개인·회사 Gmail 주소는 사장 금고에서 온다(없으면 enum 없이 문자열만 받고 계정 검사는 아래 설정 대조가 한다).
_ACCOUNTS = [a for a in (vault.text('accounts.personal.gmail'), vault.text('accounts.company.gmail')) if a]
_ACCOUNT_PROP = {'type': 'string', 'enum': _ACCOUNTS} if _ACCOUNTS else {'type': 'string'}
REF = {'type': 'object', 'properties': {'receipt_id': {'type': 'string'}, 'pointer': {'type': 'string', 'description': 'Exact JSON Pointer returned by list.'},
       'quote': {'type': 'string', 'description': 'Optional exact substring of the source string, e.g. its stated deadline.'}},
       'required': ['receipt_id', 'pointer'], 'additionalProperties': False}
SCHEMAS = {
    'work_crosscheck': {'name': 'work_crosscheck', 'description': 'Compare actual source values from this turn’s Gmail, Calendar, Notes and read-only Notion receipts. List pointers first. Differences are candidates, not proof of the same task or missing completion. Never changes originals.',
        'parameters': {'type': 'object', 'properties': {
            'action': {'type': 'string', 'enum': ['list', 'compare']}, 'query': {'type': 'string'},
            'references': {'type': 'array', 'items': REF, 'minItems': 2, 'maxItems': 10}}, 'required': ['action'], 'additionalProperties': False}},
    'mail_waiting': {'name': 'mail_waiting', 'description': 'Read Gmail sent threads in an explicit KST date range, checking current thread metadata for later incoming messages. Returns reply candidates, not an assertion that a reply is owed. No sending, marking or background runs.',
        'parameters': {'type': 'object', 'properties': {'start': {'type': 'string', 'description': 'YYYY-MM-DD inclusive, KST'},
            'end': {'type': 'string', 'description': 'YYYY-MM-DD exclusive, KST'},
            'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50},
            'account': dict(_ACCOUNT_PROP)}, 'required': ['start', 'end'], 'additionalProperties': False}},
}


def leaves(value, pointer='', depth=0):
    if depth > 20: return
    if isinstance(value, dict):
        for k, v in value.items():
            yield from leaves(v, pointer + '/' + str(k).replace('~', '~0').replace('/', '~1'), depth + 1)
    elif isinstance(value, list):
        for i, v in enumerate(value): yield from leaves(v, pointer + '/' + str(i), depth + 1)
    else:
        yield pointer, value


def selected(data, pointer):
    if not isinstance(pointer, str) or not pointer.startswith('/') or len(pointer) > 1000:
        raise ValueError('invalid_json_pointer')
    for part in pointer[1:].split('/'):
        part = part.replace('~1', '/').replace('~0', '~')
        if isinstance(data, list) and part.isdigit() and int(part) < len(data): data = data[int(part)]
        elif isinstance(data, dict) and part in data: data = data[part]
        else: raise ValueError('source_pointer_not_found')
    if isinstance(data, (dict, list)):
        raise ValueError('select_a_scalar_source_value')
    return data


def crosscheck(args, evidence):
    evidence = {k: v for k, v in evidence.items() if v['tool'] != 'instagram_dm_guide'}
    if args['action'] == 'list':
        if 'references' in args: raise ValueError('references_require_compare')
        query = args.get('query', '')
        if not isinstance(query, str) or len(query) > 200: raise ValueError('invalid_query')
        items = []
        for identifier, receipt in evidence.items():
            for pointer, value in leaves(receipt['data']):
                if query.casefold() not in (pointer + ' ' + str(value)).casefold(): continue
                items.append({'receipt_id': identifier, 'tool': receipt['tool'], 'pointer': pointer,
                    'value': value[:1000] if isinstance(value, str) else value,
                    'value_truncated': isinstance(value, str) and len(value) > 1000,
                    'checked_at_kst': datetime.fromtimestamp(receipt['checked_at'], ZoneInfo('Asia/Seoul')).isoformat()})
        return {'ok': True, 'values': items[:150], 'count': len(items), 'truncated': len(items) > 150,
                'scope': 'Successful read receipts in this session and turn only; not all related tasks.'}
    if args['action'] != 'compare' or 'query' in args:
        raise ValueError('invalid_crosscheck_action')
    refs = args.get('references')
    if not isinstance(refs, list) or not 2 <= len(refs) <= 10: raise ValueError('two_to_ten_references_required')
    rows, identities = [], set()
    for ref in refs:
        if not isinstance(ref, dict) or set(ref) - {'receipt_id', 'pointer', 'quote'}:
            raise ValueError('invalid_source_reference')
        receipt = evidence.get(ref.get('receipt_id'))
        if receipt is None: raise ValueError('source_not_in_current_read_evidence')
        value = selected(receipt['data'], ref.get('pointer'))
        quote = ref.get('quote')
        if quote is not None:
            if not isinstance(quote, str) or not quote or not isinstance(value, str) or quote not in value:
                raise ValueError('quote_must_be_exact_source_substring')
            value = quote
        if isinstance(value, str) and len(value) > 2000:
            raise ValueError('select_an_exact_short_quote_for_long_text')
        identity = (ref['receipt_id'], ref['pointer'])
        if identity in identities: raise ValueError('duplicate_source_reference')
        identities.add(identity)
        rows.append({**ref, 'tool': receipt['tool'], 'value': value, 'checked_at': receipt['checked_at']})
    known = all(r['value'] is not None and r['value'] != '' for r in rows)
    same = len({json.dumps([type(r['value']).__name__, r['value']], ensure_ascii=False) for r in rows}) == 1 if known else None
    return {'ok': True, 'sources': rows, 'values_equal': same, 'status': 'unknown' if same is None else 'equal' if same else 'difference_candidate',
            'note': 'Exact value comparison only. Verify task identity, timezone, applicability and field meaning; absent values are unknown. No source was changed.'}


def mail(home, args):
    import hermes_yaml as yaml
    from pm.environments import project_python
    cfg = yaml.safe_load((home / 'config.yaml').read_text())
    account = cfg.get('plugins', {}).get('entries', {}).get('team-delegation', {}).get('settings', {}).get('gmail', {}).get('account')
    account=args.get('account') or account
    if not account: raise ValueError('gmail_account_not_configured')
    args={k:v for k,v in args.items() if k!='account'}
    root = home.parent.parent
    token_home=root
    scope_path=cfg.get('plugins',{}).get('entries',{}).get('team-delegation',{}).get('settings',{}).get('personal_roles',{}).get('scope_config')
    if scope_path:
        shared=yaml.safe_load(Path(scope_path).read_text())['plugins']['entries']['team-kit']['settings']['personal_scopes']
        # Each secretary reads only its own scope's mailbox (2026-10-18 사용자 결정), like gmail_direct.
        own='personal' if team.home_has_role(home,'personal') else 'company' if team.home_has_role(home,'work') else None
        if own and str(account).casefold()!=str(shared[own]['gmail']).casefold():
            raise ValueError("PERSONAL_SCOPE_WRONG_OWNER: "+(_owner_text("개인 메일은 <<personal_name>> 담당(멘션으로 요청)") if own=='company' else _owner_text('회사 메일은 <<work_name>> 담당이다.'))
                             +_owner_text(" <<owner_label_lower>>-world 스레드면 거부로 끝내지 말고 team_project plan(profile=담당 비서) 후 dispatch(task_id, tool='mail_waiting')로 바로 넘긴다."))
        if account==shared['personal']['gmail']:
            if not shared['personal'].get('connected'):raise ValueError('PERSONAL_ACCOUNT_NOT_CONNECTED: 개인 계정 연결 전')
            token_home=team.home_of_role('personal', root)
        elif account!=shared['company']['gmail']:raise ValueError('gmail_account_not_configured')
    proc = subprocess.run([str(project_python(root / 'hermes-agent')), str(Path(__file__).with_name('mail_waiting_worker.py'))],
        input=json.dumps({'root': str(root), 'account': account, 'args': args, 'token_home':str(token_home)}), capture_output=True, text=True, timeout=120)
    if proc.returncode: raise ValueError('mail_waiting_failed_account_or_connection')
    return json.loads(proc.stdout)


def handle(name, args, *, home, evidence=None, **_):
    return crosscheck(args, evidence) if name == 'work_crosscheck' else mail(home, args)
