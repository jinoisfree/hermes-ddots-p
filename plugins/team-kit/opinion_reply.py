"""의견 (owner decision 2026-10-31): the owner pressed or wrote 의견 on a question in a thread.

The staff member asks what to change or do, and waits; nothing runs and nothing counts as approval.
Learning reports answer 의견 themselves (report_review, registered earlier), SNS담당's customer drafts in the
private-service-24 plugin, so this only words the turn for every other thread.
"""
from pathlib import Path

NOTE = ("의견\n\n[자동 안내: 소유자가 이 스레드의 질문에 '의견'을 골랐다. 승인이나 실행으로 보지 말고 도구로 아무것도 "
        "바꾸지 마라. 이 스레드의 직전 질문을 기준으로 무엇을 어떻게 바꾸거나 할지 한두 문장으로 묻고 소유자의 답을 "
        "기다려라. 이미 같은 것을 물어 답을 기다리는 중이면 다시 묻지 말고 기다린다고만 짧게 말해라. 버튼은 붙이지 않는다.]")
SKIP_PROFILES = {'sns-manager'}


async def dispatch(home, event=None, **_):
    source = getattr(event, 'source', None)
    if Path(home).name in SKIP_PROFILES or str(getattr(getattr(source, 'platform', None), 'value', '')) != 'slack':
        return None
    if str(getattr(event, 'text', '') or '').strip() != '의견' or not getattr(source, 'thread_id', None):
        return None
    return {'action': 'rewrite', 'text': NOTE}
