"""Bounded company source snapshots in one tool call; never synchronizes or writes originals."""
from datetime import datetime, timezone
import json
import time

KINDS = ('notion', 'notes', 'calendar')
FIELDS = ('body', 'tasks', 'schedule')
SAFE_REASONS = {'calendar_permission_denied', 'calendar_not_found', 'calendar_read_failed',
                'calendar_read_timeout', 'calendar_read_invalid', 'calendar_executor_compile_failed',
                'recurring_calendar', 'google_calendar_source', 'company_notion_database_required',
                'obsidian_deleted', 'obsidian_unavailable_or_syncing', 'notes_permission_denied',
                'source_scope_unverified', 'note_read_unclassified', 'unsupported_work_source'}
MAX_SOURCES = 12
BODY_CHARS = 2000
TASK_LIMIT = 30
RESULT_CHARS = 30000
SCHEMA = {'name': 'linked_work_read', 'description':
    '업무비서 실행 B의 연결 업무 상태 조회. 확정된 common_id의 Notion·메모·일정을 한 호출로 읽는다. '
    '연결 ID만 필요한 경우 common_work_get. kinds로 필요한 종류만 선택. '
    '원본별 상태·근거 ID·조회 시각·revision과 fields로 요청한 정보를 반환한다. '
    '마감·할 일 비교는 fields=[tasks,schedule], 본문이 필요할 때만 body를 포함한다. '
    'partial/truncated/closed는 완료·없음이 아니다. 상세 본문·첨부·쓰기 전후 검증은 원래 도구로 새로 읽는다. '
    '예약·개인 범위·쓰기 금지. team_work(start)의 tools에 포함해 B에서 사용.',
    'parameters': {'type': 'object', 'properties': {
        'common_id': {'type': 'string', 'minLength': 1},
        'kinds': {'type': 'array', 'items': {'type': 'string', 'enum': list(KINDS)},
                  'minItems': 1, 'maxItems': 3, 'uniqueItems': True},
        'fields': {'type': 'array', 'items': {'type': 'string', 'enum': list(FIELDS)},
                   'minItems': 1, 'maxItems': 3, 'uniqueItems': True,
                   'description': '생략하면 body/tasks/schedule 전부. 본문 생략은 요청 정보의 누락이 아니다.'}},
        'required': ['common_id'], 'additionalProperties': False}}


def references(item, kinds):
    refs = []
    for row in item.get('knowledge_refs', []):
        if row['ref_type'] == 'notion_page' and 'notion' in kinds:
            refs.append(('notion', row['external_id'], row.get('metadata', {})))
    for row in item.get('sources', []):
        if row['domain'] in kinds:
            refs.append((row['domain'], row['source_id'], row.get('metadata', {})))
    # Do not hide an unhealthy duplicate link behind a healthy one.
    grouped = {}
    for kind, identifier, meta in refs:
        key = (kind, identifier)
        state = meta.get('link_state', {}).get('status', 'ok')
        if key not in grouped or state != 'ok':
            grouped[key] = state
    return [(kind, identifier, state) for (kind, identifier), state in grouped.items()]


def snapshot(item, sources, kinds, fields=None):
    fields = list(FIELDS) if fields is None else fields
    refs = references(item, kinds)
    if len(refs) > MAX_SOURCES:
        return {'ok': False, 'error': 'LINKED_READ_SOURCE_LIMIT', 'source_count': len(refs), 'limit': MAX_SOURCES}
    rows = []
    for kind, identifier, state in refs:
        row = {'kind': kind, 'source_id': identifier}
        if state != 'ok':
            rows.append({**row, 'status': 'unavailable', 'reason': 'linked_source_unhealthy'})
            continue
        if kind == 'notion' and item.get('scope') == 'private':
            rows.append({**row, 'status': 'out_of_scope', 'reason': 'private_work_notion_refused'})
            continue
        started = time.monotonic()
        try:
            # Existing adapters enforce company scope and classify missing vs transient failure.
            # Serial deliberately: native adapters import mutable module names and are not thread-safe.
            data = sources.read(kind, identifier)
            content = data['content']
            title, body, tasks = str(content['title']), str(content.get('body') or ''), content.get('tasks', [])
            shown = []
            truncated_fields = ['title'] if len(title) > 500 else []
            if 'body' in fields and len(body) > BODY_CHARS:
                truncated_fields.append('body')
            if 'tasks' in fields and len(tasks) > TASK_LIMIT:
                truncated_fields.append('tasks')
            for task in (tasks[:TASK_LIMIT] if 'tasks' in fields else []):
                selected = {k: task[k] for k in ('text', 'due', 'done', 'ambiguous', 'source_id') if k in task}
                for key, value in list(selected.items()):
                    if isinstance(value, str) and len(value) > 500:
                        selected[key] = value[:500]
                        if 'tasks' not in truncated_fields:
                            truncated_fields.append('tasks')
                shown.append(selected)
            row.update(status='closed' if data.get('closed') else 'ok', revision=data['revision'],
                       title=title[:500], truncated=bool(truncated_fields), truncated_fields=truncated_fields,
                       omitted_fields=[f for f in FIELDS if f not in fields and (f != 'schedule' or kind == 'calendar')],
                       read_at=datetime.now(timezone.utc).isoformat())
            if 'body' in fields:
                row['body'] = body[:BODY_CHARS]
            if 'tasks' in fields:
                row.update(tasks=shown, task_count=len(tasks))
            if kind == 'calendar' and 'schedule' in fields:
                raw = data.get('raw', {})
                row['schedule'] = {k: raw[k] for k in ('start', 'end', 'isAllDay', 'allDay') if k in raw}
        except Exception as exc:
            # Exception text can contain business content or credentials. Only fixed classifications leave.
            from source_lookup import SourceReadError
            row.update(status=exc.status if isinstance(exc, SourceReadError) else 'unavailable',
                       reason=exc.reason if isinstance(exc, SourceReadError) and exc.reason in SAFE_REASONS else 'source_read_failed')
        row['elapsed_ms'] = round((time.monotonic() - started) * 1000)
        rows.append(row)
    used = 0
    for row in rows:
        size = len(json.dumps(row, ensure_ascii=False))
        if used + size > RESULT_CHARS:
            removed = [f for f in ('body', 'tasks') if f in row]
            for field in removed:
                row.pop(field)
            row['truncated_fields'] = sorted(set(row.get('truncated_fields', [])) | set(removed))
            row['truncated'] = True
            row['omitted_reason'] = 'response_budget'
        used += len(json.dumps(row, ensure_ascii=False))
    complete = all(r['status'] == 'ok' and not r.get('truncated') for r in rows)
    return {'ok': complete, 'status': 'complete' if complete else 'partial',
            'requested_fields': fields,
            'common_id': item['common_id'], 'work_status': item.get('status'),
            'sources': rows, 'source_count': len(rows),
            'unlinked_kinds': [k for k in kinds if not any(r['kind'] == k for r in rows)],
            'coverage': 'linked notion/notes/calendar only; not full bodies, attachments or reminders',
            'next_step': '성공한 조회는 요청한 정보의 비교에 재사용한다. omitted_fields는 요청하지 않아 생략한 정보로 재조회 사유가 아니다. '
                         'truncated_fields·실패 중 요청에 필요한 근거만 추가 조회한다. '
                         '본문 교체·첨부 보존·쓰기 전후 검증에는 원래 도구로 새로 읽는다.',
            'mutation_calls': 0}


def handle(td, args):
    if not td._task_capture_owner_chat():
        return td._error('LINKED_READ_OWNER_CHAT_REQUIRED')
    if error := td._require_common_work_access():
        return error
    kinds = args.get('kinds', list(KINDS))
    fields = args.get('fields', list(FIELDS))
    if (set(args) - {'common_id', 'kinds', 'fields'} or not isinstance(args.get('common_id'), str)
            or not args['common_id'].strip() or not isinstance(kinds, list) or not kinds
            or len(kinds) > 3 or any(not isinstance(k, str) or k not in KINDS for k in kinds)
            or len(set(kinds)) != len(kinds) or not isinstance(fields, list) or not fields
            or len(fields) > 3 or any(not isinstance(f, str) or f not in FIELDS for f in fields)
            or len(set(fields)) != len(fields)):
        return td._error('LINKED_READ_INVALID_ARGUMENTS')
    try:
        item = td._common_work_store().get(args['common_id'])
        # Validate bounds before loading adapters or issuing any remote read.
        if len(references(item, kinds)) > MAX_SOURCES:
            return td._error('LINKED_READ_SOURCE_LIMIT')
        from hermes_constants import get_hermes_home
        from work_sources import Sources
        from pathlib import Path
        result = snapshot(item, Sources(Path(get_hermes_home())), kinds, fields)
        return json.dumps(result, ensure_ascii=False)
    except Exception:
        return td._error('LINKED_READ_UNAVAILABLE')
