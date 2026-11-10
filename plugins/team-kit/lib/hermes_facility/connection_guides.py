"""Input instructions belong to the facility; clients render this data (AC-31)."""
import json
from pathlib import Path
from urllib.parse import urlencode


def step(n, text, **extra):
    return dict(n=n, text=text, **extra)


def check(field, pattern, message):
    return dict(field=field, pattern=pattern, message=message)


def manifest_url(manifest):
    query={'new_app':'1'}
    if isinstance(manifest,dict):query['manifest_json']=json.dumps(manifest,ensure_ascii=False,separators=(',',':'))
    return 'https://api.slack.com/apps?'+urlencode(query)


def instructions(service, home=None, manifest=None):
    if service in ('slack','ddots_slack'):
        if service=='slack' and home:
            try:manifest=json.loads((Path(home)/'slack-manifest.json').read_text())
            except (OSError,ValueError):manifest=None
        user=service=='ddots_slack';field='token' if user else 'bot_token'
        name='User OAuth Token' if user else 'Bot User OAuth Token'
        prefix='xoxp-' if user else 'xoxb-'
        rows=[step(1,'Slack 앱 만들기 버튼을 누르세요.',open_url=manifest_url(manifest)),
              step(2,'워크스페이스를 고르고 Next → Create를 누르세요.'),
              step(3,'Install App → Install to Workspace → 허용을 누르세요.'),
              step(4,'OAuth & Permissions의 '+name+' 옆 Copy를 눌러 첫 칸에 붙여넣으세요.',
                   check=check(field,r'^(?:xoxp-|xoxe\.xoxp-)[A-Za-z0-9.-]{15,400}$' if user else r'^xoxb-[A-Za-z0-9-]{15,400}$',
                               '4번 단계의 '+name+'이에요. '+prefix+'로 시작하는 값을 넣어 주세요.'))]
        if not user:
            rows.extend([step(5,'Basic Information → App-Level Tokens → Generate Token and Scopes에서 connections:write를 더하고 Generate를 누르세요.',copy='connections:write'),
                         step(6,'나온 토큰 옆 Copy를 눌러 두 번째 칸에 붙여넣으세요.',check=check('app_token',r'^xapp-[A-Za-z0-9-]{15,400}$','6번 단계의 App-Level Token이에요. xapp-로 시작하는 값을 넣어 주세요.'))])
        rows.append(step(5 if user else 7,'연결을 누르세요.'))
        if isinstance(manifest,dict):rows[0]['copy']=json.dumps(manifest,ensure_ascii=False,indent=2)
        return rows
    if service=='notion':
        return [step(1,'Notion의 내 통합에서 새 내부 통합을 만드세요.',open_url='https://www.notion.com/profile/integrations'),
                step(2,'통합의 시크릿 옆 복사를 눌러 비밀값 칸에 붙여넣으세요.',check=check('token',r'^(?:ntn_|secret_)[A-Za-z0-9_-]+$','2번 단계의 통합 시크릿이에요. ntn_ 또는 secret_로 시작하는 값을 넣어 주세요.')),
                step(3,'쓸 페이지의 연결 추가에서 만든 통합을 고르세요.'),step(4,'연결을 누르세요.')]
    if service=='synology':
        return [step(1,'이 Mac의 Synology Drive Client를 여세요.'),
                step(2,'연결 정보의 NAS 주소를 주소 칸에 붙여넣으세요.',check=check('api_base',r'^https?://[^\s]+$','2번 단계의 NAS 주소예요. http:// 또는 https://로 시작하는 주소를 넣어 주세요.')),
                step(3,'파일 링크에 쓰는 NAS 주소를 링크 주소 칸에 붙여넣으세요.'),
                step(4,'이 NAS에 로그인할 아이디를 아이디 칸에 넣으세요.'),
                step(5,'그 계정의 비밀번호를 비밀번호 칸에 넣으세요.'),
                step(6,'로그인 뒤 이 Mac의 동기화 폴더를 직접 고르세요.'),step(7,'쓸 폴더를 고르고 계속을 누르세요.')]
    if service=='obsidian_notes':
        return [step(1,'Obsidian에서 쓸 보관함의 위치를 확인하세요.'),step(2,'그 폴더를 직접 고르세요.')]
    if service=='x':
        return [step(1,'X에 직접 로그인하세요.',open_url='https://x.com'),step(2,'브라우저 개발자 도구의 쿠키에서 auth_token을 복사해 첫 칸에 붙여넣으세요.'),step(3,'같은 곳의 ct0를 복사해 두 번째 칸에 붙여넣으세요.')]
    if service=='instagram':
        return [step(1,'Meta 개발자 대시보드를 여세요.',open_url='https://developers.facebook.com/apps/'),step(2,'Instagram 장기 액세스 토큰을 복사해 토큰 칸에 붙여넣으세요.')]
    return [step(1,'이 연결에 쓸 계정이나 위치를 직접 고르세요.')]


def failure_hint(service, reason):
    if reason not in ('FORMAT_INVALID','TOKEN_INVALID','AUTH_FAILED','NO_TOKEN'):
        return None
    if service=='synology':return '2~3번 단계의 주소를 확인해 주세요.' if reason=='FORMAT_INVALID' else '4~5번 단계의 아이디와 비밀번호를 확인해 주세요.'
    if service=='slack':return '4번 Bot User OAuth Token과 6번 App-Level Token을 확인해 주세요.'
    rows=instructions(service)
    row=next((r for r in rows if r.get('check')),None)
    return row['check']['message'] if row else '2번 단계에서 복사한 값을 다시 확인해 주세요.'
