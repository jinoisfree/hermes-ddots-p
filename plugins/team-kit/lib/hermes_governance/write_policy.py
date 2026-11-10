"""One app operation classifier shared by host gates and standalone packs.

Operations are declared by contracts or by the owning pack. Caller arguments
such as approved=True never confer authority. Unclassified actions are external.
"""
from hermes_governance.contracts import build_APP_OPERATIONS
from pathlib import Path

READ = 'read'
REVERSIBLE = 'reversible_write'
DELETE = 'delete'
EXTERNAL = 'external_action'


def classify(tool, args, *, safe_commands=(), state=None):
    if not isinstance(args, dict): return EXTERNAL
    action = str(args.get('action') or '').lower()
    if tool=='apple_notes_direct_mutation' and action=='update':
        from hermes_facility.app_scope import note_source
        source=(state or {}).get('source') or args.get('source') or note_source() or 'apple_notes'
        if source!='obsidian':return EXTERNAL  # Notes rewrites saved HTML on import.
    if tool == 'gmail_direct' and action == 'mail_organize' and args.get('delete_filter_ids'):
        return DELETE
    if tool=='gmail_direct' and state is not None and state.get('inverse_ready') is not True:
        spec=build_APP_OPERATIONS().get(tool,{})
        if action in spec.get(REVERSIBLE,()):return EXTERNAL
    if tool=='notion' and action=='api':
        return (state or {}).get('operation_kind',EXTERNAL)
    if tool=='calendar_direct_mutation' and action=='update' and (args.get('span')=='future' or (state or {}).get('recurring') or (state or {}).get('externalNotifications')):
        return EXTERNAL  # restoring a detached occurrence does not reconstruct its series
    if tool=='contacts_direct_mutation' and action=='update' and 'image_path' in args:
        return EXTERNAL  # Contacts.app cannot restore the original image bytes.
    if tool=='apple_notes_direct_mutation' and (state or {}).get('inverse_ready') is False and action in build_APP_OPERATIONS()[tool][REVERSIBLE]:
        return EXTERNAL
    if tool == 'doc_fill' and action == 'inspect': return READ
    if tool == 'personal_work_bundle' or (tool == 'notion' and action == 'batch'):
        operations = args.get('operations')
        if not isinstance(operations, list) or not operations: return EXTERNAL
        states=(state or {}).get('operations',[])
        kinds = [classify('notion' if tool == 'notion' else {
            'notes': 'apple_notes_direct_mutation', 'calendar': 'calendar_direct_mutation'}.get(op.get('domain'), ''),
            op if tool=='notion' else dict(op.get('arguments',{}),action=op.get('action')),
            state=states[index].get('before') if index<len(states) else None)
            if isinstance(op, dict) and (tool=='notion' or isinstance(op.get('arguments',{}),dict)) else EXTERNAL for index,op in enumerate(operations)]
        return next((kind for kind in (EXTERNAL, DELETE, REVERSIBLE) if kind in kinds), READ)
    if tool == 'mac_app' and action == 'command':
        return READ if args.get('name') in safe_commands else EXTERNAL
    spec = build_APP_OPERATIONS().get(tool, {})
    for kind in (READ, REVERSIBLE, DELETE):
        if action in spec.get(kind, ()) or '*' in spec.get(kind, ()): return kind
    return EXTERNAL


def governed(tool): return tool in build_APP_OPERATIONS()


def background(env):
    return any(env(key, '') for key in ('HERMES_CRON_SESSION', 'HERMES_SINGLE_QUERY_SESSION', 'HERMES_KANBAN_TASK'))


def owner_chat(home, env):
    """Prove the same owner/channel identity for every write, not just a nonempty user id."""
    from hermes_facility import app_registry
    from hermes_facility.config_assembly import yaml_load
    if background(env): return False
    platform, user = env('HERMES_SESSION_PLATFORM', '').lower(), env('HERMES_SESSION_USER_ID', '')
    if platform not in ('slack', 'photon') or not user or not env('HERMES_SESSION_CHAT_ID', ''): return False
    config_path = Path(home) / 'config.yaml'
    if not config_path.is_file(): return False
    config = yaml_load(config_path.read_bytes())
    allowed = config.get('platforms', {}).get(platform, {}).get('api_human_users', [])
    return isinstance(allowed, list) and user in allowed


def gate(tool, args, *, owner, unattended=False, safe_commands=(), state=None):
    kind = classify(tool, args, safe_commands=safe_commands,state=state)
    if kind == READ: return None
    if unattended or not owner:
        return dict(action='block', message='APP_OWNER_CHAT_REQUIRED: 쓰기는 소유자 대화에서만 할 수 있어요.')
    if kind == REVERSIBLE: return None
    import hashlib, json
    payload={k:v for k,v in args.items() if k not in ('approved','request_plan')}
    key = hashlib.sha256(json.dumps([tool,payload], sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:20]
    return dict(action='approve', rule_key='app-write:' + key,
                message=('승인하면 삭제합니다.' if kind == DELETE else '승인하면 바깥 동작을 실행합니다.') + '\n[[버튼: 승인 | 거절]]')


def result_text(summary, key=None):
    reference = ('\n변경 번호: ' + key) if key else ''
    return '앱 쓰기 결과\n' + summary + reference + '\n[[버튼: 확인 | 되돌리기]]'


def rule_note():
    return '읽기는 바로 한다. 되돌릴 수 있는 쓰기는 소유자 대화에서 승인 없이 바로 실행하고 확인·되돌리기를 보여 준다. 삭제·바깥 동작은 먼저 승인받으며 배경 쓰기·고른 범위 밖 접근은 거부한다. '
