"""Read task deadlines from the structured Notion format, never from arbitrary source prose.

Inline dates and labelled direct children belong to a task. A single date in a heading_3
inside '할 일·마감' belongs to its following tasks until the next heading. Ranges and
conflicting evidence are ambiguous; an explicit inline date can resolve a section range.
"""
import re

import deadline_time as dates
import work_content as content

SECTIONS = {'할일마감', '할일', '할일목록'}
LABEL = re.compile(r'^\s*(?:마감(?:일|\s*시각)?|제출\s*(?:기한|마감)|기한|다음\s*일정)\s*[:：|]\s*(.+)$')
WEEKDAY = re.compile(r'\(([월화수목금토일])(?:요일)?\)')
RANGE = re.compile(r'\d[^\n]*?(?:[~～–]|부터)\s*\d')
DATE_HINT = re.compile(r'\d{1,2}\s*(?:월|[./-])\s*\d|\d{1,2}\s*월\s*(?:초|중|말|상순|중순|하순)')


def date_evidence(text, *, now=None):
    text = WEEKDAY.sub(' ', text)
    if RANGE.search(text):
        return None, True
    try:
        value = dates.extract(text, now=now, required=False)
    except ValueError:
        return None, True
    return value, bool(not value and DATE_HINT.search(text))


def read(blocks, *, now=None):
    """Preserve task identity/checks; only enrich dates with local, explicitly related evidence."""
    ids = {b['id'] for b in blocks}
    children = {}
    for block in blocks:
        parent = block.get('parent', {}).get('block_id')
        children.setdefault(parent if parent in ids else None, []).append(block)
    tasks = []

    def visit(parent, section=False, heading=(None, False)):
        for block in children.get(parent, []):
            if block.get('archived') or block.get('in_trash'):
                continue
            kind = block.get('type')
            value = block.get(kind, {})
            text = content.rich_text(value)
            # Stored originals are evidence, not a second live checklist.
            if kind == 'toggle' and '원문' in text:
                continue
            if kind in {'heading_1', 'heading_2'}:
                section = content.normalized(text) in SECTIONS
                heading = (None, False)
            elif kind == 'heading_3':
                heading = date_evidence(text, now=now) if section else (None, False)
            if kind == 'to_do':
                row = content.task(WEEKDAY.sub(' ', text), done=value.get('checked'), identifier=block['id'], now=now)
                # Preserve displayed task wording; weekday normalization is only for date parsing.
                original = content.task(text, done=value.get('checked'), identifier=block['id'], now=now)
                row['text'] = original['text']
                inline = date_evidence(text.split(' | ', 1)[-1], now=now)
                local = [inline] if inline[0] or inline[1] else []
                for child in children.get(block['id'], []):
                    if child.get('archived') or child.get('in_trash'):
                        continue
                    if child.get('type') not in {'paragraph', 'bulleted_list_item'}:
                        continue
                    match = LABEL.match(content.rich_text(child[child['type']]))
                    if match:
                        local.append(date_evidence(match[1], now=now))
                evidence = local or ([heading] if section else [])
                values = {date for date, _ in evidence if date}
                ambiguous = any(bad for _, bad in evidence) or len(values) > 1
                if ambiguous:
                    row['due'] = None
                    if not row['done']:
                        row['ambiguous'] = True
                    else:
                        row.pop('ambiguous', None)
                elif values:
                    row['due'] = next(iter(values))
                    row.pop('ambiguous', None)
                tasks.append(row)
            visit(block['id'], section, heading)
    visit(None)
    return tasks
