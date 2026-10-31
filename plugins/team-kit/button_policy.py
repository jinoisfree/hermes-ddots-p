"""Which reply buttons may be made for the owner (owner decision 2026-10-31).

Staff never make up button words. A new set of reply buttons is one of two fixed kinds:
- general and learning: 승인 · 거절 · 의견 · 확인 (any of them, each once)
- mail work registration: 메모 · 메모+노션 · 확인, only in a message that carries the mail legend
A checklist is one of the fixed task-registration checklists below. Anything else is not turned into
buttons and is not swapped for another set: the marker line is replaced by its words as plain text,
so the owner still sees the choices and answers in the thread. Nothing here runs a button's action.

Clicks on buttons already posted before this rule keep working: they arrive as the owner's words and
are matched against the stored report by whoever handles them (``report_review.find`` etc.).
"""
import re

STANDARD = ('승인', '거절', '의견', '확인')
MAIL = ('메모', '메모+노션', '확인')
# Same sentence as task_capture.MAIL_LEGEND; a test keeps the two equal.
MAIL_LEGEND = '메모 = 개인(Obsidian 메모→미리알림), 메모+노션 = 공용(노션+Obsidian 메모→미리알림), 확인 = 만들지 않음'
# 업무비서 task registration checklists (owner decisions 2026-10-24, 2026-10-28).
CHECKLISTS = ('일정 | 제출: lv1 | lv2 | 확인', '전체 | 노션 | 일정 | 메모')

# Fixed sets a plugin script posts for a decision whose meaning or approval boundary has no clear match in the
# common words yet (owner decision pending, docs/학습과-알림.md 응답 버튼 허용 목록). Each set belongs to the one
# script that posts it and handles its answer; that script names itself on the Slack body
# (``'_script_buttons': '<owner>'``), so the same words from a staff member, a tool or another script never
# become buttons. Nothing new goes here without an owner decision.
SCRIPT_PENDING = {
    'paseo_autofix': (('확인=푸시 승인, 롤백=되돌림 커밋', [r'확인', r'롤백']),
                      ('하루 한도', [r'오늘 계속 고쳐', r'이것만 고쳐', r'내일로'])),
    'deadline_watch': (('마감 답', [r'완료했어', r'못했어', r'수정할게', r'확인했어']),),
    'starter_plugins': (('공개 여부', [r'공개', r'비공개', r'나중에']),),
    'conflict_decisions': (('기준 원본', [r'(?:노션|메모|일정) 기준(?: \| (?:노션|메모|일정) 기준)*', r'그대로 두기']),),
    'link_decisions': (('원본 후보', [r'\d+번 연결(?: \| \d+번 연결)*', r'연결 안 함']),
                       ('이름 확인', [r'연결', r'연결 안 함']),
                       ('묶음', [r'확실한 \d+건 모두 연결', r'하나씩 볼게'])),
}


def script_allowed(labels, owner):
    """The name of ``owner``'s pending set these labels form exactly, else None."""
    joined = ' | '.join(labels)
    for name, parts in SCRIPT_PENDING.get(owner or '', ()):
        if re.fullmatch(r' \| '.join(parts), joined):
            return name
    return None


_MARKER = re.compile(r'\[\[(버튼|체크):([^\]\n]*)\]\]')


def _labels(raw):
    return [label.strip() for label in str(raw).split('|')]


def buttons_allowed(labels, text=''):
    """The labels when they form an allowed set in this message, else None."""
    labels = [str(label) for label in labels]
    if not labels or any(not label or label != label.strip() for label in labels) or len(set(labels)) != len(labels):
        return None
    if all(label in STANDARD for label in labels):
        return labels
    if all(label in MAIL for label in labels) and any(label != '확인' for label in labels) and MAIL_LEGEND in str(text or ''):
        return labels
    return None


def checklist_allowed(raw):
    spaced = ' | '.join(_labels(raw))
    return spaced if spaced in CHECKLISTS else None


def _trailing(text):
    """The last marker when nothing but blank lines or the usage footer follows it."""
    found = None
    for match in _MARKER.finditer(text):
        found = match
    if not found:
        return None
    rest = text[found.end():]
    if rest.strip() and '\n' not in rest.lstrip(' \t'):  # more words on the marker's own line
        return None
    return found


def guard(text, *, script=None):
    """``text`` with a disallowed trailing button/checklist marker turned into plain words.

    ``script`` is the owner name a plugin script put on its own Slack body (``slack_blocks.apply``)."""
    if not isinstance(text, str) or '[[' not in text:
        return text
    match = _trailing(text)
    if not match:
        return text
    kind, raw = match.group(1), match.group(2)
    body = text[:match.start()]
    if kind == '체크':
        if checklist_allowed(raw):
            return text
    elif buttons_allowed(_labels(raw), body) or script_allowed(_labels(raw), script):
        return text
    words = ' · '.join(label for label in _labels(raw) if label) or '선택지 없음'
    note = f'_버튼으로 만들지 않은 선택지: {words} — 필요하면 이 스레드에 글로 답해 줘_'
    return text[:match.start()] + note + text[match.end():]


def blocked(text, *, script=None):
    """True when ``guard`` would change the text."""
    return guard(text, script=script) != text
