"""의견 (owner decisions 2026-10-31): pressing 의견 means the owner is about to write the instruction.

Nobody answers the press itself: the staff member does not ask back, nothing runs and nothing counts as approval.
The owner's own message that follows in the thread is the instruction. Reports with their own handler
(learning reviews, 공개판, 업무비서 link/conflict questions, SNS담당's customer drafts) treat 의견 the same way;
this hook, registered last, covers every other thread.
"""


async def dispatch(home, event=None, **_):
    source = getattr(event, 'source', None)
    if str(getattr(getattr(source, 'platform', None), 'value', '')) != 'slack':
        return None
    if str(getattr(event, 'text', '') or '').strip() != '의견' or not getattr(source, 'thread_id', None):
        return None
    return {'action': 'skip', 'reason': '의견: the owner writes the instruction next'}
