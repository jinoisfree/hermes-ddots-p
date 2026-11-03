"""Owner-requested idea/private report to the one configured assistant DM, never arbitrary recipients."""

# Owner-specific text is rendered from private policy; public source stays generic.
from pathlib import Path as _OwnerPath
import sys as _owner_sys
_owner_library = str((_OwnerPath(__file__).resolve().parent / '..').resolve())
if _owner_library not in _owner_sys.path:
    _owner_sys.path.insert(0, _owner_library)
from hermes_facility.owner_text import render as _owner_text

import hashlib
import json
import re
import threading
from hermes_facility import team_registry as team, owner_vault as vault

SCHEMA = {'name':'personal_report','description':_owner_text('Only when the owner explicitly asks to send it to the <<personal_dm_label>>, deliver an AI-idea or private-life result there; otherwise answer in the current conversation (<<owner_label_lower>>-world: that thread). A successful DM response in that same DM needs no duplicate call. The message must start with a `# title` line (no status icon; the section headings set the bar colours).'),
 'parameters':{'type':'object','properties':{'message':{'type':'string'}},'required':['message'],'additionalProperties':False}}
# `# 제목` becomes the Slack header block; `*…*` would render as italics. Since 2026-10-19 the status is the bar
# colour of each section, so the title needs no status icon (an old one is still accepted).
_TITLE = re.compile(r'# (?:[🔴🟡🟢🔵] )?\S')
_ATTEMPTS = {}  # insertion-ordered set of sent (message, text) keys, bounded below
_ATTEMPT_LIMIT = 1000
_LOCK = threading.Lock()


def handle(td, args, sender=None):
    scope = td.personal_scopes
    if scope.config(td) is None or not team.has_role(scope.current(td), 'personal'):return td._error('PERSONAL_REPORT_DISABLED')
    if problem := scope.role_problem(td,'personal_work_bundle',{}):return td._error(problem)
    message = args.get('message')
    if set(args) != {'message'} or not isinstance(message,str) or not message.strip() or len(message)>12000:
        return td._error('PERSONAL_REPORT_INVALID')
    if not _TITLE.match(message):return td._error("PERSONAL_REPORT_FORMAT_REQUIRED: 첫 줄을 '# 제목'처럼 '# '로 시작한다. 상태는 아이콘 대신 묶음 소제목 낱말(막대 색)로 나타낸다.")
    message_id = td.get_session_env('HERMES_SESSION_MESSAGE_ID','')
    if not message_id:return td._error('PERSONAL_REPORT_CURRENT_REQUEST_REQUIRED')
    settings = td._PLUGIN_CONTEXT.get_config('personal_report',{})
    target = settings.get('dm_chat_id')
    verified_dm = vault.text('dms.personal')  # 사장 금고의 개인비서 DM. 없으면 검증할 수 없어 보내지 않는다
    if settings.get('enabled') is not True or not verified_dm or target != verified_dm:return td._error('PERSONAL_REPORT_TARGET_UNVERIFIED')
    if td.get_session_env('HERMES_SESSION_CHAT_ID','') == target:
        return json.dumps({'ok':True,'sent':False,'reason':'already_in_report_dm; use the normal final reply'})
    key = (message_id,hashlib.sha256(message.encode()).hexdigest())
    with _LOCK:
        if key in _ATTEMPTS:return td._error('PERSONAL_REPORT_ALREADY_ATTEMPTED: 전달 불확실이면 자동 재전송하지 않는다.')
        _ATTEMPTS[key] = True
        while len(_ATTEMPTS) > _ATTEMPT_LIMIT:
            _ATTEMPTS.pop(next(iter(_ATTEMPTS)))
    try:
        if sender is None:
            from tools.send_message_tool import send_message_tool
            sender = send_message_tool
        result = sender({'target':'slack:'+target,'message':message})
        if isinstance(result,str):result=json.loads(result)
        if not isinstance(result,dict) or result.get('success') is not True or not result.get('message_id'):
            return td._error('PERSONAL_REPORT_DELIVERY_UNCONFIRMED')
        return json.dumps({'ok':True,'sent':True,'message_id':result['message_id']})
    except Exception:
        return td._error('PERSONAL_REPORT_DELIVERY_UNCONFIRMED')
