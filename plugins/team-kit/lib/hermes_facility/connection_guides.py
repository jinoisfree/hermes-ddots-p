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


def instructions(service, home=None, manifest=None, *, stage=None):
    if service=='slack':
        if home:
            try:manifest=json.loads((Path(home)/'slack-manifest.json').read_text())
            except (OSError,ValueError):manifest=None
        rows=[step(1,'열기를 눌러 Slack에서 앱을 만들고, 사용할 작업 공간을 고르세요.',open_url=manifest_url(manifest)),
              step(2,'앱 설치에서 작업 공간에 설치하고 허용을 누르세요.'),
              step(3,'권한 페이지에서 xoxb-로 시작하는 로그인 열쇠 글자를 복사해 첫 칸에 붙여넣으세요.',
                   check=check('bot_token',r'^xoxb-[A-Za-z0-9-]{15,400}$','xoxb-로 시작하는 로그인 열쇠 글자를 넣어 주세요.')),
              step(4,'앱 기본 정보에서 앱용 로그인 열쇠를 만들고, 아래 값을 연결 권한에 더하세요.',copy='connections:write'),
              step(5,'xapp-로 시작하는 로그인 열쇠 글자를 복사해 두 번째 칸에 붙여넣으세요.',
                   check=check('app_token',r'^xapp-[A-Za-z0-9-]{15,400}$','xapp-로 시작하는 앱 로그인 열쇠 글자를 넣어 주세요.'))]
        if isinstance(manifest,dict):rows[0]['copy']=json.dumps(manifest,ensure_ascii=False,indent=2)
        return rows
    if service=='notion':
        return [step(1,'열기를 눌러 Notion에서 새 연결을 만드세요.',open_url='https://www.notion.com/profile/integrations'),
                step(2,'로그인 열쇠 글자를 복사해 아래 칸에 붙여넣으세요.',
                     check=check('token',r'^(?:ntn_|secret_)[A-Za-z0-9_-]+$','ntn_ 또는 secret_로 시작하는 로그인 열쇠 글자를 넣어 주세요.')),
                step(3,'쓸 페이지의 연결 추가에서 방금 만든 연결을 고르세요.')]
    if service=='synology':
        if stage=='address':
            return [step(1,'서버에 연결할 주소를 넣어 주세요. 이미 채워진 주소는 그대로 써도 돼요.'),
                    step(2,'파일을 열 때 쓸 주소를 넣어 주세요. 모르면 Drive Client의 연결 정보를 확인해 주세요.')]
        if stage=='login':
            return [step(1,'시놀로지에 로그인할 비밀번호를 넣어 주세요. 아이디가 채워져 있으면 확인하고, 다르면 고쳐 주세요.')]
        return [step(1,'비밀번호를 넣고 아이디를 확인해 주세요.'),step(2,'서버에서 동기화할 폴더와 쓸 폴더를 골라 주세요.')]
    if service=='obsidian_notes':
        return [step(1,'Obsidian에서 쓸 보관함의 위치를 확인하세요.'),step(2,'그 보관함 폴더를 아래 칸에 넣어 주세요.')]
    if service=='x':
        return [step(1,'열기를 눌러 X에 로그인하세요.',open_url='https://x.com'),
                step(2,'브라우저의 개발자 도구에서 쿠키 목록을 열고, auth_token 값을 복사해 첫 칸에 붙여넣으세요.',copy='auth_token'),
                step(3,'같은 목록의 ct0 값을 복사해 두 번째 칸에 붙여넣으세요.',copy='ct0')]
    if service=='instagram':
        return [step(1,'열기를 눌러 Meta의 앱 관리 페이지를 여세요.',open_url='https://developers.facebook.com/apps/'),
                step(2,'Instagram의 장기 로그인 열쇠 글자를 복사해 아래 칸에 붙여넣으세요.')]
    return [step(1,'이 연결에 쓸 계정이나 위치를 골라 주세요.')]


def failure_hint(service, reason):
    if reason not in ('FORMAT_INVALID','TOKEN_INVALID','AUTH_FAILED','NO_TOKEN'):
        return None
    if service=='synology':return '주소를 확인해 주세요.' if reason=='FORMAT_INVALID' else '아이디와 비밀번호를 확인해 주세요.'
    if service=='slack':return '첫 칸의 봇 로그인 열쇠와 두 번째 칸의 앱 로그인 열쇠를 확인해 주세요.'
    rows=instructions(service)
    row=next((r for r in rows if r.get('check')),None)
    return row['check']['message'] if row else '복사한 로그인 열쇠 글자를 다시 확인해 주세요.'
