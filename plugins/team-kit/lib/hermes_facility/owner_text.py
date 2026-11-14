"""Render owner labels from private policy without changing the public code."""
import json
import os
from pathlib import Path
from .owner_vault import root_home

DEFAULTS = {'company_domain_label': 'example-company',
 'company_email': 'user(at)example.com',
 'company_mail_alias': 'user(at)example.com',
 'company_name_title': 'example-company',
 'customers_name': 'SNS담당',
 'default_name': '위키담당',
 'doctor_dm_label': '진단담당 DM',
 'doctor_english_name': 'system-doctor',
 'doctor_name': '진단담당',
 'learning_channel_label': '학습 채널',
 'learning_room': '학습 채널',
 'location_env_name': 'ASSISTANT_LOCATION',
 'meeting_report_title': '정기회의 초안',
 'owner_account': 'starter-owner',
 'owner_label_lower': 'starter_user',
 'owner_label_title': 'starter_user',
 'owner_label_upper': 'starter_user',
 'personal_cron_prefix': 'as-',
 'personal_dm_label': 'assistant DM',
 'personal_email': 'user(at)example.com',
 'personal_full_name': '개인비서',
 'personal_name': '개인비서',
 'personal_skill_prefix': 'assistant',
 'relay_domain': 'example.com',
 'report_channel_id': 'REPLACE_SLACK_ID',
 'report_channel_label': '보고 채널',
 'report_room': '보고 채널',
 'report_rooms_label': '학습·보고 채널',
 'retired_meeting_job_id': '없음',
 'retired_system_room': '이전 시스템 채널',
 'settings_repository_name': 'hermes-config',
 'work_meeting_job_id': '미연결',
 'work_name': '업무비서',
 'work_profile': 'work-assistant',
 'work_profile_title': 'work-assistant',
 'work_skill_prefix': 'office',
 'workspace_folder': 'workspace'}
DEFAULTS['retired_labels'] = ''
DEFAULTS['company_notebook'] = 'company-notebook'
_CACHE = {}


def values():
    path = Path(os.environ.get('HERMES_OWNER_POLICY_FILE') or root_home() / 'owner/policy.yaml')
    try:
        stat = path.stat()
    except FileNotFoundError:
        return DEFAULTS
    stamp = (stat.st_mtime_ns, stat.st_size)
    cached = _CACHE.get(str(path))
    if cached and cached[0] == stamp: return cached[1]
    text = path.read_text()
    try: data = json.loads(text)
    except ValueError:
        from ruamel.yaml import YAML
        data = YAML(typ='safe').load(text)
    selected = data.get('text', {})
    if not isinstance(selected, dict) or any(not isinstance(v, str) for v in selected.values()):
        raise ValueError('invalid owner text policy')
    value = {**DEFAULTS, **selected}
    _CACHE[str(path)] = stamp, value
    return value


def render(template):
    output = template
    for key, value in values().items():
        output = output.replace('<<' + key + '>>', value)
    return output
