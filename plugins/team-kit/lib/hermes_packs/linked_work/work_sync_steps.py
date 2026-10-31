"""Watcher-only step accounting for one linked-work pass.

No new durable journal: the native writers own pending/receipts, and the watcher
stores only this pass's aggregate. (2026-10-31: the Reminders step was removed.)
"""
import time


class Steps:
    def __init__(self, home):
        self.home = home
        self.engine = None

    def begin(self, cid):
        if self.engine is not None:
            self.engine.reads.pop(cid, None)

    def finish(self, item, outcome=None, *, error=None, decisions=None, dry=False):
        from hermes_packs.linked_work.diagnostics import content_warning_code
        outcome = outcome or {'handled': True, 'messages': []}
        messages = list(outcome.get('messages', []))
        warnings = [line for line in messages if '⚠️' in line]
        blocked = bool(error or warnings or outcome.get('conflict') or
                       outcome.get('connection_status', 'ok') != 'ok' or
                       decisions and any(d['status'] != 'ok' for d in decisions))
        content_status = 'blocked' if blocked else 'checked' if outcome.get('handled') else 'not_run'
        record = {'status': 'blocked' if blocked else 'checked', 'checked_at': time.time(),
                  'content': {'status': content_status}}
        if warnings:
            record['content']['reason'] = content_warning_code(warnings[0]) or 'content_blocked'
        if error:
            record['content']['error_type'] = type(error).__name__
        return {**outcome, 'messages': messages, 'execution': record}
