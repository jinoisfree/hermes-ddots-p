"""One owner request's app changes are one receipt: find the group, fold same-target chains, word the posts.

The ledger stays the only record. Every entry of a request carries the same optional field
`receipt_group = {id, keys, oldest_at}`; `keys` lets a click tell that part of the group was cleaned
out of the ledger, and `oldest_at` keeps the group's age after its oldest entry is gone. An entry
without the field (a receipt posted before groups existed) is a group of one.

Packs declare, next to their restore function, how to name a change's target (`target`) and how to
word it (`line`). The facility only compares targets and never reads another pack's fields.
"""
from copy import deepcopy
import logging
import re
import uuid

logger = logging.getLogger(__name__)

FIELDS = ('platform', 'user_id', 'chat_id', 'thread_id')
GROUP = re.compile(r'(?:^|\n)묶음 번호: ([0-9a-f]{32})(?:\n|$)')
SINGLE = re.compile(r'(?:^|\n)변경 번호: ([0-9a-f]{32})(?:\n|$)')
# Display words for kinds whose pack declares no `line`.
KIND_LABELS = {'calendar': '일정', 'google_calendar': '일정', 'calendar_color': '일정 색', 'memo': '메모', 'memo_backup': '메모',
               'notion': '노션', 'mail': '메일', 'contacts': '연락처', 'files': '파일', 'mac_app': '맥 앱', 'personal': '개인 업무'}


EXPIRED = 'UNDO_EXPIRED: 24시간이 지났거나 기록이 없어서 되돌릴 수 없어요.'


class Refused(ValueError):
    """The whole group is left as it is; the message tells the owner why."""


def make(entries):
    return {'id': uuid.uuid4().hex, 'keys': [e['key'] for e in entries], 'oldest_at': min(e['created_at'] for e in entries)}


def recorded(entry):
    return entry.get('app_conversation', entry.get('conversation')) or {}


def find(entries, ref):
    """(group, members) for a group id or for one entry's key; an entry from before groups is a group of one."""
    members = [e for e in entries if (e.get('receipt_group') or {}).get('id') == ref]
    if members:
        return members[0]['receipt_group'], members
    entry = next((e for e in entries if e.get('key') == ref), None)
    if entry is None:
        raise ValueError(EXPIRED)
    if entry.get('receipt_group'):
        return find(entries, entry['receipt_group']['id'])
    return {'id': None, 'keys': [entry['key']], 'oldest_at': entry['created_at']}, [entry]


def missing(group, members):
    """Keys the group lists that the ledger no longer holds (time or size cleanup)."""
    return [key for key in group['keys'] if key not in {e['key'] for e in members}]


def target(entry, declared):
    fn = (declared.get(entry.get('journal_kind')) or {}).get('target')
    return fn(entry) if fn else None


def chains(entries, declared):
    """Entries of one target in time order; an entry without a declared target stands alone."""
    by_target, found = {}, []
    for entry in sorted(entries, key=lambda e: e['created_at']):
        name = target(entry, declared)
        if name is None:
            found.append([entry])
            continue
        if name not in by_target:
            by_target[name] = []
            found.append(by_target[name])
        by_target[name].append(entry)
    return found


def line(chain, declared):
    """`일정 만들기 · 12/12(토) 09:00~18:00 제목 · 개인 캘린더 · 노랑`: later changes of the target are appended."""
    words = []
    for entry in chain:
        fn = (declared.get(entry.get('journal_kind')) or {}).get('line')
        try:
            action, subject = fn(entry) if fn else (KIND_LABELS.get(entry.get('journal_kind'), '앱') + ' 변경', '')
        except Exception:  # wording must never keep a receipt from reaching the owner
            logger.warning('receipt wording failed for %s', entry.get('journal_kind'), exc_info=True)
            action, subject = KIND_LABELS.get(entry.get('journal_kind'), '앱') + ' 변경', ''
        words.extend([action, subject] if not words else [subject or action])
    return ' · '.join(word for word in words if word)


def receipt(group_id, lines):
    return '앱 쓰기 결과\n되돌릴 수 있는 변경이 있어요.\n' + ''.join('• ' + text + '\n' for text in lines) + '묶음 번호: ' + group_id + '\n[[버튼: 확인 | 되돌리기]]'


def without_single_receipts(text, keys):
    """Drop single-change receipt sentences the model copied from a tool result; the group post replaces them."""
    for key in keys:
        text = re.sub(r'(?:(?<=\n)|^)(?:\*?[^\n\w]*앱 쓰기 결과\*?\n(?:[^\n]+\n){0,3}?)?변경 번호: ' + key + r'(?:\n\[\[버튼: 확인 \| 되돌리기\]\])?\n?', '', text)
    parts = [part.strip('\n') for part in text.split('[[글 나누기]]')]
    return '\n\n[[글 나누기]]\n\n'.join(part for part in parts if part.strip())


def plan(live, declared):
    """Chains to restore, latest change first. Refuses the whole group when a chain cannot be folded safely.

    A chain of one entry restores as it always did. A longer chain must start with a creation and each
    later change must have started from exactly what the one before it left (whole object, etag
    included), so what is deleted is what this request wrote and nothing someone else changed since."""
    found = chains(live, declared)
    for chain in found:
        if len(chain) == 1:
            continue
        first = chain[0]
        if first.get('before') is not None:
            raise Refused('같은 대상을 여러 번 고친 변경은 한 번에 되돌릴 수 없어서 아무것도 되돌리지 않았어요.')
        previous = first
        for entry in chain[1:]:
            before, after = entry.get('before'), previous.get('after')
            if not isinstance(before, dict) or not isinstance(after, dict) or before != after:
                raise Refused('“' + line(chain, declared) + '”이(가) 만든 뒤 다른 곳에서 바뀌어서 아무것도 되돌리지 않았어요.')
            previous = entry
    return sorted(found, key=lambda chain: chain[-1]['created_at'], reverse=True)


def folded(chain):
    """What the restore function of a chain's creation is given: the creation as the chain left it."""
    if len(chain) == 1:
        return chain[0]
    subject = deepcopy(chain[0])
    subject['after'] = deepcopy(chain[-1]['after'])
    return subject
