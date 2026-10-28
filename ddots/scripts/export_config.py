#!/usr/bin/env python3
"""Read only allowlisted Hermes metadata. Run with the gateway's Python environment."""
from __future__ import annotations
import argparse
import importlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

SAMPLES = [
    '', '안녕', '고마워', '내일 일정 알려줘', '위키에서 지난 회의록 찾아줘',
    '오늘 토큰 얼마나 썼어?', '인스타 DM 온 거 있어?', '네이버 톡톡 문의 확인해줘',
    '위키', 'memory 검색', '일정 등록해줘', '메일 읽어줘', '메일 보내줘',
    '메모 수정하지 마', '메모 수정 여부 확인', '캘린더 확인해줘', '캘린다 확인해줘',
    '파일 찾아줘', '보고서 작성해줘', '노션 정리해줘', 'PDF로 변환해줘',
    '위키와 일정 각각 확인해줘', '문서와 인스타 DM 같이 찾아줘', '우선순위 정해줘',
    '헤르메스 오류 진단해줘', '게이트웨이 작업 시간 확인', '토큰', '인스타그램',
    '> 메일 보내줘\n안녕', '`메일 보내줘` 안녕', '```\n일정 등록\n```\n위키 찾아줘',
    '기존 메모 연동만 해줘', '노션 내용을 참고해서 파일 찾아줘',
    '메일이라는 열 수정해줘', '자료 검색\n---\n메일 보내줘', '일정 안 바꿔',
    '만든 메모 읽어줘', '회의 알려줘', '전체 현황 알려줘', '첨부 파일 요약해줘',
]
SAMPLES += ['내일 일정 등록해줘', '내일 일정 확인해줘', '메일 보내지 말고 내용만 요약해줘', '메일 발송 여부 확인하고 일정 등록해줘', '수정된 메모 읽어줘', '메일 안 보내고 내용만 확인해줘', '계약서 검토해줘', 'Hermes에 저장한 계약서 검토해줘', 'Hermes 오류 진단해줘', '위키 찾아줘', '인스타 답장 확인', '내일 오전 일정 알려줘', '헤이', '', '위키에 지난 회의 내용 있어?', '메모리에서 그 자료 찾아줘', '메모리 부족하다던데', '오늘 토큰 얼마나 썼어?', '아까 작업 시간 왜 그렇게 걸렸어', '점거 시간 알려줘', '게이트웨이 오류 진단해줘', '인스타 새로 온 거 있어?', 'DM 답장 보내줘', '피드 올릴 거 정리해줘', 'random 값', '네이버 톡톡 확인해줘', '톡톡 답장 수정해줘', 'naver talk 확인', '인스타 DM 처리에 토큰 얼마나 들었어', '오늘 뭐부터 할지 우선순위 정해줘', '위키 찾아보고 그리고 일정도 등록해줘', '```\n위키 찾아줘\n```\n내일 일정 알려줘', '> 인스타 확인해줘\n고마워', '`토큰` 이라는 단어']
# A deliberately bounded schema: never copy config dictionaries wholesale.
ROLE_KEYS = ('wiki', 'personal_operations', 'personal_review', 'company_operations',
             'data_operations', 'audit', 'coordination', 'standby', 'fallback')
PATTERN_KEYS = ('personal_write', 'wiki_target', 'wiki', 'wiki_action', 'personal_target',
                'personal_operations', 'personal_action', 'coordination', 'cross_owner_connector',
                'company_target', 'company_action', 'audit_subject', 'data_target', 'data_action',
                'audit_target', 'audit_action', 'audit_strong_action', 'personal_request',
                'attachment_request', 'document_conversion')

def yaml_load(path):
    try:
        from ruamel.yaml import YAML
    except ImportError as exc:
        raise RuntimeError('ruamel.yaml이 필요합니다. Hermes gateway venv의 Python으로 실행하세요.') from exc
    if not path.exists():
        return {}
    try:
        value = YAML(typ='safe').load(path.read_text(encoding='utf-8'))
    except Exception as exc:
        # YAML diagnostics may quote adjacent credential-bearing lines. Never forward them.
        raise ValueError(f'YAML 구문을 읽지 못했습니다: {path.name}') from exc
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f'설정은 mapping이어야 합니다: {path.name}')
    return value

def strings(value):
    return [str(v) for v in value if isinstance(v, str)] if isinstance(value, list) else []

def mapping(value):
    return value if isinstance(value, dict) else {}

def picked(value, keys):
    return {k: v for k, v in mapping(value).items() if k in keys and isinstance(v, str)}

def safe(value):
    """Inspect only the output, never credential files; fail without echoing the value."""
    if isinstance(value, dict):
        for key, child in value.items():
            safe(key); safe(child)
    elif isinstance(value, list):
        for child in value: safe(child)
    elif isinstance(value, str):
        if re.search(r'(?:xox[a-z]*-|sk-|gh[pousr]_|github_pat_|ya29\.)[A-Za-z0-9_.-]+', value, re.I) or re.search(r'(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{48,}={0,2}(?![A-Za-z0-9+/])', value):
            raise ValueError('출력 허용 값에 비밀 형태 문자열이 있습니다. 출력하지 않습니다.')

def atomic_json(output, value):
    safe(value)
    text = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n'
    output = Path(output); output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + output.name + '-', dir=output.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def integer(value):
    if type(value) is int:
        return value
    if isinstance(value,str) and len(value) <= 16 and re.fullmatch(r'[+-]?[0-9]+',value):
        return int(value)
    raise ValueError('오타 교정의 숫자 설정은 정수여야 합니다.')

def contract(raw):
    raw = mapping(raw)
    profiles = picked(raw.get('profiles'), ROLE_KEYS)
    patterns = picked(raw.get('patterns'), PATTERN_KEYS)
    aliases = {str(k): strings(v) for k, v in mapping(raw.get('aliases')).items()}
    typo = mapping(raw.get('typo_correction'))
    prefixes = mapping(raw.get('address_prefixes'))
    return dict(profiles=profiles, patterns=patterns, aliases=aliases, alias_order=list(aliases),
                cross_owner=picked(raw.get('cross_owner'), ('profile',)),
                address_prefixes=dict(enabled=prefixes.get('enabled') is True,
                                      profiles=picked(prefixes.get('profiles'), mapping(prefixes.get('profiles')).keys())),
                typo_correction=dict(enabled=typo.get('enabled') is True,
                                     max_distance=max(0, min(2, integer(typo.get('max_distance', 1)))),
                                     min_term_length=max(3, integer(typo.get('min_term_length', 3))),
                                     terms={k: strings(v) for k, v in mapping(typo.get('terms')).items() if k in PATTERN_KEYS}),
                hub_request_routing=raw.get('hub_request_routing') is True)

def samples_for(base):
    texts = list(SAMPLES)
    for profile, names in base['aliases'].items():
        for name in names[:1]:
            texts += [f'{name}, 안녕', f'{name}에게 확인해줘', f'이제 {name} 맡아줘', f'@{profile} 안녕']
    for prefix in base['address_prefixes']['profiles']:
        texts += [prefix + '일정 알려줘', prefix + ' 메일 읽어줘']
    return list(dict.fromkeys(texts))

# Conversation rules are metadata, not an arbitrary settings dictionary.
CONVERSATION_KEYS = {'texts': ['settledText', 'unanswered', 'draft', 'approveText', 'denyText', 'branchText', 'mailApproveText', 'mailDenyText', 'checklistSkip', 'checklistAll', 'checklistPrefix', 'learningApprove', 'learningDeny', 'workingText', 'waitingText', 'approvedText', 'denyLabel', 'mailApproveLabel', 'reviseLabel', 'mailReviseLabel', 'learningReviseLabel'], 'colors': ['questionColor', 'approvedColor', 'alertColor', 'askingColor', 'workingColor', 'closedColor'], 'patterns': ['nothingWaiting', 'sentLearning', 'mailDraft', 'mailWaiting', 'mailSent', 'thinking', 'approval1', 'approval2', 'learningReport1', 'learningReport2'], 'sets': ['settled', 'yes', 'workingStatus', 'closedStatus'], 'numbers': ['longThread', 'alertWindow']}

def conversation_contract(raw):
    if not isinstance(raw, dict) or type(raw.get('schema')) is not int or raw['schema'] != 1:
        return None
    result = {'schema': 1}
    for group, keys in CONVERSATION_KEYS.items():
        values = mapping(raw.get(group))
        selected = {}
        for key in keys:
            value = values.get(key)
            if group == 'sets':
                if isinstance(value, list) and all(isinstance(v, str) for v in value): selected[key] = value
            elif group == 'numbers':
                if type(value) in (int, float): selected[key] = value
            elif isinstance(value, str): selected[key] = value
        if selected: result[group] = selected
    safe(result)
    return result

def export(home, agent_source=None):
    home = Path(home)
    config = yaml_load(home / 'config.yaml')
    raw = mapping(mapping(config.get('gateway')).get('common_router'))
    if not raw or not mapping(raw.get('profiles')).get('fallback'):
        raise ValueError('gateway.common_router.profiles.fallback 설정이 필요합니다.')
    if agent_source:
        sys.path.insert(0, str(Path(agent_source).resolve()))
    try:
        router = importlib.import_module('gateway.common_router')
        project = importlib.import_module('gateway.project_threads')
    except ImportError as exc:
        raise RuntimeError('Hermes 본체 경로를 PYTHONPATH 또는 --agent-source로 지정하세요.') from exc
    hub = mapping(raw.get('project_hub'))
    effective = project.routing_contract(raw, 'slack', str(hub.get('channel_id', '')))
    base, home_contract = contract(raw), contract(effective)
    members = []
    bots = picked(hub.get('staff_user_ids'), mapping(hub.get('staff_user_ids')).keys())
    team, listeners, excluded = set(), set(), set()
    roots = [('default', home)] + [(p.name, p) for p in sorted((home / 'profiles').glob('*')) if p.is_dir() and not p.name.startswith('.')]
    for profile, root in roots:
        cfg = config if root == home else yaml_load(root / 'config.yaml')
        meta = yaml_load(root / 'profile.yaml')
        slack = mapping(mapping(cfg.get('platforms')).get('slack'))
        # Config loader merges platform's extra with its direct custom keys.
        extra = {**mapping(slack.get('extra')), **{k: v for k, v in slack.items() if k != 'extra'}}
        solo = mapping(extra.get('solo_channel'))
        if solo.get('enabled') is True:
            team.update(strings(solo.get('team_bots'))); listeners.update(strings(solo.get('listener_bots')))
            excluded.update(strings(extra.get('report_channels')))
            if isinstance(extra.get('project_hub_channel_id'), str): excluded.add(extra['project_hub_channel_id'])
        members.append(dict(profile=profile, displayName=str(meta.get('display_name') or profile),
                            aliases=base['aliases'].get(profile, []), slackUserID=bots.get(profile, '')))
    rows=[]
    for text in samples_for(base):
        # Source contract, not the sanitized export, is the independent oracle.
        rows.append(dict(text=text, base=router.select_profile(text, raw).profile,
                         hub=router.select_profile(text, effective).profile))
    # No content override is safe merely because a finite corpus happened to agree.
    # Fallback is exactly the contract's fallback, so it is retained without new grammar.
    overrides = {'fallback': base['profiles']['fallback']}
    result = dict(schemaVersion=1, members=members, routing={'base':base,'hub':home_contract},
                  routing_samples=rows, ddots_overrides=overrides,
                  rooms=picked(mapping(raw.get('dedicated_channels')).get('slack'), mapping(mapping(raw.get('dedicated_channels')).get('slack')).keys()),
                  solo=dict(team_bots=sorted(team),listener_bots=sorted(listeners),excluded_rooms=sorted(excluded)),
                  defaults={'recipient':base['profiles']['fallback']},
                  features={'homeRoom':str(hub.get('channel_id') or '')})
    conversation = conversation_contract(mapping(config.get("ddots")).get("conversation"))
    if conversation is not None: result["conversation"] = conversation
    safe(result)
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, default=Path(os.environ.get('HERMES_HOME', '~/.hermes')).expanduser())
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--agent-source', type=Path)
    args=parser.parse_args()
    try:
        value=export(args.home,args.agent_source);atomic_json(args.output,value)
    except (ValueError,RuntimeError,OSError) as exc:
        parser.exit(1, str(exc)+'\n')
    print(f'설정 내보내기 완료: {len(value["routing_samples"])}개 판정 샘플')
if __name__=='__main__':main()
