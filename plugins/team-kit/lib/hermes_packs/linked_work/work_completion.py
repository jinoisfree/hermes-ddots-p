"""Organic work completion (2026-10-26 owner decision).

Any completion signal (Notion 상태 Done, every task done, or the common work completed in
conversation) completes the work everywhere: Notion pages get 상태 Done with all to-dos checked, calendar events get a '✅ ' title
and the gray (graphite) Google color, and the memo moves to the Notes folder 'complete' (owner decision
2026-10-26: no question).
"""
from datetime import datetime, timedelta
from pathlib import Path
import json
import logging
import subprocess
import time

import importlib.util as _ilu, pathlib as _pl, sys as _sys
from hermes_facility import team_registry as team

DONE_MARK = '✅ '
GRAY = '8'  # Google Calendar event color "Graphite"
MOVE_FOLDER = 'complete'
STATUS = '상태'


PROGRESS_LINE = '진행도: '
IN_PROGRESS, DONE = '진행중', '완료'
NOTES_PER_PASS = 5  # memo rewrites can rebuild a note; spread the first fill over passes


def split_progress(notes):
    """Calendar notes start with '진행도: 진행중|완료'; return (progress, the rest)."""
    notes = str(notes or '')
    first, sep, rest = notes.partition('\n')
    if first.startswith(PROGRESS_LINE) and first[len(PROGRESS_LINE):].strip() in (IN_PROGRESS, DONE):
        return first[len(PROGRESS_LINE):].strip(), rest
    return '', notes


def with_progress(notes, progress):
    rest = split_progress(notes)[1]
    return f'{PROGRESS_LINE}{progress}\n{rest}' if progress else rest


def strip_mark(title):
    title = str(title or '')
    return title[len(DONE_MARK):] if title.startswith(DONE_MARK) else title


def setting(home):
    import hermes_yaml
    try:
        cfg = hermes_yaml.safe_load((Path(home) / 'config.yaml').read_text()) or {}
    except FileNotFoundError:
        return {}
    value = cfg.get('plugins', {}).get('entries', {}).get('team-delegation', {}).get('settings', {}) \
        .get('notion_completion_sync', {}).get('completion')
    return value if isinstance(value, dict) else {}


def enabled(home):
    return team.home_has_role(home, 'work') and setting(home).get('enabled') is True


class Completion:
    """Runs inside the linked-work watcher (Sync). Each step is journaled in sync.state['completions']."""

    def __init__(self, sync, *, since, calendar_service=None, notes_runner=subprocess.run):
        self.sync, self.since = sync, float(since)
        self.calendar_service = calendar_service
        self.notes_runner = notes_runner

    @property
    def journal(self):
        return self.sync.state.setdefault('completions', {})

    # ---- detection -------------------------------------------------------------------------
    def signal(self, item):
        if item['status'] == 'completed':
            return 'completed'
        if item['status'] != 'active':
            return None
        sources = self.sync.content_engine.sources
        reads = getattr(self.sync.content_engine, 'reads', {}).get(item['common_id']) or {}
        tasks, task_originals = [], 0
        refs = sources.references(item)
        authority = getattr(sources, 'authority', lambda *_: None)(item, refs)
        for kind, identifier in ([authority] if authority else refs):
            row = reads.get(kind + '|' + identifier) or sources.read(kind, identifier)
            if row.get('closed'):
                return None  # Cancelled or trashed is not completion.
            if kind == 'notion':
                page = row['raw']['page']
                if ((page.get('properties', {}).get(STATUS, {}).get('status') or {}).get('name')) == 'Done':
                    return 'notion_done'
            if row['content']['tasks']:
                task_originals += 1
                tasks += row['content']['tasks']
        if tasks:
            return 'all_tasks_done' if all(t.get('done') for t in tasks) else None
        # A memo or Notion page without tasks is not evidence that the work is done (CIIE, 2026-10-26).
        return None

    def has_open_task(self, item):
        sources = self.sync.content_engine.sources
        refs = sources.references(item)
        authority = getattr(sources, 'authority', lambda *_: None)(item, refs)
        for kind, identifier in ([authority] if authority else refs):
            if any(not t.get('done') for t in sources.read(kind, identifier)['content']['tasks']):
                return True
        return False

    def rebaseline(self, item, kind, identifier):
        """After a 진행도 write, the linked-work sync must not read the new mark as an owner edit."""
        from hermes_packs.linked_work import work_content as content
        cid = item['common_id']
        with content.ledger(self.sync.path.parent.parent, 'work-sync') as (path, state):
            work = state['works'].get(cid)
            key = kind + '|' + identifier
            if work and not work.get('pending') and key in work.get('sources', {}):
                work['sources'][key] = self.sync.content_engine.sources.read(kind, identifier)
                content.save(path, state)

    def check(self, item):
        """Called per active work after the content sync; never raises into the watcher."""
        cid = item['common_id']
        record = self.journal.get(cid)
        if any(src.get('metadata', {}).get('owner_scope') == 'personal' for src in item['sources']):
            return  # personal originals stay with the personal assistant
        if record and record.get('ongoing'):
            # The owner said it is still in progress. Re-arm only on positive evidence (an open task
            # read successfully), never because a read failed or the signal briefly disappeared.
            try:
                if self.has_open_task(item) and not self.sync.dry:
                    self.journal.pop(cid, None)
                    self.sync.persist()
            except Exception:
                pass
            return
        if record and record.get('done'):
            if not record['steps'].get('progress') and not self.sync.dry:
                try:
                    lines = self.mark_progress(self.sync.store.get(cid), DONE, record['steps'])
                    for line in lines:
                        self.sync.say(line)
                except Exception as exc:
                    from hermes_packs.linked_work.diagnostics import log_work_error
                    log_work_error(self.sync.path.parent.parent, cid, 'completion_progress_failed', exc)
            return
        try:
            reason = record['reason'] if record else self.signal(item)
            if reason and not self.sync.state.get('completion_baseline'):
                # First pass after enabling: works that already look complete are recorded, not written.
                if not self.sync.dry:
                    self.journal[cid] = {'reason': reason, 'at': time.time(), 'steps': {}, 'ongoing': True, 'preexisting': True}
                return
            if reason:
                self.cascade(self.sync.store.get(cid), reason)
        except Exception as exc:
            from hermes_packs.linked_work.diagnostics import log_work_error
            log_work_error(self.sync.path.parent.parent, cid, 'completion_cascade_failed', exc)

    def finish_pass(self):
        self.sync.state.pop('_progress_budget', None)
        if not self.sync.dry and not self.sync.state.get('completion_baseline'):
            self.sync.state['completion_baseline'] = time.time()
            self.sync.persist()

    def completed_items(self):
        """Works completed outside the watcher (conversation) after the feature start."""
        with self.sync.store._connect() as conn:
            rows = conn.execute("SELECT common_id FROM common_work WHERE status='completed' AND completed_at>=?",
                                (self.since,)).fetchall()
        def pending(cid):
            record = self.journal.get(cid) or {}
            return not record.get('done') or not record.get('steps', {}).get('progress')
        return [self.sync.store.get(r['common_id']) for r in rows if pending(r['common_id'])]

    # ---- cascade ---------------------------------------------------------------------------
    def cascade(self, item, reason):
        cid = item['common_id']
        record = self.journal.setdefault(cid, {'reason': reason, 'at': time.time(), 'steps': {}})
        steps, lines = record['steps'], []
        if self.sync.dry:
            self.sync.say(f'• [시험 실행] 업무 완료({reason}) — 노션·일정에 완료를 표시할 예정이에요.')
            return
        if item['status'] != 'completed':
            self.sync.store.complete(cid, approved=True)
        self.sync.persist()
        for ref in item.get('knowledge_refs', []):
            if ref['ref_type'] == 'notion_page' and not steps.get('notion:' + ref['external_id']):
                checked = self.notion_done(ref['external_id'])
                steps['notion:' + ref['external_id']] = True
                self.sync.persist()
                lines.append('• 노션 상태 Done' + (f', 할 일 {checked}개 체크' if checked else ''))
        for source in item['sources']:
            if source['domain'] == 'calendar' and not steps.get('calendar:' + source['source_id']):
                lines.append(self.calendar_done(source['source_id']))
                steps['calendar:' + source['source_id']] = True
                self.sync.persist()
        if not steps.get('progress'):
            lines += self.mark_progress(self.sync.store.get(cid), DONE, steps)
        # 2026-10-26 owner decision: move the memo without asking, report only (reversible).
        if not steps.get('moved'):
            notes = [s['source_id'] for s in self.sync.store.get(cid)['sources'] if s['domain'] == 'notes']
            moved = [nid for nid in notes if move_note(nid, self.notes_runner)]
            if notes:
                lines.append(f'• 메모 {len(moved)}개를 `{MOVE_FOLDER}` 폴더로 옮겼어요.' if len(moved) == len(notes)
                             else f'• ⚠️ 메모 {len(notes)}개 중 {len(moved)}개만 `{MOVE_FOLDER}` 폴더로 옮겼어요.')
            if len(moved) == len(notes):
                steps['moved'] = True
        record['done'] = True
        self.sync.persist()
        labels = {'completed': '업무 완료 처리', 'notion_done': '노션 Done', 'all_tasks_done': '할 일 모두 완료'}
        self.sync.say(f'• ✅ 업무 완료 — {labels.get(reason, reason)}')
        for line in lines:
            self.sync.say(line)

    def mark_progress(self, item, progress, steps):
        """Set 진행도 on every linked memo and calendar event; returns report lines."""
        tools, lines = self.sync.calendar.tools(), []
        for source in item['sources']:
            if source['domain'] == 'notes':
                if self.sync.state.get('progress_skip', {}).get(source['source_id']):
                    continue  # known not writable (tables, photos+documents, no saved originals)
                result = tools._set_linked_note_progress(source['source_id'], progress)
                if not result.get('ok'):
                    self.sync.state.setdefault('progress_skip', {})[source['source_id']] = result.get('reason') or 'failed'
                    lines.append('• 메모 진행도는 표시하지 못했어요(메모 형식상 다시 쓰지 않음).')
                elif result.get('changed'):
                    self.rebaseline(item, 'notes', result.get('note_id') or source['source_id'])
                    lines.append(f'• 메모 진행도: {progress}')
            elif source['domain'] == 'calendar':
                event = self.sync.calendar.get(source['source_id'])
                if event and not event.get('recurring') and split_progress(event.get('notes'))[0] != progress:
                    self.sync.calendar.set_notes(event, with_progress(event.get('notes'), progress))
                    self.rebaseline(item, 'calendar', source['source_id'])
                    lines.append(f'• 일정 진행도: {progress}')
        steps['progress'] = True
        self.sync.persist()
        return lines

    def fill_progress(self, item):
        """Active works show 진행도: 진행중 on their memo and calendar event (first fill is spread out)."""
        if any(src.get('metadata', {}).get('owner_scope') == 'personal' for src in item['sources']):
            return
        skipped = self.sync.state.setdefault('progress_skip', {})
        budget = self.sync.state.setdefault('_progress_budget', {})
        tools = self.sync.calendar.tools()
        for source in item['sources']:
            sid = source['source_id']
            if source['domain'] not in ('notes', 'calendar') or skipped.get(sid):
                continue
            try:
                if source['domain'] == 'calendar':
                    event = self.sync.calendar.get(sid)
                    if event and not event.get('recurring') and not split_progress(event.get('notes'))[0]:
                        self.sync.calendar.set_notes(event, with_progress(event.get('notes'), IN_PROGRESS))
                        self.rebaseline(item, 'calendar', sid)
                        self.sync.say(f'• 일정 진행도: {IN_PROGRESS}')
                    continue
                seen = self.sync.state.setdefault('progress_seen', {})
                read = (getattr(self.sync.content_engine, 'reads', {}).get(item['common_id']) or {}).get('notes|' + sid)
                html = (read or {}).get('raw', {}).get('body_html') if read else None
                if html is not None:
                    seen[sid] = tools._note_progress(html)
                if seen.get(sid) or budget.get('used', 0) >= NOTES_PER_PASS:
                    continue
                result = tools._set_linked_note_progress(sid, IN_PROGRESS)
                if result.get('changed') and result.get('ok'):
                    budget['used'] = budget.get('used', 0) + 1
                    self.rebaseline(item, 'notes', result.get('note_id') or sid)
                    self.sync.say(f'• 메모 진행도: {IN_PROGRESS}')
                if result.get('ok'):
                    seen[result.get('note_id') or sid] = IN_PROGRESS
                else:
                    skipped[sid] = result.get('reason') or 'failed'  # unstructured or unreadable: do not retry
            except Exception as exc:
                skipped[sid] = type(exc).__name__
                from hermes_packs.linked_work.diagnostics import log_work_error
                log_work_error(self.sync.path.parent.parent, item['common_id'], 'progress_fill_failed', exc)
        self.sync.persist()

    def notion_done(self, page_id):
        from hermes_packs.linked_work.source_adapters import DATABASE, page_id as normalize
        reader = self.sync.reader
        page = reader.page(page_id)
        if (normalize(page.get('parent', {}).get('database_id', '')) != DATABASE
                or page.get('in_trash') or page.get('archived')):
            raise ValueError('completion_notion_scope_changed')
        if ((page.get('properties', {}).get(STATUS, {}).get('status') or {}).get('name')) != 'Done':
            reader.request('PATCH', f'pages/{page_id}', {'properties': {STATUS: {'status': {'name': 'Done'}}}})
            after = reader.page(page_id)
            if ((after.get('properties', {}).get(STATUS, {}).get('status') or {}).get('name')) != 'Done':
                raise RuntimeError('completion_notion_status_unverified')
        checked = 0
        for block in reader.blocks(page_id):
            if (block.get('type') == 'to_do' and not block['to_do'].get('checked')
                    and not block.get('archived') and not block.get('in_trash')):
                reader.check_todo(block['id'])
                checked += 1
        return checked

    def calendar_done(self, event_id):
        calendar = self.sync.calendar
        event = calendar.get(event_id)
        if not event:
            return '• ⚠️ 일정을 찾지 못해 완료 표시를 하지 못했어요.'
        if event.get('recurring'):
            return '• 반복 일정은 완료 표시를 하지 않았어요.'
        color = self.gray(event)
        if not str(event.get('title') or '').startswith(DONE_MARK):
            calendar.rename(event, DONE_MARK + event['title'])
        return '• 일정 제목에 ✅' + (', 색 회색' if color else ' (Google 색은 바꾸지 못함)')

    def gray(self, event):
        """Company events live in the company account's primary calendar; match one Google event by title and start."""
        try:
            service = self.calendar_service or company_calendar_service()
            start = datetime.fromisoformat(str(event['start']).replace('Z', '+00:00'))
            listed = service.events().list(calendarId='primary', timeMin=(start - timedelta(minutes=1)).isoformat(),
                                           timeMax=(start + timedelta(days=1)).isoformat(), singleEvents=True,
                                           showDeleted=False, maxResults=50).execute()
            titles = {event['title'], DONE_MARK + strip_mark(event['title'])}
            def starts(item):
                value = item.get('start') or {}
                if event.get('isAllDay'):
                    return value.get('date') == str(event['start'])[:10]
                try:
                    return abs(datetime.fromisoformat(value['dateTime'].replace('Z', '+00:00')).timestamp()
                               - start.timestamp()) < 1
                except (KeyError, ValueError):
                    return False
            matches = [i for i in listed.get('items') or [] if i.get('summary') in titles and starts(i)]
            if len(matches) != 1:
                return False
            if matches[0].get('colorId') == GRAY:
                return True
            result = service.events().patch(calendarId='primary', eventId=matches[0]['id'],
                                            body={'colorId': GRAY}, sendUpdates='none').execute()
            return result.get('colorId') == GRAY
        except Exception as exc:
            logging.getLogger(__name__).warning('completion_calendar_color_failed:%s', type(exc).__name__)
            return False


def company_calendar_service():
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request
    from googleapiclient.discovery import build
    path = Path.home() / '.hermes/google_token.json'
    data = json.loads(path.read_text())
    credentials = Credentials.from_authorized_user_info(data, data.get('scopes'))
    if not credentials.valid and credentials.refresh_token:
        credentials.refresh(Request())  # in memory only; the mail tools own the token file
    return build('calendar', 'v3', credentials=credentials, cache_discovery=False)


def move_note(note_id, runner=subprocess.run):
    from hermes_packs.notes import obsidian_notes
    if obsidian_notes.handles(note_id):return obsidian_notes.move_completed(note_id)
    script = str(Path(obsidian_notes.__file__).with_name('apple_notes_mutation.applescript'))
    proc = runner(['/usr/bin/osascript', script, 'move', note_id, MOVE_FOLDER, '', ''],
                  capture_output=True, text=True, timeout=60, check=False)
    return proc.returncode == 0  # the script re-resolves the note and confirms the destination folder
