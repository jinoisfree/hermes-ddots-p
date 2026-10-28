"""The owner's explicit task registration selection; no service calls or approval bypass."""
from pathlib import Path
import re
import sqlite3

DESTINATIONS = ('노션', '일정', '메모')
DIRECT = {'task_reminders_sync', 'notion', 'knowledge_ref_link', 'knowledge_ref_get', 'apple_notes_direct_lookup', 'reminders_direct_lookup'}
NOTE = """[업무비서 업무 등급제 — 소유자 결정 2026-10-28]
회사 업무의 공개 등급 scope=private/shared는 개인비서의 개인 계정 범위(personal_scopes)와 별개다.
메모 [ ]·노션 to_do·미리알림은 원문에 우리측에 명시적으로 요청된 행동 또는 소유자가 지정한 항목만 만든다. 안내·상대측 할 일·추론한 준비는 체크 없는 정보로 두고 애매하면 할 일 후보(미생성)로 보고한다.
새 업무 제안은 한 메시지에 제목·할 일·마감·출처와 'lv1 = 개인(Obsidian→미리알림), lv2 = 공용(노션+Obsidian→미리알림), 일정은 체크하면 함께 생성'을 쓰고 마지막 줄 [[체크: 일정 | 제출: lv1 | lv2 | 확인]]을 단다. 이미 lv1/개인/비공개 또는 lv2/공용/공유를 말했으면 다시 묻지 않는다. 일정은 함께 지시한 경우만 만든다. 체크 없는 확인=건너뛰기, 일정 체크+확인=일정만이며 노션·메모·미리알림은 없다. 건너뛰기는 아무것도 만들지 않고 해당 메일 ID만 ack한 뒤 report_status(done)로 종결한다.
선택 후 personal_work_bundle(capture={title,body,tasks:[{text,due?,done?,due_evidence?:날짜 원문 발췌,evidence:원문 발췌}],source:{text,account,message_id,thread_id?,rfc_id?,subject,url?,attachment_names?},attachments?:다운로드 경로,calendar?:{start,end,evidence,start_evidence?,end_evidence?,location?}}) 한 번으로 생성·공통 ID 연결·미리알림을 마친다. 이 capture에는 operations나 별도 노션/미리알림 생성을 섞지 않는다. 원문·기존 업무를 먼저 읽고 task evidence에는 실제 발췌를 넣는다. partial/uncertain이면 성공한 ID와 journal_key를 보존하고 불명확 쓰기를 재실행하지 않는다.
lv1은 Obsidian pie1과 Hermes 미리알림, lv2는 전략기획실 업무 DB 노션과 Obsidian 및 노션 기준 미리알림이다. private 업무의 노션 생성·연결·조회·수정·첨부는 도구 계층에서 거부된다. 개인 업무는 미리알림의 제목·마감·완료를 Obsidian 할 일에 역반영하며 같은 구간 충돌은 Obsidian 우선, 삭제는 전파하지 않는다. 공용 미리알림 제목·마감 수정은 관리 제외하고 완료만 역반영한다.
선택: lv1, 일정 / 선택: lv2 / 선택: 일정 / 건너뛰기를 그대로 해석한다. 회사 캘린더는 소유자 본인만 보므로 개인+일정에도 기존 제목·할 일·마감·완료 동기화 규칙을 적용한다. 메일에서 명확히 확인한 시작·끝만 calendar에 넣고 불명확하면 일정은 만들지 않고 이유를 보고한다. 연도 없는 날짜는 KST 올해, 날짜만 있으면 시각을 만들지 않으며 D-7/3/1 준비 알림은 없다. 이번 일정만 업무는 미리알림 제외 표식을 가지며 기존 일정 전용 업무의 동작은 유지한다.
등급 전환은 personal_work_bundle(scope_change={common_id,scope})로 미리보기와 버튼을 받은 뒤 같은 소유자·스레드에서 그 버튼을 누르면 token을 함께 넘긴다. 개인→공용은 제목·할 일·마감만 공개(본문·첨부 제외), 공용→개인은 공개 철회 불가 경고 뒤 연결만 끊고 페이지는 삭제하지 않는다. 예약·배경 쓰기 거부·기존 수정/삭제/발송 승인 경계는 유지한다.
"""


def selection(text):
    value = str(text or '').strip().removeprefix('선택:').strip()
    value=re.sub(r'비공개|개인으로|개인|private','lv1',value,flags=re.I)
    value=re.sub(r'공용으로|공용|공유|shared','lv2',value,flags=re.I)
    pieces = [v for v in re.split(r'[,\s]+', value) if v]
    if pieces and all(v in {'lv1','lv2','일정'} for v in pieces):return pieces
    if not pieces or any(v not in {'전체', *DESTINATIONS} for v in pieces):
        return None
    return list(DESTINATIONS) if '전체' in pieces else [v for v in DESTINATIONS if v in pieces]


def active(home, text, session_id=''):
    if Path(home).name != 'work-assistant':
        return False
    if re.search(r'(?:할\s*일|업무).*(?:등록|추가|만들|저장)|(?:등록|추가|저장).*(?:할\s*일|업무)', str(text or '')):
        return True
    if selection(text) is None or not session_id:
        return False
    # A bare "전체" may answer any question. Only our current thread's capture draft unlocks this path.
    db = Path(home) / 'state.db'
    try:
        with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as conn:
            row = conn.execute("SELECT content FROM messages WHERE session_id=? AND role='assistant' AND content IS NOT NULL ORDER BY id DESC LIMIT 1", (session_id,)).fetchone()
        return bool(row and any(marker in row[0] for marker in ('[[체크: 전체 | 노션 | 일정 | 메모]]','[[체크: 일정 | 제출:')))
    except sqlite3.Error:
        return False


def allowed(tool, args):
    if tool == 'notion':
        return args.get('action') in {'search', 'databases', 'schema', 'query', 'page', 'users', 'api_help', 'create'}
    if tool == 'knowledge_ref_link':
        return args.get('ref_type') == 'notion_page'
    return True
