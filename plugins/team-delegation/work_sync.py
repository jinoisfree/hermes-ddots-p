"""Owner-authorized full linked-work sync, using immutable baselines and a no-replay journal."""
from __future__ import annotations
import work_content as content

CONTENT_VERSION = 'work-content-v1'

def configured(home, sources, store, settings, **kwargs):
    return Engine(home, sources, store, **kwargs) if settings.get('content_sync', True) is True else None


class Engine:
    def __init__(self, home, sources, store, *, reminders=None, dry_run=False):
        self.home, self.sources, self.store = home, sources, store
        self.reminders, self.dry = reminders, dry_run

    def event(self, cid, payload):
        if not self.dry:
            with self.store._connect() as conn:
                self.store._event(conn, cid, 'work_sync', payload)

    def run(self, item):
        cid, messages = item['common_id'], []
        refs = self.sources.references(item)
        work_deadline = len(refs) == 1 and refs[0][0] == 'calendar'
        if (item.get('status') != 'active' and not work_deadline) or not refs:
            return {'handled': False, 'messages': []}
        duplicate_domains = len(refs) != len({kind for kind, _ in refs})
        if len(refs) == 1 or duplicate_domains:
            if self.reminders:
                result = self.reminders(item, self.dry)
                messages = [f'• 할 일 미리알림 {key}: {len(result[key])}개' for key in
                            ('created', 'moved', 'completed', 'deleted', 'past_due', 'skipped') if result.get(key)]
            return {'handled': True, 'messages': messages,
                    **({'connection_status': 'unsupported', 'connection_reason': 'single_original_per_domain_required'}
                       if duplicate_domains else {})}
        with content.ledger(self.home, 'work-sync') as (path, state):
            work = state['works'].get(cid)
            current = {kind+'|'+identifier: self.sources.read(kind, identifier) for kind, identifier in refs}
            if any(row.get('closed') for row in current.values()):
                return {'handled': True, 'messages': ['• ⚠️ 업무 원본이 삭제·보관됨 — 업무 자체 삭제는 전파하지 않았어요.']}
            if work is None or ((set(work['sources']) != set(current) or work.get('content_version') != CONTENT_VERSION)
                                and not work.get('pending')):
                if not self.dry:
                    state['works'][cid] = {'sources': current, 'content_version': CONTENT_VERSION}
                    content.save(path, state)
                return {'handled': True, 'messages': []}
            if work.get('pending'):
                wanted = work['pending']['after']
                if (set(wanted) == {kind for kind, _ in refs} and
                        all(content.semantic(row['content']) == wanted[key.split('|', 1)[0]] for key, row in current.items())):
                    if not self.dry:
                        self.event(cid, {'status': 'reconciled', **work['pending']})
                        work.pop('pending'); work['sources'] = current; content.save(path, state)
                else:
                    return {'handled': True, 'messages': ['• ⚠️ 앞선 본문·할 일 반영이 불명확해 자동 재실행하지 않았어요. 원본 확인이 필요해요.']}
            changed = [key for key in current if content.semantic(current[key]['content']) !=
                       content.semantic(work['sources'][key]['content'])]
            if changed:
                edits = [{field: value for field, value in content.semantic(current[key]['content']).items()
                          if value != content.semantic(work['sources'][key]['content'])[field]} for key in changed]
                alternatives = {content.digest(edit) for edit in edits}
                if len(alternatives) != 1:
                    return {'handled': True, 'messages': ['• ⚠️ 같은 점검 구간에 두 원본이 서로 다르게 바뀌었어요. 본문·할 일을 쓰지 않고 충돌로 보류했어요.']}
                desired = {kind: {**content.semantic(current[kind+'|'+identifier]['content']), **edits[0]}
                           for kind, identifier in refs}
                targets = [(kind, identifier) for kind, identifier in refs
                           if content.semantic(current[kind+'|'+identifier]['content']) != desired[kind]]
                for kind, identifier in targets:
                    self.sources.preflight(kind, identifier, current[kind+'|'+identifier], desired[kind])
                if self.dry:
                    return {'handled': True, 'messages': ['• [시험 실행] 연결된 제목·할 일·본문을 한 원본의 변경으로 맞출 예정이에요.']}
                work['pending'] = {'before': current, 'after': desired, 'targets': targets}
                content.save(path, state)
                self.event(cid, {'status': 'pending', **work['pending']})
                try:
                    for kind, identifier in targets:
                        current[kind+'|'+identifier] = self.sources.apply(kind, identifier, current[kind+'|'+identifier], desired[kind])
                    # Re-read every original, including the winning source: concurrent edits cannot be hidden.
                    refs = self.sources.references(self.store.get(cid))
                    verified = {kind+'|'+identifier: self.sources.read(kind, identifier) for kind, identifier in refs}
                    if any(content.semantic(row['content']) != desired[key.split('|', 1)[0]] for key, row in verified.items()):
                        raise RuntimeError('work_sync_readback_differs')
                    self.event(cid, {'status': 'done', **work['pending']})
                    with self.store._connect() as conn:
                        conn.execute("UPDATE common_work SET title=? WHERE common_id=? AND status='active'", (next(iter(desired.values()))['title'], cid))
                    work.pop('pending')
                    current = verified
                    messages.append('• 연결된 제목·할 일 목록·마감·완료·본문을 맞췄어요.')
                except Exception:
                    return {'handled': True, 'messages': ['• ⚠️ 본문·할 일 반영 확인이 필요해 멈췄어요. 부분 반영 가능성이 있어 자동 재실행하지 않아요.']}
            if self.reminders:
                result = self.reminders(item, self.dry)
                for bucket in ('created', 'moved', 'completed', 'deleted', 'past_due', 'skipped'):
                    if result.get(bucket):
                        messages.append(f'• 할 일 미리알림 {bucket}: {len(result[bucket])}개')
            if not self.dry:
                work['sources'] = current
                content.save(path, state)
        return {'handled': True, 'messages': messages}
