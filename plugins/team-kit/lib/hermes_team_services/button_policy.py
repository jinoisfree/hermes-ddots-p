"""Which reply buttons may be made for the owner (owner decision 2026-10-31).

Staff never make up button words. A new set of reply buttons is one of two fixed kinds:
- general and learning: 승인 · 거절 · 의견 · 확인 (any of them, each once)
- mail work registration: 메모 · 메모+노션 · 확인, only in a message that carries the mail legend
- 다크개인비서 video: 제작해 · 수정 · 취소 and 다운 · 수정 · 종결, only with their own legend line
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
MAIL_LEGEND = '메모 = 개인(Obsidian 메모), 메모+노션 = 공용(노션+Obsidian 메모), 확인 = 만들지 않음'
# 다크개인비서 video buttons, kept as they are (owner decision 2026-10-31); like the mail words they are buttons only
# in a message carrying their own legend line.
VIDEO_MAKE = ('제작해', '수정', '취소')
VIDEO_MAKE_LEGEND = '제작해 = 이 제작안대로 만들기, 수정 = 고칠 점 말하기, 취소 = 만들지 않기'
VIDEO_DONE = ('다운', '수정', '종결')
VIDEO_DONE_LEGEND = '다운 = 받은 파일 저장, 수정 = 고칠 점 말하기, 종결 = 이 작업 끝내기'
APP_WRITE = ('확인', '되돌리기')
APP_WRITE_LEGEND = '앱 쓰기 결과'
CONTEXTS = ((MAIL, MAIL_LEGEND), (VIDEO_MAKE, VIDEO_MAKE_LEGEND), (VIDEO_DONE, VIDEO_DONE_LEGEND), (APP_WRITE, APP_WRITE_LEGEND))
# 업무비서 task registration checklists (owner decisions 2026-10-24, 2026-10-28).
CHECKLISTS = ('일정 | 제출: lv1 | lv2 | 확인', '전체 | 노션 | 일정 | 메모')

# Fixed sets a plugin script posts for a decision whose meaning or approval boundary has no clear match in the
# common words yet (owner decision pending, docs/학습과-알림.md 응답 버튼 허용 목록). Each set belongs to the one
# script that posts it and handles its answer; that script names itself on the Slack body
# (``'_script_buttons': '<owner>'``), so the same words from a staff member, a tool or another script never
# become buttons. Nothing new goes here without an owner decision.
SCRIPT_PENDING = {
    # Owner decision 2026-11-11: 확인 = result acknowledgment, 되돌리기 = revert commit.
    'paseo_autofix': (('확인=결과 확인, 되돌리기=되돌림 커밋', [r'확인', r'되돌리기']),),
    # Owner decision 2026-10-31: '어떤 후보를 연결할까요?' with the candidates' numbers, then 거절 · 의견 · 확인.
    'link_decisions': (('후보 번호', [r'\d+(?: \| \d+)*', r'거절', r'의견', r'확인']),),
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
    for words, legend in CONTEXTS:
        if all(label in words for label in labels) and any(label not in STANDARD for label in labels) and legend in str(text or ''):
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
