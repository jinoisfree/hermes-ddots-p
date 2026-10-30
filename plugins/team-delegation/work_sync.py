"""Owner-authorized full linked-work sync, using immutable baselines and a no-replay journal."""
from __future__ import annotations
import time
import work_content as content
import work_tool_writes

CONTENT_VERSION = 'work-content-v1'
SYNCED = ('title', 'tasks')  # 2026-10-27 사용자 결정: bodies differ by format per original and are not synced
DUE_UNCERTAIN = '• ⚠️ 노션 다음 마감 반영 확인이 필요해 멈췄어요. 자동 재실행하지 않아요.'
DUE_UNRESOLVED = '• ⚠️ 노션 할 일의 마감 근거를 확인해야 해요. 기간·서로 다른 날짜이거나 지난 다음 마감에 대응하는 미완료 날짜가 없어 자동 변경하지 않았어요.'


def due_basis(prop):
    """What the wanted date depends on: each to-do's own date and completion, not titles or bodies."""
    return content.digest([[row.get('due'), bool(row.get('done')), bool(row.get('ambiguous'))]
                           for row in prop.get('explicit') or []])


def due_label(value):
    if not value:
        return '없음'
    return f'{int(value[5:7])}/{int(value[8:10])}' + (f' {value[11:16]}' if len(value) > 10 else '')


def synced(row):
    """What moves between originals: title and tasks (text, due, done). Each original keeps its own body."""
    value = content.semantic(row)
    return {field: value[field] for field in SYNCED}

def content_refs(refs):
    """Day-by-day calendar events may share one work and keep their own titles; the single memo and
    Notion page of that work still sync title and tasks with each other (2026-10-28 사용자 결정)."""
    if len(refs) == len({kind for kind, _ in refs}):
        return refs
    others = [ref for ref in refs if ref[0] != 'calendar']
    return others if len(others) >= 2 and len(others) == len({kind for kind, _ in others}) else refs


def configured(home, sources, store, settings, **kwargs):
    return Engine(home, sources, store, **kwargs) if settings.get('content_sync', True) is True else None


class Engine:
    def __init__(self, home, sources, store, *, reminders=None, dry_run=False):
        self.home, self.sources, self.store = home, sources, store
        self.reminders, self.dry = reminders, dry_run
        self.reads = {}  # last originals read per work, reused by completion detection
        self.due_messages = {}  # retain verified date outcomes if another original fails later

    def event(self, cid, payload):
        if not self.dry:
            with self.store._connect() as conn:
                self.store._event(conn, cid, 'work_sync', payload)

    def due(self, cid, identifier, row, state, path):
        """Keep a Notion page's '다음 마감' on its earliest open dated to-do, independent of the content sync
        (2026-10-28): stale dates were left behind when tasks were done or re-dated but the to-do list read
        the same. Re-read before writing, verify after, and never replay an uncertain write."""
        prop = row.get('due_property')
        entries = state.setdefault('notion_due', {})
        pending = (entries.get(identifier) or {}).get('pending')
        if pending:
            # Only the target date read back, or an owner change to what the date depends on (the page's
            # own date set to a third value, or the dated to-dos), ends an uncertain write. Title, body or
            # other edits change the revision too and must not re-run the same PATCH. Older entries
            # without a basis wait for the target or an owner date change.
            if prop and prop['page'] == pending['to']:
                status = 'reconciled'
            elif prop and prop['page'] != pending['from']:
                status = 'superseded'
            elif prop and pending.get('basis') and due_basis(prop) != pending['basis']:
                status = 'superseded'
            else:
                status = None
            if status is None:
                return [DUE_UNCERTAIN], row
            if not self.dry:
                entries[identifier].pop('pending')
                content.save(path, state)
                self.event(cid, {'status': 'due_'+status, 'page': identifier, **pending})
            return [], row
        if prop and prop.get('problem'):
            return [DUE_UNRESOLVED], row
        if not prop or prop['wanted'] == prop['page']:
            return [], row
        change = f"노션 다음 마감을 {due_label(prop['page'])} → {due_label(prop['wanted'])}로"
        if self.dry:
            return [f'• [시험 실행] {change} 맞출 예정이에요.'], row
        fresh = self.sources.read('notion', identifier)
        if fresh.get('closed') or fresh['revision'] != row['revision']:
            return [], row  # edited meanwhile: the next pass compares the new state
        entries[identifier] = {'pending': {'from': prop['page'], 'to': prop['wanted'], 'revision': row['revision'],
                                           'basis': due_basis(prop), 'at': time.time()}}
        content.save(path, state)
        self.event(cid, {'status': 'due_pending', 'page': identifier, **entries[identifier]['pending']})
        try:
            after = self.sources.write_due(identifier, prop['wanted'])
            if not after.get('due_property') or due_basis(after['due_property']) != due_basis(prop):
                raise RuntimeError('notion_due_tasks_changed_during_write')
        except Exception as exc:
            from notion_completion_sync import log_work_error
            log_work_error(self.home, cid, 'work_due_write_uncertain', exc)
            return [DUE_UNCERTAIN], row
        done = entries[identifier].pop('pending')
        content.save(path, state)
        self.event(cid, {'status': 'due_done', 'page': identifier, **done})
        return [f'• {change} 맞췄어요(미완료 할 일의 가장 이른 마감).'], after

    def single_due(self, cid, identifier):
        """A Notion page that is the work's only original: first sight stores the baseline only."""
        with content.ledger(self.home, 'work-sync') as (path, state):
            row = self.sources.read('notion', identifier)
            if row.get('closed'):
                return []
            if identifier not in state.setdefault('notion_due', {}):
                if not self.dry:
                    state['notion_due'][identifier] = {}
                    content.save(path, state)
                return []
            return self.due(cid, identifier, row, state, path)[0]

    def early_due(self, cid, authority, refs, work, state, path):
        """Only known authoritative Notion, unchanged links, and known non-Notion pending targets."""
        early, messages = {}, []
        if authority and authority[0] == 'notion' and work:
            winner = '|'.join(authority)
            pending = work.get('pending')
            targets = pending.get('targets') if pending else []
            safe_pending = not pending or (isinstance(targets, list) and bool(targets) and all(
                isinstance(t, (list, tuple)) and len(t) == 2 and t[0] in {'notes', 'calendar'}
                for t in targets))
            same_sources = set(work['sources']) == {kind+'|'+sid for kind, sid in refs}
            if safe_pending and same_sources and work.get('content_version') == CONTENT_VERSION:
                row = self.sources.read(*authority)
                if not row.get('closed'):
                    lines, row = self.due(cid, authority[1], row, state, path)
                    messages += lines
                early[winner] = row
        return early, messages

    def due_only(self, item):
        """The lifecycle caller has verified the Notion link; another source is unavailable/conflicted.
        Compare configured IDs, including the unavailable source, without reading or writing it."""
        if item.get('scope') != 'shared' or item.get('status') != 'active':
            return []
        refs = [('notion', r['external_id']) for r in item.get('knowledge_refs', [])
                if r.get('ref_type') == 'notion_page']
        refs += [(r['domain'], r['source_id']) for r in item.get('sources', [])
                 if r['domain'] in {'notes', 'calendar'}]
        authority = getattr(self.sources, 'authority', lambda *_: None)(item, refs)
        if not authority or authority[0] != 'notion':
            return []
        with content.ledger(self.home, 'work-sync') as (path, state):
            return self.early_due(item['common_id'], authority, content_refs(refs),
                                  state['works'].get(item['common_id']), state, path)[1]

    def run(self, item):
        cid = item['common_id']
        self.due_messages[cid] = []
        try:
            return self._run(item)
        except Exception as exc:
            exc.work_due_messages = self.due_messages[cid]
            raise

    def _run(self, item):
        import work_policy
        item = work_policy.permitted(item)
        cid, messages = item['common_id'], []
        refs = self.sources.references(item)
        if item.get('scope') == 'private':refs = [ref for ref in refs if ref[0]!='notion']
        work_deadline = len(refs) == 1 and refs[0][0] == 'calendar'
        import obsidian_store
        private_tasks=item.get('scope')=='private' and any(kind=='notes' and obsidian_store.is_id(sid) for kind,sid in refs)
        if (item.get('status') != 'active' and not work_deadline and not private_tasks) or not refs:
            return {'handled': False, 'messages': []}
        authority = getattr(self.sources, 'authority', lambda *_: None)(item, refs)
        refs = content_refs(refs)
        duplicate_domains = len(refs) != len({kind for kind, _ in refs})
        if len(refs) == 1 or duplicate_domains:
            if not duplicate_domains and refs[0][0] == 'notion' and item.get('status') == 'active':
                messages += self.single_due(cid, refs[0][1])
                self.due_messages[cid] = list(messages)
            if self.reminders and item.get('reminder_policy') != 'none':
                result = self.reminders(item, self.dry)
                messages += [f'• 할 일 미리알림 {key}: {len(result[key])}개' for key in
                             ('created', 'moved', 'completed', 'deleted', 'past_due', 'skipped') if result.get(key)]
            return {'handled': True, 'messages': messages,
                    **({'connection_status': 'unsupported', 'connection_reason': 'single_original_per_domain_required'}
                       if duplicate_domains else {})}
        started = time.time()
        with content.ledger(self.home, 'work-sync') as (path, state):
            work = state['works'].get(cid)
            early, lines = self.early_due(cid, authority, refs, work, state, path)
            messages += lines
            self.due_messages[cid] = list(messages)
            current = {kind+'|'+identifier: (early[kind+'|'+identifier] if kind+'|'+identifier in early
                       else self.sources.read(kind, identifier)) for kind, identifier in refs}
            self.reads[cid] = current
            if any(row.get('closed') for row in current.values()):
                return {'handled': True, 'messages': messages + ['• ⚠️ 업무 원본이 삭제·보관됨 — 업무 자체 삭제는 전파하지 않았어요.']}
            if work is None or ((set(work['sources']) != set(current) or work.get('content_version') != CONTENT_VERSION)
                                and not work.get('pending')):
                if not self.dry:
                    state['works'][cid] = {'sources': current, 'content_version': CONTENT_VERSION}
                    content.save(path, state)
                    work_tool_writes.clear(self.home, current, started)
                    if work and work.get('conflict'):
                        return {'handled': True, 'messages': [], 'resolved': {'choice': None, 'status': 'cleared'}}
                return {'handled': True, 'messages': []}
            if work.get('pending'):
                wanted = work['pending']['after']
                if (set(wanted) == {kind for kind, _ in refs} and
                        all(synced(row['content']) == synced(wanted[key.split('|', 1)[0]]) for key, row in current.items())):
                    if not self.dry:
                        self.event(cid, {'status': 'reconciled', **work['pending']})
                        work.pop('pending'); work['sources'] = current; content.save(path, state)
                elif set(current) != set(work['pending']['before']):
                    # An original was replaced or relinked after the uncertain write (e.g. an owner-approved
                    # note rebuild), so the old desired state can never be read back. Adopt the current
                    # originals as the new baseline without replaying anything.
                    if not self.dry:
                        self.event(cid, {'status': 'superseded', **work['pending']})
                        state['works'][cid] = {'sources': current, 'content_version': CONTENT_VERSION}
                        content.save(path, state)
                        work_tool_writes.clear(self.home, current, started)
                    return {'handled': True, 'messages': messages + ['• 앞선 불명확한 반영 뒤 연결 원본이 바뀌어 현재 원본을 새 기준으로 삼았어요. 자동 재실행은 하지 않았어요.']}
                else:
                    return {'handled': True, 'messages': messages + ['• ⚠️ 앞선 본문·할 일 반영이 불명확해 자동 재실행하지 않았어요. 원본 확인이 필요해요.']}
            if authority and authority[0] == 'notion' and '|'.join(authority) not in early:
                # Notion is never a write target here, so its own date property is checked first and alone.
                winner = '|'.join(authority)
                lines, current[winner] = self.due(cid, authority[1], current[winner], state, path)
                messages += lines
            changed = [key for key in current if synced(current[key]['content']) != synced(work['sources'][key]['content'])]
            resolved = None
            if authority:
                winner = '|'.join(authority)
                wanted = synced(current[winner]['content'])
                changed = [winner] if any(synced(row['content']) != wanted for row in current.values()) else []
                edits = [wanted] if changed else []
            elif work.get('conflict') and work.get('resolution'):
                # The owner chose which original wins after a conflict question (2026-10-27).
                choice = work.pop('resolution').get('choice')
                winner = next((key for key in current if key.split('|', 1)[0] == choice), None)
                resolved = {'choice': choice, 'status': 'kept' if winner is None else 'applied'}
                changed = [] if winner is None else [winner]
                edits = [] if winner is None else [synced(current[winner]['content'])]
                if not self.dry:
                    self.event(cid, {'status': 'owner_resolution', **resolved})
            elif changed:
                edits = [{field: value for field, value in synced(current[key]['content']).items()
                          if value != synced(work['sources'][key]['content'])[field]} for key in changed]
                alternatives = {content.digest(edit) for edit in edits}
                if len(alternatives) != 1 and work_tool_writes.marked(self.home, changed) != set(changed):
                    # Keep the old baseline, remember the conflict so the owner can pick a side, and keep
                    # the reminder sync (Notion owns tasks, 2026-10-26) running meanwhile.
                    if not self.dry and not work.get('conflict'):
                        work['conflict'] = {'kinds': sorted(key.split('|', 1)[0] for key in changed), 'at': time.time()}
                        content.save(path, state)
                    messages = ['• ⚠️ 같은 점검 구간에 두 원본이 서로 다르게 바뀌었어요. 제목·할 일을 쓰지 않고 충돌로 보류했어요.']
                    if self.reminders:
                        result = self.reminders(item, self.dry)
                        messages += [f'• 할 일 미리알림 {key}: {len(result[key])}개' for key in
                                     ('created', 'moved', 'completed', 'deleted', 'past_due', 'skipped') if result.get(key)]
                    return {'handled': True, 'messages': messages, 'conflict': work.get('conflict')}
                if len(alternatives) != 1:
                    # Every differing original was written by work-assistant's own approved tool calls (separate
                    # memo and Notion edits of one request), not by the owner: adopt them as the new baseline
                    # without copying either side (diag-1ea80e2f0831).
                    if not self.dry:
                        self.event(cid, {'status': 'tool_writes_rebaselined', 'sources': changed})
                    changed = []
            if changed:
                desired = {kind: {**content.semantic(current[kind+'|'+identifier]['content']), **edits[0]}
                           for kind, identifier in refs}
                # A structured memo reads lossily (dates leave to-do text) and cannot take flat rows back
                # (2026-10-26 CIIE). When it changed, only completion and the title move to the others. When
                # another original changed, the memo takes the task list through its task rows only
                # (2026-10-28 사용자 결정); if those rows cannot be aligned it falls back to completion only.
                structured = getattr(self.sources, 'structured', lambda row: False)
                plan = getattr(self.sources, 'structured_target', lambda row, wanted: None)
                lossy = not authority and any(key.startswith('notes|') and structured(current[key]) for key in changed)
                for kind, identifier in refs:
                    row = current[kind+'|'+identifier]
                    if lossy or (kind == 'notes' and structured(row)):
                        planned = None if lossy else plan(row, desired[kind])
                        if authority and planned is None:
                            raise ValueError('authoritative_tasks_cannot_be_preserved_in_note')
                        desired[kind] = content.semantic(planned or content.structured_desired(content.semantic(row['content']), desired[kind]))
                targets = [(kind, identifier) for kind, identifier in refs
                           if content.semantic(current[kind+'|'+identifier]['content']) != desired[kind]]
                if not targets:
                    # Representations differ (a structured memo already carries the authority's tasks in its
                    # own wording): nothing to write, so no journal entry and no 'synced' report every pass.
                    changed = []
            if changed:
                for kind, identifier in targets:
                    self.sources.preflight(kind, identifier, current[kind+'|'+identifier], desired[kind])
                if self.dry:
                    return {'handled': True, 'messages': ['• [시험 실행] 연결된 제목·할 일을 한 원본의 변경으로 맞출 예정이에요.']}
                work['pending'] = {'before': current, 'after': desired, 'targets': targets}
                content.save(path, state)
                self.event(cid, {'status': 'pending', **work['pending']})
                try:
                    for kind, identifier in targets:
                        current[kind+'|'+identifier] = self.sources.apply(kind, identifier, current[kind+'|'+identifier], desired[kind])
                    # Re-read every original, including the winning source: concurrent edits cannot be hidden.
                    refs = content_refs(self.sources.references(self.store.get(cid)))
                    if len(refs) != len(desired) or {kind for kind, _ in refs} != set(desired):
                        raise RuntimeError('work_sync_originals_changed_during_write')
                    verified = {kind+'|'+identifier: self.sources.read(kind, identifier) for kind, identifier in refs}
                    if any(row.get('closed') or synced(row['content']) != synced(desired[key.split('|', 1)[0]])
                           for key, row in verified.items()):
                        raise RuntimeError('work_sync_readback_differs')
                    self.event(cid, {'status': 'done', **work['pending']})
                    with self.store._connect() as conn:
                        conn.execute("UPDATE common_work SET title=? WHERE common_id=? AND status='active'", (next(iter(desired.values()))['title'], cid))
                    work.pop('pending')
                    current = verified
                    self.reads[cid] = verified
                    messages.append('• 연결된 제목·할 일 목록·마감·완료를 맞췄어요.' if resolved is None else
                                    '• 소유자가 고른 원본 기준으로 제목·할 일을 맞췄어요.')
                except Exception as exc:
                    from notion_completion_sync import log_work_error
                    log_work_error(self.home, cid, 'work_content_write_uncertain', exc)
                    return {'handled': True, 'messages': messages + ['• ⚠️ 본문·할 일 반영 확인이 필요해 멈췄어요. 부분 반영 가능성이 있어 자동 재실행하지 않아요.']}
            if not authority:
                for kind, identifier in refs:
                    if kind == 'notion':
                        lines, current['notion|'+identifier] = self.due(cid, identifier, current['notion|'+identifier], state, path)
                        messages += lines
            if self.reminders and item.get('reminder_policy') != 'none':
                result = self.reminders(item, self.dry)
                for bucket in ('created', 'moved', 'completed', 'deleted', 'past_due', 'skipped'):
                    if result.get(bucket):
                        messages.append(f'• 할 일 미리알림 {bucket}: {len(result[bucket])}개')
            if not self.dry:
                work['sources'] = current
                if work.pop('conflict', None) and resolved is None:
                    resolved = {'choice': None, 'status': 'cleared'}
                content.save(path, state)
                work_tool_writes.clear(self.home, current, started)
        return {'handled': True, 'messages': messages, **({'resolved': resolved} if resolved else {})}
