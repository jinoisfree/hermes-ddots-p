"""Current Slack owner authority for the doctor's Paseo entrypoint."""
from collections import OrderedDict
from pathlib import Path
import os
import re
import threading

from hermes_facility import team_registry as team

# The existing diagnosis turn records are shared with the direct handler, which
# must enforce the same restriction even when pre_tool_call is bypassed.
DIAGNOSIS_TURNS = OrderedDict()
DIAGNOSIS_LOCK = threading.RLock()


def direct_request(text):
    """Conservative, current-text-only exception to read-only diagnosis."""
    text = re.sub(r'```.*?```|`[^`]*`', '', text, flags=re.S)
    text = re.sub(r'(?m)^\s*>.*$', '', text)
    text = re.sub(r'"[^"\n]*"|\'[^\'\n]*\'|“[^”\n]*”|‘[^’\n]*’', '', text)
    text = re.sub(r'https?://\S+', '', text)
    if re.search(r'보내지|요청하지|전달하지|맡기지|중단하지|멈추지|하지\s*마|하지\s*말|금지|원인만|분석만\s*알려|해도\s*(?:돼|되)|아니|말고|말아|될까', text, re.I):
        return False
    return bool(re.search(
        r'(?<![A-Za-z0-9_])paseo(?![A-Za-z0-9_])[^\n.!?]{0,160}(?:맡겨|요청해|요청\s*해|요청할\s*수\s*있자너|'
        r'전달해|전달\s*해|보내줘|보내\s*줘|중단해|중단\s*해|멈춰|'
        r'(?:진행|상태|결과)[^\n.!?]{0,40}(?:조회|확인|알려))', text, re.I))


def owner_text(home=None, **context):
    """Bind the persisted owner request to THIS task-local transport event."""
    from gateway.session_context import get_session_env as env
    from hermes_constants import get_hermes_home
    from hermes_team_services import learning
    from tools.skill_provenance import is_background_review

    actual_home = Path(get_hermes_home()).resolve()
    home = actual_home if home is None else Path(home).resolve()
    profile = env('HERMES_SESSION_PROFILE', '')
    if (home != actual_home or team.profile_of_home(home) != profile
            or not team.has_role(profile, 'doctor')):
        raise ValueError('Paseo doctor profile/home mismatch')
    if any(context.get(key) for key in ('parent_session_id', 'aux_task', 'auxiliary')):
        raise ValueError('Paseo requires the main human turn')
    flags = ('HERMES_CRON_SESSION', 'HERMES_SINGLE_QUERY_SESSION', 'HERMES_KANBAN_TASK',
             'HERMES_DIAGNOSIS_REQUEST', 'HERMES_ORG_REVIEW_RUN')
    if is_background_review() or any(env(key, '') or os.environ.get(key) for key in flags):
        raise ValueError('Paseo refuses unattended and diagnosis-request execution')
    fields = {key: env('HERMES_SESSION_' + key, '') for key in
              ('PLATFORM', 'ID', 'USER_ID', 'CHAT_ID', 'THREAD_ID', 'MESSAGE_ID')}
    if fields['PLATFORM'] != 'slack' or not all(fields[key] for key in ('ID', 'USER_ID', 'CHAT_ID', 'MESSAGE_ID')):
        raise ValueError('Paseo requires a current Slack transport event')
    if context.get('session_id') and context['session_id'] != fields['ID']:
        raise ValueError('Paseo session mismatch')
    if fields['USER_ID'] not in learning.owners(home):
        raise ValueError('Paseo requires the configured Slack owner')
    learning.extension('learning_skills').human_context()
    source = learning.source(home, fields['ID'], allow_approval=True)
    wanted = {'session_id': fields['ID'], 'user_id': fields['USER_ID'],
              'chat_id': fields['CHAT_ID'], 'thread_id': fields['THREAD_ID'],
              'platform_message_id': fields['MESSAGE_ID']}
    if any(str(source.get(key) or '') != value for key, value in wanted.items()):
        raise ValueError('Paseo current owner source mismatch')
    if not isinstance(source.get('text'), str) or not source['text'].strip():
        raise ValueError('Paseo has no current owner text')
    return source['text']


def require(home=None, *, diagnosis=False, **context):
    """One authority decision for the diagnostic filters and direct execution."""
    from gateway.session_context import get_session_env as env
    from hermes_constants import get_hermes_home
    text = owner_text(home, **context)
    # A compression boundary can rotate the DB session during this same inbound
    # Slack request; it must not drop the diagnosis restriction on the handler.
    event = tuple(env('HERMES_SESSION_'+key, '') for key in ('CHAT_ID','THREAD_ID','MESSAGE_ID'))
    resolved = str(Path(home or get_hermes_home()).resolve())
    with DIAGNOSIS_LOCK:
        active = any(key[0] == resolved and row.get('paseo_event') == event
                     for key, row in DIAGNOSIS_TURNS.items())
    if (diagnosis or active) and not direct_request(text):
        raise ValueError('Read-only diagnosis requires a current direct Paseo request')
    return text


def permitted(home, **context):
    try:
        require(home, diagnosis=True, **context)
        return True
    except Exception:
        # An unavailable configuration/database is not permission to submit work.
        return False
