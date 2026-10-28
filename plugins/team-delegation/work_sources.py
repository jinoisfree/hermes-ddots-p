"""Company-only adapters for the owner's linked-work synchronization exception."""
from __future__ import annotations
import difflib
import json
import re
import subprocess
from datetime import datetime, timedelta

import work_content as content
import deadline_time as dates
import source_lookup
import notion_task_dates

TEXT_BLOCKS = {'paragraph', 'heading_1', 'heading_2', 'heading_3', 'bulleted_list_item',
               'numbered_list_item', 'quote', 'callout', 'toggle', 'code', 'table_row'}


def ordered_blocks(blocks):
    """NotionReader fetches descendants in batches; recover document order from their parents."""
    ids = {row['id'] for row in blocks}
    children = {}
    for row in blocks:
        parent = row.get('parent', {}).get('block_id')
        children.setdefault(parent if parent in ids else None, []).append(row)
    def visit(parent):
        for row in children.get(parent, []):
            yield row
            yield from visit(row['id'])
    return list(visit(None))


def body_text(block):
    if block['type'] == 'table_row':
        return '\t'.join(content.rich_text({'rich_text': cell}) for cell in block['table_row']['cells']).rstrip('\t')
    return content.rich_text(block[block['type']])


def rich(value):
    return [{'type': 'text', 'text': {'content': value[i:i+1900]}} for i in range(0, len(value), 1900)]


def stable_notion(value):
    """Notion returns a fresh request_id and freshly signed file URLs on every read.

    Drop the request_id and keep only the file path (its identity) so an unchanged page keeps
    one revision; otherwise every pre-write check sees a change and the write never runs.
    """
    if isinstance(value, dict):
        if set(value) == {'url', 'expiry_time'}:
            return {'url': str(value['url']).split('?', 1)[0]}
        return {key: stable_notion(item) for key, item in value.items() if key != 'request_id'}
    if isinstance(value, list):
        return [stable_notion(item) for item in value]
    return value


DUE = '다음 마감'


def due_property(props, explicit, status_name):
    """The page's '다음 마감' and the value its own dated to-dos call for; None when it is not ours to set
    (no such date property, a date range, an unreadable value, or a page already Done)."""
    value = props.get(DUE)
    if not isinstance(value, dict) or value.get('type', 'date') != 'date' or status_name == 'Done':
        return None
    date = value.get('date') or {}
    if date.get('end'):
        return None
    try:
        page = dates.canonical(date.get('start'))
    except ValueError:
        return None
    result = {'page': page, 'wanted': content.due_target(explicit, page), 'explicit': explicit}
    opened = [row for row in explicit if not row.get('done')]
    if any(row.get('ambiguous') for row in opened):
        result['problem'] = 'ambiguous_task_deadline'
    elif page and dates.past(page) and opened and not any(row.get('due') for row in opened):
        # An expired page date is not evidence for an undated task. Surface the gap rather than
        # silently calling the stale value correct or fabricating a reminder from it.
        result['problem'] = 'stale_undated_notion_deadline'
    return result


def _note_summary_line(line, nested=False):
    hit = re.match(r'\s*- ([^:]+):\s*(.*?)\s*\|\s*(.*)', line)
    if hit:
        section, label, value = hit.groups()
    else:
        # Only task rows may omit the deadline separator; body rows still need a value.
        hit = re.match(r'\s*- (할 일):\s*(.*)', line)
        if not hit:
            # A nested detail row with no section of its own ('  - 장소 | 코엑스') is body text of its
            # parent. Unparsed, it sent the whole memo to the plaintext reading, whose task wording
            # differs from the task rows (진단담당 진단 89267e81, 2026-10-29).
            sub = nested and re.match(r'\s+- ([^:|\[\]{}\n]+?)\s*\|\s*(.*)', line)
            if sub:
                return sub[1].strip()+': '+sub[2]
            raise ValueError('note_summary_incomplete')
        section, label = hit.groups()
        value = ''
    label = re.sub(r'^(\[[ xX]\]\s*)?\{fmt:[^}]+\}\s*', lambda m: m[1] or '', label)
    if section == '할 일':
        mark = re.match(r'^(\[[ xX]\])\s*(.*)', label)
        name = mark[2] if mark else label
        if name.strip() == '다음 마감':
            # A display row of the nearest deadline, not a task.
            return name.strip()+': '+value
        # content.task strips before splitting; an empty " | " would become part of the title.
        return (mark[1]+' '+name if mark else '[ ] '+label)+(' | '+value if value.strip() else '')
    return value if section == '본문' else label+': '+value


def _attachment_keys(note):
    """Attachment names up to the first content digest: a rebuild re-exports each file into the note-file
    store, which appends '_<digest>' again (and cuts long names at 40 characters), so 'a.png',
    'a_<d>.png' and 'a_<d>_<d>.png' are the same attachment (2026-10-28 scratch-note check)."""
    return sorted(re.sub(r'_[0-9a-f]{16}.*(?=\.[^.]+$)', '', str(name)) for name in note.get('attachment_names') or [])


def _summary_lines(summary):
    """Readable lines of a memo summary. Detail rows are tolerated only when the summary has its own task
    rows: a memo without them keeps reading its tasks from the plain text (checkbox lines elsewhere)."""
    lines = str(summary).splitlines()
    nested = any(re.match(r'\s*- 할 일:', line) for line in lines)
    return [_note_summary_line(line, nested) for line in lines]


SUMMARY_ROW = re.compile(r'^(\s*- )([^:{\n]+)(:\s*)(\[[ xX]\]\s*)?(\{fmt:[^}]+\}\s*)?(.*)$')
INFO_SECTION = '참고'


def _summary_tasks(summary):
    """(line index, task) for each task row of a memo summary, read row by row like Sources.read."""
    rows = []
    for index, line in enumerate(str(summary).splitlines()):
        try:
            found = content.from_text('', _note_summary_line(line))['tasks']
        except ValueError:
            continue
        if found:
            rows.append((index, found[0]))
    return rows


def _task_row(section, row, fmt=''):
    """One summary task row that reads back as exactly this task, or None (section rows need ' | ')."""
    text, mark = row['text'], '[x]' if row['done'] else '[ ]'
    if section == '할 일':  # here ' | ' carries the deadline
        tail = text + (f" | {row['due']}" if row.get('due') else '')
    elif row.get('due'):
        tail = f"{text} | {row['due']}"
    elif ': ' in text:
        tail = ' | '.join(text.split(': ', 1))
    else:
        return None
    return f"- {section}: {mark} {fmt}{tail}"


def structured_edit(summary, own, wanted):
    """Give a structured memo summary the wanted task list by touching task rows only (2026-10-28 사용자
    결정): a kept task flips its mark in place, a renamed task keeps its row and section, a task gone from
    the other original stays as an unmarked info row (nothing is deleted), and a new task joins the
    '할 일' section. Sections, sub rows, colors and every other row are left as they are.
    None when the rows cannot be aligned with the memo's own tasks."""
    lines = str(summary).splitlines()
    rows = _summary_tasks(summary)
    if [r for _, r in rows] != content.semantic({'tasks': own})['tasks']:
        return None
    # A soft line break inside a Notion to-do becomes ' · ' (task_key ignores both).
    wanted = [dict(r, text=' · '.join(x.strip() for x in str(r['text']).splitlines() if x.strip())) for r in wanted]
    if any('|' in r['text'] or not r['text'] for r in wanted):
        return None
    parts = {}
    for index, _ in rows:
        hit = SUMMARY_ROW.match(lines[index])
        if not hit or hit[1] != '- ':
            return None  # nested or unlabeled task rows are not rewritten
        parts[index] = hit
    keys = [content.task_key(r['text']) for r in wanted]
    used, pairs = set(), {}
    for index, row in rows:
        match = next((i for i, key in enumerate(keys) if key == content.task_key(row['text']) and i not in used), None)
        if match is not None:
            used.add(match)
            pairs[index] = (wanted[match], False)
    gone = [index for index, _ in rows if index not in pairs]
    new = [i for i in range(len(wanted)) if i not in used]
    # A renamed task keeps its row when the wording stays close; anything else is an info row plus a new row.
    own_text = dict(rows)
    for index in list(gone):
        score = lambda i: difflib.SequenceMatcher(None, content.task_key(own_text[index]['text']), keys[i]).ratio()
        close = max(new, key=score, default=None)
        if close is not None and score(close) >= 0.75 and _task_row(
                parts[index][2].strip(), wanted[close], parts[index][5] or ''):
            pairs[index] = (wanted[close], True)
            gone.remove(index)
            new.remove(close)
    for index, (row, renamed) in pairs.items():
        hit = parts[index]
        if renamed:
            lines[index] = _task_row(hit[2].strip(), row, hit[5] or '')
        else:
            lines[index] = f"{hit[1]}{hit[2]}{hit[3]}{'[x]' if row['done'] else '[ ]'} {hit[5] or ''}{hit[6]}"
    for index in gone:
        hit = parts[index]
        section = INFO_SECTION if hit[2].strip() == '할 일' else hit[2]
        rest = hit[6] if '|' in hit[6] else hit[6] + ' | '
        lines[index] = f"{hit[1]}{section}{hit[3]}{hit[5] or ''}{rest}"
    if new:
        anchor = max((index for index, hit in parts.items() if hit[2].strip() == '할 일'), default=None)
        if anchor is None:
            at = len(lines)
        else:
            at = anchor + 1
            while at < len(lines) and re.match(r'^\s+- ', lines[at]):
                at += 1
        lines[at:at] = [_task_row('할 일', wanted[i]) for i in new]
    return '\n'.join(lines)


def structured_content(title, summary):
    """What Sources.read will see in a memo carrying this summary."""
    return content.semantic(content.from_text(title, '\n'.join(_summary_lines(summary))))


class Sources:
    def __init__(self, home, *, reader=None, notes=None, calendar=None):
        import notion_completion_sync as sync
        self.home = home
        self.reader = reader or sync.NotionReader(home)
        self.notes = notes or sync.Notes()
        self.calendar = calendar or sync.Calendar()
        self.guard = sync.company_scope_guard
        self.database = sync.DATABASE
        self.aliases = {}

    def authority(self, item, refs=None):
        import work_policy
        item = work_policy.permitted(item)
        import obsidian_store
        if not obsidian_store.enabled(getattr(self,'home',None)):return None
        notions = [('notion', r['external_id']) for r in item.get('knowledge_refs', []) if r['ref_type']=='notion_page']
        if item.get('scope')=='shared' and not notions:
            raise source_lookup.SourceReadError('transient','shared_notion_original_required')
        notes = [('notes', r['source_id']) for r in item.get('sources', []) if r['domain']=='notes']
        candidates = notions or notes
        if not candidates:return None
        if len(candidates)!=1:raise source_lookup.SourceReadError('unsupported', 'multiple_authoritative_originals')
        if refs is not None and candidates[0] not in refs:
            raise source_lookup.SourceReadError('transient', 'authoritative_original_unavailable')
        if not notions and not obsidian_store.is_id(candidates[0][1]):
            raise source_lookup.SourceReadError('unsupported', 'obsidian_migration_required')
        return candidates[0]

    def references(self, item):
        import work_policy
        item = work_policy.permitted(item)
        refs = [('notion', r['external_id']) for r in item.get('knowledge_refs', []) if r['ref_type'] == 'notion_page' and r.get('metadata',{}).get('link_state',{}).get('status','ok')=='ok']
        refs += [(s['domain'], s['source_id']) for s in item.get('sources', []) if s['domain'] in {'notes', 'calendar'} and s.get('metadata',{}).get('link_state',{}).get('status','ok')=='ok']
        self.authority(item, refs)  # A failed/hidden Notion is never equivalent to no Notion.
        return refs

    def read(self, kind, identifier):
        identifier = self.aliases.get(identifier, identifier)
        if kind == 'notion':
            import work_policy
            if work_policy.notion_problem({'page_id':identifier}):
                raise ValueError(work_policy.ERROR)
            page = self.reader.page(identifier)
            if str(page.get('parent', {}).get('database_id', '')).replace('-', '').lower() != self.database:
                raise source_lookup.SourceReadError('out_of_scope', 'company_notion_database_required')
            from notion_completion_sync import page_title
            blocks = ordered_blocks(self.reader.blocks(identifier))
            tasks, lines = notion_task_dates.read(blocks), []
            for block in blocks:
                key = block.get('type')
                if block.get('archived') or block.get('in_trash'):
                    continue
                if key in TEXT_BLOCKS:
                    line = body_text(block)
                    if key != 'table_row' or line.strip():
                        lines.append(line)
            props = page.get('properties', {})
            status = props.get('상태', {})
            status_name = (status.get('status') or status.get('select') or {}).get('name')
            if status_name == 'Done':
                for row in tasks:
                    row['done'] = True
            due = (props.get('다음 마감', {}).get('date') or {}).get('start')
            explicit = content.semantic({'tasks': tasks})['tasks']  # before the single-task page fallback
            due_info = due_property(props, explicit, status_name)
            if (len(tasks) == 1 and not tasks[0].get('due') and not tasks[0].get('ambiguous') and due
                    and not (due_info or {}).get('problem')):
                tasks[0]['due'] = dates.canonical(due)
            closed = bool(page.get('in_trash') or page.get('archived') or status_name == 'Cancelled')
            result = {'content': {'title': page_title(page)[1], 'body': '\n'.join(lines).strip(), 'tasks': tasks},
                      'raw': {'page': page, 'blocks': blocks}, 'closed': closed,
                      'due_property': due_info}
        elif kind == 'notes':
            self.guard('notes', {'action': 'update', 'note_id': identifier}, strict=True)
            raw = self.notes.current(identifier)
            if not raw:
                raise source_lookup.SourceReadError('transient', 'note_read_unclassified')
            try:
                _, summary, _ = self.notes.tools()._linked_note_sections(raw['body_html'])
                lines = _summary_lines(summary)
                parsed = content.from_text(raw['title'], '\n'.join(lines))
            except (KeyError, ValueError):
                text = str(raw.get('plaintext') or '')
                text = text.partition('\n')[2] if text.splitlines()[:1] == [raw.get('title')] else text
                # 진행도 (work_completion) is a status mark, not content: its own line or the end of 생성:.
                text = re.sub(r'\s*· 진행도: (진행중|완료)', '', text)
                text = '\n'.join(_note_summary_line(l) if re.match(r'\s*- 할 일:', l) else l
                                 for l in text.splitlines() if not re.fullmatch(r'진행도: (진행중|완료)', l.strip()))
                parsed = content.from_text(raw['title'], text)
            if raw.get('backend')=='obsidian':
                try:self.notes.tools()._linked_note_sections(raw['body_html'])
                except ValueError:
                    import obsidian_notes
                    parsed=obsidian_notes.markdown_tasks(raw)[0]
                    raw['_markdown_tasks']=True
            result = {'content': parsed, 'raw': raw, 'closed': False}
        elif kind == 'calendar':
            if identifier.startswith('google:'):
                raise source_lookup.SourceReadError('out_of_scope', 'google_calendar_source')
            if hasattr(self.calendar, 'lookup'):
                raw = source_lookup.require(self.calendar.lookup(identifier))
            else:
                raw = self.calendar.get(identifier)
                if not raw:
                    raise source_lookup.SourceReadError('transient', 'calendar_read_unclassified')
                if raw.get('recurring'):
                    raise source_lookup.SourceReadError('unsupported', 'recurring_calendar')
            self.guard('calendar', {'action': 'update', 'event_id': identifier, 'expected_start': raw['start']}, strict=True)
            from work_completion import strip_mark, split_progress
            parsed = content.from_text(strip_mark(raw['title']), split_progress(raw.get('notes') or '')[1])
            due = content.next_due(parsed)
            if due and dates.canonical(raw['start'], all_day=raw.get('isAllDay', raw.get('allDay')) is True) != due:
                # A calendar move changes only tasks that shared the earliest deadline.
                start = dates.canonical(raw['start'], all_day=raw.get('isAllDay', raw.get('allDay')) is True)
                for row in parsed['tasks']:
                    if row.get('due') == due:
                        row['due'] = start
            result = {'content': parsed, 'raw': raw, 'closed': False}
        else:
            raise source_lookup.SourceReadError('unsupported', 'unsupported_work_source')
        result['revision'] = content.digest(stable_notion(result['raw']) if kind == 'notion' else result['raw'])
        return result

    def structured(self, row):
        try:
            return content.structured_summary(self.notes.tools()._linked_note_sections(row['raw']['body_html'])[1])
        except (KeyError, ValueError, TypeError):
            return False

    def structured_target(self, row, wanted):
        """A structured memo's own content once it carries the wanted task list, or None."""
        try:
            _, summary, _ = self.notes.tools()._linked_note_sections(row['raw']['body_html'])
            edited = structured_edit(summary, row['content']['tasks'], wanted['tasks'])
            planned = edited is not None and structured_content(row['content']['title'], edited)
        except (KeyError, ValueError, TypeError):
            return None
        return {**planned, 'title': wanted.get('title') or planned['title']} if planned else None

    def preflight(self, kind, identifier, before, desired):
        current = self.read(kind, identifier)
        if current['closed'] or current['revision'] != before['revision']:
            raise ValueError('work_original_changed_before_write')
        if kind == 'notes' and before['raw'].get('_markdown_tasks'):
            import obsidian_notes
            obsidian_notes.apply_markdown_tasks(identifier,before,desired)
        elif kind == 'notes':
            # Existing structured summary/source and original attachment export are prerequisites.
            _, summary, _ = self.notes.tools()._linked_note_sections(before['raw']['body_html'])
            if content.structured_summary(summary):
                edited = structured_edit(summary, before['content']['tasks'], desired['tasks'])
                try:
                    planned = edited is not None and structured_content(desired['title'], edited)
                except ValueError:
                    planned = None
                wanted = content.semantic(desired)
                if not planned or (planned['body'], planned['tasks']) != (wanted['body'], wanted['tasks']):
                    raise ValueError('note_structure_preserved')
        if any(row.get('ambiguous') for row in desired['tasks']):
            raise ValueError('ambiguous_task_deadline')

    def apply(self, kind, identifier, before, desired):
        self.preflight(kind, identifier, before, desired)
        if kind == 'notion':
            self._notion(identifier, before, desired)
        elif kind == 'calendar':
            self._calendar(identifier, before, desired)
        else:
            self._notes(identifier, before, desired)
        after = self.read(kind, identifier)
        read = content.semantic(after['content'])
        if read != content.semantic(desired) and not (
                kind == 'notion' and after.get('due_property')
                and {**read, 'tasks': after['due_property']['explicit']} == content.semantic(desired)):
            raise RuntimeError('work_content_write_unverified')
        return after

    def write_due(self, identifier, wanted):
        """Set only the page's '다음 마감' and read it back; the caller re-read the page just before."""
        import work_policy
        if work_policy.notion_problem({'page_id':identifier}):raise ValueError(work_policy.ERROR)
        self.reader.request('PATCH', f'pages/{identifier}', {'properties': {DUE: {'date': {'start': wanted} if wanted else None}}})
        after = self.read('notion', identifier)
        if after['closed'] or not after.get('due_property') or after['due_property']['page'] != wanted:
            raise RuntimeError('notion_due_write_unverified')
        return after

    def _notion(self, identifier, before, desired):
        from notion_completion_sync import page_title
        name, old_title = page_title(before['raw']['page'])
        tasks_changed = content.semantic(before['content'])['tasks'] != desired['tasks']
        props = {}
        due = before.get('due_property')
        if tasks_changed and due:
            # Same rule as the independent '다음 마감' check: undated tasks never clear the page's own date.
            wanted = content.due_target(desired['tasks'], due['page'])
            if wanted != due['page']:
                props[DUE] = {'date': {'start': wanted} if wanted else None}
        if old_title != desired['title']:
            props[name] = {'title': rich(desired['title'])}
        if props:
            self.reader.request('PATCH', f'pages/{identifier}', {'properties': props})
        old_tasks = before['content']['tasks'] if tasks_changed else []
        desired_tasks = content.reconcile([dict(r, key=r['source_id']) for r in old_tasks], desired['tasks']) if tasks_changed else []
        wanted = {r['key'] for r in desired_tasks}
        for row in old_tasks:
            if row['source_id'] not in wanted:
                self.reader.request('DELETE', 'blocks/'+row['source_id'])
        append = []
        for row in desired_tasks:
            text = row['text'] + (' | '+row['due'] if row.get('due') else '')
            block = {'rich_text': rich(text), 'checked': row['done']}
            if any(r['source_id'] == row['key'] for r in old_tasks):
                self.reader.request('PATCH', 'blocks/'+row['key'], {'to_do': block})
            else:
                append.append({'object': 'block', 'type': 'to_do', 'to_do': block})
        if before['content']['body'] != desired['body']:
            old = [b for b in before['raw']['blocks'] if b.get('type') in TEXT_BLOCKS and not b.get('archived')
                   and (b['type'] != 'table_row' or body_text(b).strip())]
            lines = desired['body'].splitlines()
            for i, block in enumerate(old):
                if block['type'] == 'table_row':
                    width = len(block['table_row']['cells'])
                    cells = lines[i].split('\t') if i < len(lines) else []
                    if len(cells) > width:
                        cells = [lines[i]]
                    cells += [''] * (width-len(cells))
                    self.reader.request('PATCH', 'blocks/'+block['id'], {'table_row': {'cells': [rich(cell) for cell in cells]}})
                elif i < len(lines):
                    data = {'rich_text': rich(lines[i])}
                    if block['type'] == 'code':
                        data['language'] = block['code'].get('language', 'plain text')
                    self.reader.request('PATCH', 'blocks/'+block['id'], {block['type']: data})
                else:
                    self.reader.request('DELETE', 'blocks/'+block['id'])
            append += [{'object': 'block', 'type': 'paragraph', 'paragraph': {'rich_text': rich(line)}} for line in lines[len(old):]]
        for offset in range(0, len(append), 100):
            self.reader.request('PATCH', f'blocks/{identifier}/children', {'children': append[offset:offset+100]})

    def _calendar(self, identifier, before, desired):
        tools, event = self.calendar.tools(), before['raw']
        from work_completion import DONE_MARK, split_progress, with_progress
        mark = DONE_MARK if str(event['title']).startswith(DONE_MARK) else ''
        progress = split_progress(event.get('notes') or '')[0]
        args = {'action': 'update', 'event_id': identifier, 'expected_title': event['title'],
                'expected_start': event['start'], 'title': mark + desired['title'],
                'notes': with_progress(content.render(desired), progress), 'span': 'this'}
        if all(before['content'][field] == desired[field] for field in ('body', 'tasks')):
            args['notes'] = event.get('notes') or ''
        due = content.next_due(desired)
        if due:
            start = due if len(due) > 10 else due+'T00:00:00+09:00'
            delta = datetime.fromisoformat(event['end']) - datetime.fromisoformat(event['start'])
            args.update(start=start, end=(datetime.fromisoformat(start)+delta).isoformat(), all_day=len(due)==10)
        binary = tools._calendar_cache_root(tools.PERSONAL_PROFILE)/'eventkit_calendar_mutation-v1'
        result = subprocess.run([str(binary), json.dumps(args, ensure_ascii=False)], capture_output=True, text=True, timeout=30)
        # The EventKit helper reports {action, before, after}; it has no "ok" field. apply() re-reads to verify.
        try:
            after = json.loads(result.stdout).get('after') if not result.returncode else None
        except ValueError:
            after = None
        if not isinstance(after, dict):
            raise RuntimeError('calendar_work_write_uncertain')

    def _notes(self, identifier, before, desired):
        tools = self.notes.tools()
        if before['raw'].get('_markdown_tasks'):
            import obsidian_notes
            obsidian_notes.apply_markdown_tasks(identifier,before,desired,write=True)
            return
        preview, original_summary, original = tools._linked_note_sections(before['raw']['body_html'])
        summary = [f'- 본문: 줄 {i+1} | {line}' for i, line in enumerate(desired['body'].splitlines())]
        summary += ['- 할 일: '+('[x] ' if r['done'] else '[ ] ')+r['text']+' | '+(r.get('due') or '') for r in desired['tasks']]
        if not summary:
            summary = ['- 본문: 내용 | ']
        if all(before['content'][field] == desired[field] for field in ('body', 'tasks')):
            summary = original_summary.splitlines()
        elif content.structured_summary(original_summary):
            # Only task rows change in a structured memo; preflight checked the edit reads back as desired.
            summary = structured_edit(original_summary, before['content']['tasks'], desired['tasks']).splitlines()
        result = json.loads(tools._apple_notes_direct_mutation({
            'action': 'update', 'note_id': identifier, 'title': desired['title'], 'rename_title': True,
            'preview_summary': preview, 'summary': '\n'.join(summary), 'approved': True,
            '_skip_common_work': True, 'mixed_mode': 'rebuild'},
            _linked_title_authority=tools._LINKED_TITLE_AUTHORITY, _linked_title_before=before['raw']))
        if not result.get('ok') or result.get('result', {}).get('content_loss'):
            raise RuntimeError('note_work_write_uncertain')
        actual_id = result.get('target_id') or result.get('result', {}).get('note_id') or identifier
        if actual_id != identifier:
            self.aliases[identifier] = actual_id
        after = self.notes.current(actual_id)
        if not after or _attachment_keys(after) != _attachment_keys(before['raw']):
            raise RuntimeError('note_attachment_preservation_unverified')
        if tools._linked_note_sections(after['body_html'])[2] != original:
            raise RuntimeError('note_original_preservation_unverified')
