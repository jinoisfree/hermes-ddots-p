"""Precision-aware updates for linked deadlines; never treat an event date as a task deadline."""
from datetime import datetime
from hermes_packs.linked_work import deadline_time as dt


def synchronize(sync, item, cur, prev):
    """Handle timed deadline changes. Return True to suppress legacy date sync."""
    def values(snap):
        result = {}
        if snap.get('notion'):
            n = snap['notion']
            result[('notion', n['pid'])] = n.get('exact_due')
        for kind in ('notes', 'calendar'):
            for sid, row in (snap.get(kind) or {}).items():
                if row and not row.get('done') and not row.get('recurring'):
                    result[(kind, sid)] = row.get('exact_due')
        return result
    before, current = values(prev), values(cur)
    changes = [(key, before[key], new) for key, new in current.items()
               if before.get(key) and new and before[key] != new]
    precise = any((old[10:] != new[10:]) or (len(old) > 10 and any(k != key and v == old for k, v in current.items()))
                  for key, old, new in changes)
    if not precise:
        return False
    # Conflicts must never be resolved by applying whichever change was discovered first.
    if len({(old, new) for _, old, new in changes}) > 1:
        sync.report('deadline-conflict:' + item['common_id'] + ':' + repr(changes),
                    '• ⚠️ 연결된 마감이 서로 다르게 바뀌어 날짜·시간은 그대로 두었어요. 기준 마감을 확인해 주세요.')
        return True
    origins = {key for key, _, _ in changes}
    _, old, new = changes[0]
    allowed = {key for key, value in current.items() if value == old and key not in origins}
    moved = []
    for kind, sid in sorted(allowed):
        if kind == 'notion':
            if cur['notion'].get('due_range'): continue
            sync.reader.set_due(sid, new)
            cur['notion'].update(exact_due=new, due=new[:10])
            moved.append('노션 다음 마감')
        elif kind == 'calendar':
            # Date-only <-> timed is not an instruction to convert an all-day event.
            if len(old) == 10 or len(new) == 10: continue
            event = cur['calendar'][sid]['event']
            delta = datetime.fromisoformat(new) - datetime.fromisoformat(old)
            end = datetime.fromisoformat(event['end'].replace('Z', '+00:00')) + delta
            sync.calendar.move(event, new, end.isoformat())
            cur['calendar'][sid].update(exact_due=new, day=new[:10])
            moved.append('연결된 일정')
        elif kind == 'notes':
            sync.append_note(item['common_id'], 'deadline', f'{sid}:{old}:{new}', sid,
                             '마감 변경', line=f'📅 마감 변경: {dt.label(old)} → {dt.label(new)}',
                             edits=[{'kind': 'due', 'old': old, 'new': new}])
            cur['notes'][sid].update(exact_due=new, due=new)
            moved.append('메모 다음 마감')
    if moved:
        sync.say(f'• 마감 {dt.label(old)} → {dt.label(new)}: ' + ', '.join(moved))
    return True
