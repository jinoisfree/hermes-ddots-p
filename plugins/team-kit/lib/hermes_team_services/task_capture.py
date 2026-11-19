"""The owner's explicit task registration selection; no service calls or approval bypass."""

# Owner-specific text is rendered from private policy; public source stays generic.
from pathlib import Path as _OwnerPath
import sys as _owner_sys
_owner_library = str((_OwnerPath(__file__).resolve().parent / '..').resolve())
if _owner_library not in _owner_sys.path:
    _owner_sys.path.insert(0, _owner_library)
from hermes_facility.owner_text import render as _owner_text
from hermes_team_services.learning import quoted_row_sql

from pathlib import Path
import re
import sqlite3
import importlib.util as _ilu, pathlib as _pl, sys as _sys
team = _sys.modules.get('hermes_team_registry')
if team is None:
    _spec = _ilu.spec_from_file_location('hermes_team_registry', _pl.Path(__file__).with_name('team_registry.py'))
    team = _sys.modules['hermes_team_registry'] = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(team)

DESTINATIONS = ('노션', '일정', '메모')
DIRECT = {'notion', 'knowledge_ref_link', 'knowledge_ref_get', 'apple_notes_direct_lookup'}
NOTE = _owner_text("""[<<work_name>> 업무 등급 선택]
회사 업무의 공개 등급 scope=private/shared는 <<personal_name>>의 개인 계정 범위(personal_scopes)와 별개다.
메모 [ ]·노션 to_do는 원문에 우리측에 명시적으로 요청된 행동 또는 소유자가 지정한 항목만 만든다. 안내·상대측 할 일·추론한 준비는 체크 없는 정보로 두고 애매하면 할 일 후보(미생성)로 보고한다.
메일과 일반 요청의 새 업무 제안·등급 전환 질문은 한 메시지에 업무 제목·할 일·마감·출처와 다음 안내를 쓰고 버튼 하나만 단다.
메모 = 개인(Obsidian 메모), 메모+노션 = 공용(노션+Obsidian 메모), 확인 = 만들지 않음
[[버튼: 메모 | 메모+노션 | 확인]]
한 번 선택하면 생성·전환을 실행한다. 맨 메모는 답한 글에 고정 안내 문장이 있을 때만 개인이다. 예전 lv1/lv2·개인/비공개·공용/공유·선택: …·일정 선택·건너뛰기·이모지 클릭 값은 하위 호환으로 처리한다. 고유 선택어 메모+노션·노션+메모(공백 변형 포함)는 물음표·부정·개인 계열·맨 메모 단독 선택이 없는 문장에서도 공용이다. 여러 줄이면 그 고유 선택어가 있는 줄이 한 줄이고 다른 줄에 다른 선택어가 없을 때만 그 줄을 쓴다. 공용·공유·개인·비공개·맨 메모는 계속 전체 일치 문법만 인정한다. 확인·건너뛰기는 만들거나 전환하지 않는다. 메일이면 해당 메일 ID ack와 report_status(done)를 실제 확인하고 종결한다.
선택 후 personal_work_bundle(capture={title,body,tasks:[{text,due?,done?,due_evidence?:날짜 원문 발췌,evidence:원문 발췌}],source:{text,account,message_id,thread_id?,rfc_id?,subject,url?,attachment_names?},attachments?:다운로드 경로,calendar?:{start,end,evidence,start_evidence?,end_evidence?,location?}}) 한 번으로 생성·공통 ID 연결을 마친다. 별도 노션 생성이나 operations를 섞지 않는다. 원문·기존 업무를 먼저 읽는다.
개인은 Obsidian <<company_notebook>>, 공용은 회사 업무 DB 노션과 Obsidian이다. private 업무의 노션 생성·연결·조회·수정·첨부는 도구 계층에서 거부된다.
메일과 일반 요청 모두 생성 뒤 원문에 명시된 날짜(가능하면 시각)의 일정 후보가 있을 때만 완료 답글 끝에 일정도 만들까요?와 [[버튼: 승인 | 거절]]을 붙인다. 승인 시 기존 일정 생성 도구로 company.default_calendar_id에 생성하고 기존 common_id에 연결하며 capture를 다시 호출하지 않는다. 거절하면 일정 없이 종결하고 후보가 없으면 묻지 않는다. 처음부터 일정을 함께 지시했으면 생성 때 함께 만든다. 일정 답을 기다리는 동안 report_status(done)로 종결하지 않는다. 시작·끝은 명확한 원문 근거만 쓰고 불명확하면 만들지 않는다. 회사 캘린더는 소유자 본인만 보므로 개인+일정에도 기존 제목·할 일·마감·완료 동기화를 적용한다.
여러 항목 답은 capture·scope_change에 choice_ref로 소유자 글의 번호·정확한 이름을 지정해 한 줄만 선택한다. 키가 없거나 중복이면 다시 묻고 선택 거부를 다른 도구의 메모·노션 생성으로 우회하지 않는다. 노션+메모·메모 + 노션은 공용이며 화살표(->·→·-&gt;·=>) 뒤 설명은 선택과 분리한다.
등급 전환은 업무 제목을 넣은 위 질문에 대한 현재 소유자 선택 한 번으로 personal_work_bundle(scope_change={common_id,scope})를 실행한다. 개인→공용은 제목·할 일·마감만 공개하고 본문·첨부는 제외한다. 공용→개인은 공개 철회 불가를 안내하고 노션 연결만 끊으며 페이지는 삭제하지 않는다. 미리보기·토큰·추가 승인 질문은 없다. partial은 새 같은 목표 선택으로 로컬 미완료 단계를 이어서 하고 uncertain은 운영자 원본 대조 전 재실행하지 않는다. 예약·배경 쓰기 거부·기존 수정/삭제/발송 승인 경계는 유지한다.
""")


MAIL_MARKER = '[[버튼: 메모 | 메모+노션 | 확인]]'
# Reports posted before 2026-10-31 carried Slack emoji codes; their clicks still answer, no new buttons use them.
LEGACY_MAIL_MARKER = '[[버튼: :hp-memo: 메모 | :hp-notion: 메모+노션 | :hp-check: 확인]]'

MAIL_LEGEND = '메모 = 개인(Obsidian 메모), 메모+노션 = 공용(노션+Obsidian 메모), 확인 = 만들지 않음'
MAIL_CHOICES = {':hp-memo: 메모':'lv1', ':hp-notion: 메모+노션':'lv2', ':hp-check: 확인':'확인', '메모+노션':'lv2'}

def mail_thread(home, session_id):
    """Only the latest inbound's bounded transport thread context supplies bare-word meaning; a steer or
    redirect that interrupted its turn is not an inbound."""
    if not team.home_has_role(home, 'work') or not session_id:
        return False
    try:
        quoted, quoted_args = quoted_row_sql()
        with sqlite3.connect((Path(home)/'state.db').as_uri()+'?mode=ro', uri=True) as db:
            row = db.execute("SELECT m.content FROM messages m WHERE m.session_id=? AND m.role='user' AND m.content IS NOT NULL "
                             f"AND NOT {quoted} ORDER BY m.id DESC LIMIT 1", (session_id, *quoted_args)).fetchone()
        text = str(row[0] or '') if row else ''
        if not text.startswith('[Thread context') or '[End of thread context]' not in text:
            return False
        context = text.split('[End of thread context]',1)[0]
        return MAIL_LEGEND in context
    except (sqlite3.Error, OSError, ValueError):
        return False

def scope_choice(text, *, legend, choice_ref=None):
    """Owner choices: exact legacy grammar or an unambiguous combined-destination sentence."""
    value = str(text or '').strip()
    combined = r'(?:메모\s*\+\s*노션|노션\s*\+\s*메모)'
    if choice_ref is not None:
        key = str(choice_ref).strip()
        if not key or '\n' in key:
            return None
        rows = [found[1] for line in value.splitlines()
                if (found := re.match(r'^\s*'+re.escape(key)+r'(?=$|\s|[.)。:：])\s*[.)。:：]?\s*(.*?)\s*$',line))]
        if len(rows) != 1:
            return None
        value = rows[0]
    elif '\n' in value:
        lines = [line.strip() for line in value.splitlines() if line.strip()]
        choices = [line for line in lines if re.search(combined,line)]
        if len(choices) != 1:
            return None
        others = [line for line in lines if line != choices[0]]
        for line in others:
            if re.search(combined,line) or re.search(r'(?<![\w])(?:공용|공유|개인|비공개|lv1|lv2)(?![\w])',line,re.I):
                return None
            try:
                other_choice = scope_choice(line,legend=True)
            except ValueError:
                return None
            if other_choice is not None:
                return None
        value = choices[0]
    sentence = value
    value = re.split(r'->|→|-&gt;|=>',value,maxsplit=1)[0].strip()
    value = MAIL_CHOICES.get(value,value)
    # Earlier reports used this explicit private-work label without a legend.
    if value == '메모 작성':
        return ('private', False)
    private = re.search(r'\blv1\b|비공개|개인|\bprivate\b', value, re.I)
    shared = re.search(r'\blv2\b|공용|공유|(?:메모\s*\+\s*노션|노션\s*\+\s*메모)|\bshared\b', value, re.I)
    match = re.fullmatch(
        r'(?:선택:\s*)?(메모\s*\+\s*노션|노션\s*\+\s*메모|lv2|공용|공유|shared|lv1|개인|비공개|private|메모|확인|건너뛰기|일정만|일정)'
        r'([,\s]+일정)?(?:\s*(?:으로|로))?(?:\s*(?:전환|생성|작성|진행))?'
        r'(?:\s*(?:해|해줘|해 줘|해주세요|해 주세요))?[.!]?', value, re.I)
    if not match:
        if re.search(combined,sentence):
            remaining = re.sub(combined,'',sentence)
            if (re.search(r'[?？]|말고|빼고|아니|않|없이|하지\s*마|안\s',sentence)
                    or re.search(r'개인|비공개|lv1|private|메모(?=$|[^\w]|만|로|에|는|를|도)',remaining,re.I)):
                return None
            return ('shared', False)
        if private and shared:
            if choice_ref is not None:
                return None
            raise ValueError('WORK_SCOPE_CHOICE_AMBIGUOUS')
        return None
    word = re.sub(r'\s+','',match[1].lower())
    if word in {'확인','건너뛰기'}:
        return (None, False)
    if word in {'일정','일정만'}:
        return (None, True)
    if word == '메모' and not legend:
        return None
    return ('shared' if word in {'메모+노션','노션+메모','lv2','공용','공유','shared'} else 'private', bool(match[2]))


def mail_choice(text, *, mail=False):
    # Compatibility presentation for existing callers; all scope interpretation lives above.
    picked = scope_choice(text, legend=mail)
    if picked and picked[0]:
        return 'lv1' if picked[0] == 'private' else 'lv2'
    return MAIL_CHOICES.get(str(text or '').strip(), str(text or '').strip())


def selection(text, *, mail=False):
    picked = scope_choice(text, legend=mail)
    if picked and picked[0]:
        return ['lv1' if picked[0]=='private' else 'lv2'] + (['일정'] if picked[1] else [])
    # The older destination checklist remains a separate contract.
    value = str(text or '').strip().removeprefix('선택:').strip()
    pieces = [v for v in re.split(r'[,\s]+', value) if v]
    if not pieces or any(v not in {'전체', *DESTINATIONS} for v in pieces):
        return None
    return list(DESTINATIONS) if '전체' in pieces else [v for v in DESTINATIONS if v in pieces]


def active(home, text, session_id=''):
    if not team.home_has_role(home, 'work'):
        return False
    if re.search(r'(?:할\s*일|업무).*(?:등록|추가|만들|저장)|(?:등록|추가|저장).*(?:할\s*일|업무)', str(text or '')):
        return True
    if str(text or '').strip() in MAIL_CHOICES or (mail_thread(home, session_id) and str(text or '').strip() in {'메모','확인'}):
        return True
    if selection(text, mail=mail_thread(home, session_id)) is None or not session_id:
        return False
    # A bare "전체" may answer any question. Only our current thread's capture draft unlocks this path.
    db = Path(home) / 'state.db'
    try:
        with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as conn:
            row = conn.execute("SELECT content FROM messages WHERE session_id=? AND role='assistant' AND content IS NOT NULL ORDER BY id DESC LIMIT 1", (session_id,)).fetchone()
        return bool(row and any(marker in row[0] for marker in ('[[체크: 전체 | 노션 | 일정 | 메모]]','[[체크: 일정 | 제출:', '[[버튼: 메모 작성 | 메모+노션 | 확인]]', MAIL_MARKER, LEGACY_MAIL_MARKER)))
    except sqlite3.Error:
        return False


def allowed(tool, args):
    if tool == 'notion':
        return args.get('action') in {'search', 'databases', 'schema', 'query', 'page', 'users', 'api_help', 'create'}
    if tool == 'knowledge_ref_link':
        return args.get('ref_type') == 'notion_page'
    return True
