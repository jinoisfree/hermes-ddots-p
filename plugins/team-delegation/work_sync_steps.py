"""Watcher-only step accounting and conservative independent reminder continuation.

No new durable journal: the native writers own pending/receipts, and the watcher
stores only this pass's aggregate. Never replay a reminder call made in this pass.
"""
import json
import time

import work_content as content

REMINDER_WARNING = '• ⚠️ 할 일 미리알림 반영 확인이 필요해요. 성공한 작업은 유지하고 불명확한 쓰기는 재실행하지 않아요.'
BUCKETS = ('created', 'moved', 'completed', 'deleted', 'past_due', 'skipped')


def summary(result):
    counts = {k: len(result.get(k) or []) for k in (*BUCKETS, 'no_due')}
    policy_skips = {'excluded', 'user_modified_or_removed', 'source_removed_no_delete_propagation',
                    'calendar_only_no_reminders', 'no_due'}
    blocked = any(r.get('reason') not in policy_skips for r in result.get('skipped') or [])
    status = ('blocked' if result.get('execution_uncertain') or blocked else
              'failed' if result.get('ok') is False else
              'applied' if result.get('mutation_calls', 0) else 'checked')
    return {'status': status, 'counts': counts}


def lines(result):
    result_lines = [f'• 할 일 미리알림 {k}: {len(result[k])}개' for k in BUCKETS if result.get(k)]
    if summary(result)['status'] in {'blocked', 'failed'}:
        result_lines.append(REMINDER_WARNING)
    return result_lines


class Steps:
    def __init__(self, home, runner):
        self.home, self.runner = home, runner
        self.results = {}
        self.engine = None

    def begin(self, cid):
        self.results.pop(cid, None)
        if self.engine is not None:
            self.engine.reads.pop(cid, None)

    def reminders(self, item, dry, *, authority=None):
        cid = item['common_id']
        if cid in self.results:
            raise RuntimeError('reminder_step_already_attempted')
        # Normal callbacks may run while Engine holds work-sync.lock. Read its atomic
        # snapshot without acquiring that lock again. An uncertain authority date is
        # not a safe basis for reminder writes (including single-task date fallback).
        path = self.home/'state/work-sync.json'
        if path.exists():
            state = json.loads(path.read_text())
            notions = [r['external_id'] for r in item.get('knowledge_refs', []) if r.get('ref_type') == 'notion_page']
            if any(state.get('notion_due', {}).get(sid, {}).get('pending') for sid in notions):
                result = {'ok': False, 'mutation_calls': 0, 'skipped': [{'reason': 'authority_write_pending'}]}
                self.results[cid] = summary(result)
                return result
        self.results[cid] = {'status': 'failed'}  # mark before any native work
        try:
            result = self.runner(item, dry, authority=authority)
        except Exception as exc:
            # Fixed type only; no original contents or exception message in the aggregate.
            self.results[cid] = {'status': 'failed', 'error_type': type(exc).__name__}
            raise
        self.results[cid] = summary(result)
        return result

    def independent(self, item, dry, decisions=None):
        """Only established shared Notion authority; fail closed on legacy/unknown journals."""
        from work_sync import CONTENT_VERSION, content_refs
        cid = item['common_id']
        if cid in self.results or self.engine is None:
            return []
        if item.get('scope') != 'shared' or item.get('status') != 'active' or item.get('reminder_policy') == 'none':
            return []
        # Do not infer a different authority or adopt a changed link during recovery.
        fresh = self.engine.store.get(cid)
        def signature(value):
            sources = [(r['domain'], r['source_id'], r.get('metadata', {}).get('owner_scope'),
                        r.get('metadata', {}).get('identity')) for r in value.get('sources', [])]
            notions = [(r['external_id'], r.get('metadata', {}).get('owner_scope'),
                        r.get('metadata', {}).get('identity')) for r in value.get('knowledge_refs', [])
                       if r.get('ref_type') == 'notion_page']
            return content.digest([value.get('status'), value.get('scope'), value.get('reminder_policy'), sources, notions])
        if signature(fresh) != signature(item):
            return []
        if any(r.get('metadata', {}).get('link_state', {}).get('status', 'ok') not in {'ok', 'transient'}
               for r in [*item.get('sources', []), *item.get('knowledge_refs', [])]):
            return []
        item = fresh  # lifecycle refreshes timestamps/failure counts even when link IDs did not change
        current = self.engine.reads.get(cid, {})
        if any(row.get('closed') for row in current.values()):
            return []
        refs, states = [], {}
        for row in item.get('sources', []):
            kind, sid = row['domain'], row['source_id']
            if kind not in {'notes', 'calendar', 'todo'}:
                continue
            meta = row.get('metadata', {})
            if meta.get('owner_scope') != 'company':
                return []
            status = meta.get('link_state', {}).get('status', 'ok')
            if status not in {'ok', 'transient'} or (kind == 'todo' and status != 'ok'):
                return []
            if kind != 'todo':
                refs.append((kind, sid))
                states[(kind, sid)] = status
        for row in item.get('knowledge_refs', []):
            if row.get('ref_type') == 'notion_page':
                ref = ('notion', row['external_id'])
                refs.append(ref)
                states[ref] = row.get('metadata', {}).get('link_state', {}).get('status', 'ok')
        if decisions is not None:
            for d in decisions:
                ref = (d['domain'], d['source_id'])
                if d.get('old_id') or d['status'] not in {'ok', 'transient'}:
                    return []
                if d['domain'] == 'todo' and d['status'] != 'ok':
                    return []
                states[ref] = d['status']
        notions = [ref for ref in refs if ref[0] == 'notion']
        if len(notions) != 1 or states.get(notions[0]) != 'ok':
            return []
        authority = self.engine.sources.authority(item, refs)
        if authority != notions[0]:
            return []
        refs = content_refs(refs)
        if len(refs) < 2 or len(refs) != len({k for k, _ in refs}):
            return []
        keys = {k+'|'+sid for k, sid in refs}
        if not (self.home/'state/work-sync.json').is_file():
            return []
        with content.ledger(self.home, 'work-sync') as (_, state):
            work = state['works'].get(cid)
            if not work or work.get('content_version') != CONTENT_VERSION or set(work.get('sources', {})) != keys:
                return []
            if any(r.get('closed') for r in work['sources'].values()):
                return []
            pending = work.get('pending')
            if pending:
                targets = pending.get('targets')
                if (not isinstance(targets, list) or not targets or set(pending.get('before', {})) != keys or
                        any(not isinstance(t, (list, tuple)) or len(t) != 2 or
                            t[0] not in {'notes', 'calendar'} or tuple(t) not in refs for t in targets)):
                    return []
            if state.get('notion_due', {}).get(authority[1], {}).get('pending'):
                return []
        # Source adapter re-reads company Notion, tasks, reminder scope and write preconditions.
        result = self.reminders(item, dry, authority=authority)
        return lines(result)

    def finish(self, item, outcome=None, *, error=None, decisions=None, dry=False):
        from notion_completion_sync import content_warning_code
        outcome = outcome or {'handled': True, 'messages': []}
        messages = list(outcome.get('messages', []))
        warnings = [line for line in messages if '⚠️' in line]
        blocked = bool(error or warnings or outcome.get('conflict') or
                       outcome.get('connection_status', 'ok') != 'ok' or
                       decisions and any(d['status'] != 'ok' for d in decisions))
        if blocked:
            try:
                messages += self.independent(item, dry, decisions)
            except Exception as exc:
                self.results.setdefault(item['common_id'], {'status': 'failed', 'error_type': type(exc).__name__})
        reminder = self.results.get(item['common_id'], {'status': 'not_run'})
        if reminder['status'] in {'blocked', 'failed'} and not reminder.get('error_type') and REMINDER_WARNING not in messages:
            messages.append(REMINDER_WARNING)
        content_status = 'blocked' if blocked else 'checked' if outcome.get('handled') else 'not_run'
        status = ('partial' if blocked and reminder['status'] in {'checked', 'applied'} else
                  'blocked' if blocked else
                  'partial' if reminder['status'] in {'blocked', 'failed'} else 'checked')
        record = {'status': status, 'checked_at': time.time(),
                  'content': {'status': content_status}, 'reminders': reminder}
        if warnings:
            record['content']['reason'] = content_warning_code(warnings[0]) or 'content_blocked'
        if error:
            record['content']['error_type'] = type(error).__name__
        return {**outcome, 'messages': messages, 'execution': record}
