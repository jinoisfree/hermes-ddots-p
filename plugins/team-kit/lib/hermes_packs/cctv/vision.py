"""Two-step reading of a captured window: first prove it is the right live view, then classify the scene.

`ask(prompt, images)` is the model call (the staff member's auxiliary vision model); tests pass a stand-in.
The model only reports what it sees: every decision on those reports is made here, in code."""
import base64
import json
import re
import subprocess
import tempfile
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo

SCENES = ('평소', '준비중', '진행중')
UNREADABLE = '판독불가'
SITE_FOLDERS = ('My Sites', '뷰가드서버 장비', '로컬 장비', '즐겨찾기')
MODEL_MAX_EDGE = 1600  # pixels; the model gets a shrunk copy so ten images stay under the payload limit
MODEL_TIMEOUT = 120
SIPS = '/usr/bin/sips'

IDENTIFY_PROMPT = """아래 이미지는 CCTV 감시 프로그램(ADT-EYE)이 열린 원격 데스크톱 창을 캡처한 것이다.
앞의 {count}장은 소유자가 등록한 '기준 구도' 참고 사진이고, 마지막 한 장이 방금 캡처한 화면이다.
화면에 실제로 보이는 것만 보고하고 추측하지 않는다. 가려져서 읽을 수 없으면 null로 답한다.
영상 밖 우클릭 메뉴는 영상 판정에서 뺀다. 단, 인증서·로그인·업데이트 대화상자가 뜬 화면은 adt_eye와 windows_desktop을 모두 false로 답한다. 채널·LIVE 표시는 영상 안의 오버레이만 본다.
JSON 한 개만 답한다:
{{"adt_eye": CCTV 감시 프로그램 화면이면 true, 아니면 false,
 "empty_view": "ADT-EYE에 레이아웃 탭은 있지만 영상 칸에 카메라 영상도 채널 표시도 없이 비어 있으면 true, 아니면 false",
 "windows_desktop": "ADT-EYE 창 없이 Windows 바탕화면 아이콘과 작업 표시줄이 보이고 잠금·로그인 화면이 아니면 true, 아니면 false",
 "channel": "화면 오버레이에 보이는 채널 표시를 보이는 그대로, 안 보이면 null",
 "live": "LIVE 표시가 보이면 true, 녹화 재생 등 LIVE가 없으면 false, 가려져 모르면 null",
 "osd_time": "영상 아래 시각에서 날짜를 빼고 시각만 HH:MM 또는 HH:MM:SS로 추출한다. 날짜는 절대로 포함하지 않는다. 못 읽으면 null",
 "waiting": "프레임을 기다리는 중 문구가 보이면 true, 아니면 false",
 "layout_tabs": "ADT-EYE 위쪽 탭 줄의 레이아웃 탭 개수(정수), 모르면 null",
 "site": "파란색으로 강조된 채널 줄이 속한 사이트 줄([번호] 이름 (주소) 형식)의 이름. My Sites·뷰가드서버 장비·로컬 장비·즐겨찾기는 폴더이며 사이트가 아니다. 사이트 줄이 안 보이거나 이름을 읽지 못하면 null",
 "video_box": 프로그램 창 안에서 카메라 영상이 그려진 칸(장비 목록·메뉴·여백 제외)의 위치를 마지막 이미지 전체 기준 0~1 비율 {{"x": 왼쪽, "y": 위, "w": 너비, "h": 높이}}로. 모르면 null,
 "same_view": 마지막 화면의 영상이 기준 구도 사진과 같은 카메라가 같은 장소를 같은 각도로 비추면 true, 아니면 false(프로그램 창의 크기·위치나 영상 칸의 크기·잘림이 달라도 카메라와 각도가 같으면 true),
 "reason": "한 문장"}}"""

CLASSIFY_PROMPT = """아래 이미지는 CCTV 카메라 화면이다. {examples}마지막 한 장이 방금 캡처한 화면이다. 마지막 화면의 장면을 하나로 분류한다.
{cropped}장비 목록·우클릭 메뉴·대화상자처럼 영상 밖의 창 요소는 판단에서 뺀다. 영상 영역만 보고, 낮이든 밤이든 밝기와 상관없이 분류한다.
- 평소: 줄에 매단 낙화봉도 불꽃도 없는 화면. 낮이든 밤이든, 용암 선 조명이 켜졌든 꺼졌든(붉은 선이든 흰·회색 선이든) 평소다. 바닥의 굵은 붉은 용암 선은 늘 켜 두는 평소 조명이다.
- 준비중: 줄에 낙화봉이 매달려 있으면(바위 위·물 위 등 위치와 관계없이) 불이 붙지 않은 동안은 준비중이다. 불꽃 줄기·불꽃 점이 보이면 진행중이다. 밝기와 상관없다. 낮이나 평소 화면에도 늘 서 있는 흰 기둥·난간 막대·울타리는 설치물일 뿐 낙화봉이 아니다.
- 진행중: 낙화가 타는 화면. 줄에 매단 낙화봉에서 금빛 불꽃 줄기가 쏟아지는 경우뿐 아니라, 화면 위쪽이나 먼 곳이라도 작은 흰·금빛 불꽃 점·줄기가 비처럼 떨어지거나 반짝이면 진행중이다(불꽃의 크기·거리와 관계없다). 밝기와 상관없다.
- 판독불가: 영상 영역이 가려졌거나 흐려서 위 셋을 구분할 수 없을 때만이다. 낮이라서, 조명이 꺼져 있어서, 영상 밖 메뉴가 떠 있어서는 판독불가가 아니다.
JSON 한 개만 답한다: {{"scene": "평소|준비중|진행중|판독불가", "reason": "한 문장"}}"""
CROPPED = "이미지들은 카메라 영상의 일부(낙화 불꽃이 보이는 위쪽 구역)만 잘라 낸 것이다. "
UNCROPPED = ""
LOCATE_PROMPT = """아래 이미지들은 CCTV 감시 프로그램(ADT-EYE) 창을 찍은 사진이나 캡처다. 각 이미지마다 카메라 영상이 그려진 칸(장비 목록·메뉴·여백·창 밖 제외)의 위치를 그 이미지 전체 기준 0~1 비율로 찾는다.
이미지 순서대로 JSON 배열 한 개만 답한다: [{{"x": 왼쪽, "y": 위, "w": 너비, "h": 높이}} 또는 영상 칸을 모르면 null, ...] (이미지 {count}장이므로 원소 {count}개)."""
WITH_EXAMPLES = "앞의 사진들은 '평소', '준비중', '진행중' 이름표가 붙은 참고 사진이다. "
WITHOUT_EXAMPLES = "참고 사진은 없다. 아래 설명만으로 판단한다. "


def parse_json(text):
    """First JSON object in a model answer (code fences allowed); None when there is none."""
    found = re.search(r'\{.*\}', str(text), re.S)
    if not found:
        return None
    try:
        value = json.loads(found.group(0))
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def _squash(value):
    return re.sub(r'\s+', '', str(value)).lower()


def _site_name(value):
    """A site as the device list shows it ('[1] Name (address)') reduced to its name."""
    return _squash(re.sub(r'\([^)]*\)|\[[^\]]*\]', '', str(value)))


def stopped(osd_time, waiting, now):
    """A readable clock (optional ISO date prefix, KST, circular at midnight) or an explicit waiting message proves a frozen video."""
    if waiting is True:
        return True
    if not isinstance(osd_time, str):
        return False
    found = re.fullmatch(r'(?:(\d{4}-\d{2}-\d{2}) )?((?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?)', osd_time)
    if found is None:
        return False
    if found[1]:
        try:
            datetime.strptime(found[1], '%Y-%m-%d')
        except ValueError:
            return False
    local = now.astimezone(ZoneInfo('Asia/Seoul')) if now.tzinfo else now
    values = list(map(int, found[2].split(':')))
    seconds = values[0] * 3600 + values[1] * 60 + (values[2] if len(values) == 3 else 0)
    delta = abs(local.hour * 3600 + local.minute * 60 + local.second - seconds)
    return min(delta, 86400 - delta) > 180


def identify(ask, capture, references, *, site_label, channel_label, now=None):
    """{'ok': True} or {'ok': False, 'reason': ...}. Every condition must hold; any doubt is a failure."""
    if not references:
        return {'ok': False, 'reason': '기준 구도 없음'}
    try:
        answer = parse_json(ask(IDENTIFY_PROMPT.format(count=len(references)),
                                [('기준 구도', path) for path in references] + [('방금 캡처', capture)]))
    except Exception as error:
        return {'ok': False, 'reason': '모델 오류:' + type(error).__name__}
    if answer is None:
        return {'ok': False, 'reason': '모델 답 형식 오류'}
    channel = answer.get('channel')
    site = answer.get('site')
    if _site_name(site) in {_site_name(folder) for folder in SITE_FOLDERS}:
        site = None  # A device-tree folder is unread site evidence, matching the existing null contract.
    detail = {key: answer[key] for key in ('adt_eye', 'osd_time', 'waiting', 'layout_tabs', 'empty_view', 'windows_desktop') if key in answer}
    if answer.get('adt_eye') is not True:
        reason = 'ADT-EYE 꺼짐' if answer.get('windows_desktop') is True else 'ADT-EYE 화면 아님'
    elif stopped(answer.get('osd_time'), answer.get('waiting'), now or datetime.now(ZoneInfo('Asia/Seoul'))):
        reason = '영상 멈춤'
    elif type(answer.get('layout_tabs')) is int and answer['layout_tabs'] == 0:
        reason = '레이아웃 없음'
    elif type(answer.get('layout_tabs')) is int and answer['layout_tabs'] >= 1 and answer.get('empty_view') is True:
        reason = '빈 화면'
    elif not channel:
        reason = '채널 확인 불가'
    elif _squash(channel) != _squash(channel_label):
        reason = '다른 채널'
    elif answer.get('live') is not True:
        reason = 'LIVE 아님'
    elif site and _site_name(site) != _site_name(site_label):
        reason = '다른 사이트'
    elif answer.get('same_view') is not True:
        reason = '기준 구도 불일치'
    else:
        return {'ok': True, 'detail': str(answer.get('reason', ''))[:200], 'video_box': valid_box(answer.get('video_box')), **detail}
    return {'ok': False, 'reason': reason, **detail}


def valid_box(value, *, smallest=0.05):
    """{'x','y','w','h'} as 0-1 fractions of an image, or None when the model's box is missing or nonsense."""
    if not isinstance(value, dict):
        return None
    try:
        box = {key: float(value[key]) for key in ('x', 'y', 'w', 'h')}
    except (KeyError, TypeError, ValueError):
        return None
    if any(box[key] != box[key] for key in box):   # NaN
        return None
    if box['x'] < 0 or box['y'] < 0 or box['w'] < smallest or box['h'] < smallest or box['x'] + box['w'] > 1.02 or box['y'] + box['h'] > 1.02:
        return None
    box['w'], box['h'] = min(box['w'], 1 - box['x']), min(box['h'], 1 - box['y'])
    return box


def locate(ask, paths):
    """The video-pane box of each image (None where the model cannot say). One model call for all of them."""
    if not paths:
        return []
    try:
        reply = ask(LOCATE_PROMPT.format(count=len(paths)), [(f'사진 {number + 1}', path) for number, path in enumerate(paths)])
        found = re.search(r'\[.*\]', str(reply), re.S)
        rows = json.loads(found.group(0)) if found else []
    except Exception:
        return [None] * len(paths)
    rows = rows if isinstance(rows, list) else []
    return [valid_box(rows[number]) if number < len(rows) else None for number in range(len(paths))]


def _size(path, run):
    done = run([SIPS, '-g', 'pixelWidth', '-g', 'pixelHeight', str(path)], capture_output=True, text=True, timeout=MODEL_TIMEOUT)
    sizes = dict(re.findall(r'pixel(Width|Height):\s*(\d+)', done.stdout))
    if done.returncode != 0 or set(sizes) != {'Width', 'Height'}:
        raise OSError('IMAGE_SIZE_FAILED')
    return int(sizes['Width']), int(sizes['Height'])


def crop(path, box, region, folder, name, run=subprocess.run):
    """A copy of `path` cut to `region` (fractions of the video pane) inside `box` (fractions of the image).
    Returns (path to use, what was applied): without a box the whole image is used and nothing is cut."""
    if box is None:
        return path, 'whole'
    width, height = _size(path, run)
    inner = region or {'x': 0.0, 'y': 0.0, 'w': 1.0, 'h': 1.0}
    left, top = box['x'] + inner['x'] * box['w'], box['y'] + inner['y'] * box['h']
    cut_w, cut_h = inner['w'] * box['w'], inner['h'] * box['h']
    pixels = (max(1, round(cut_w * width)), max(1, round(cut_h * height)), max(0, round(left * width)), max(0, round(top * height)))
    target = Path(folder) / f'{name}.png'
    done = run([SIPS, '-c', str(pixels[1]), str(pixels[0]), '--cropOffset', str(pixels[3]), str(pixels[2]), str(path), '--out', str(target)],
               capture_output=True, text=True, timeout=MODEL_TIMEOUT)
    if done.returncode != 0 or not target.exists():
        raise OSError('IMAGE_CROP_FAILED')
    return target, ('region' if region else 'video')


def classify(ask, capture, examples, *, box=None, region=None, run=subprocess.run):
    """{'scene': one of SCENES or 판독불가, 'reason': ..., 'crop': 'region'|'video'|'whole'}. `examples` maps a scene to its
    reference photos. The model sees only the video pane of the window (`box`), cut further to `region` (the part where
    the fireworks show) when one is set; example photos are cut the same way, each by its own located pane.
    Where a box is unknown the whole image is used, and `crop` says so."""
    pairs = [(f'참고 사진: {scene}', path) for scene in SCENES for path in examples.get(scene, ())]
    applied = 'whole'
    try:
        with tempfile.TemporaryDirectory() as folder:
            images = []
            boxes = locate(ask, [path for _, path in pairs]) if pairs and box is not None else [None] * len(pairs)
            for number, ((caption, path), found) in enumerate(zip(pairs, boxes)):
                images.append((caption, crop(path, found, region, folder, f'ref{number}', run)[0]))
            target, applied = crop(capture, box, region, folder, 'capture', run)
            images.append(('방금 캡처', target))
            answer = parse_json(ask(CLASSIFY_PROMPT.format(examples=WITH_EXAMPLES if pairs else WITHOUT_EXAMPLES,
                                                           cropped=CROPPED if applied == 'region' else UNCROPPED), images))
    except Exception as error:
        return {'scene': UNREADABLE, 'reason': '모델 오류:' + type(error).__name__, 'crop': applied}
    if answer is None or answer.get('scene') not in (*SCENES, UNREADABLE):
        return {'scene': UNREADABLE, 'reason': '모델 답 형식 오류', 'crop': applied}
    return {'scene': answer['scene'], 'reason': str(answer.get('reason', ''))[:300], 'crop': applied}


def _shrunk(path, folder, index, run):
    target = Path(folder) / f'{index}.jpg'
    done = run([SIPS, '-Z', str(MODEL_MAX_EDGE), '-s', 'format', 'jpeg', str(path), '--out', str(target)],
               capture_output=True, text=True, timeout=MODEL_TIMEOUT)
    if done.returncode != 0 or not target.exists():
        raise OSError('IMAGE_SHRINK_FAILED')
    return target


def model_caller(run=subprocess.run):
    """The real `ask`: the staff member's configured vision model, called once with every image."""
    def ask(prompt, images):
        from agent.auxiliary_client import call_llm
        with tempfile.TemporaryDirectory() as folder:
            content = [{'type': 'text', 'text': prompt}]
            for index, (caption, path) in enumerate(images):
                data = base64.b64encode(_shrunk(path, folder, index, run).read_bytes()).decode('ascii')
                content += [{'type': 'text', 'text': caption},
                            {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + data}}]
            reply = call_llm(task='vision', messages=[{'role': 'user', 'content': content}],
                             temperature=0.1, timeout=MODEL_TIMEOUT)
        return reply.choices[0].message.content
    return ask


CONTROL_PROMPTS = {
    'launch': """Windows 바탕화면에서 아이콘 글자가 정확히 '{icon}'인 앱 바로가기만 찾는다.
작업 표시줄·시작 메뉴·다른 아이콘은 제외한다. 잠금·로그인·업데이트 창이 있으면 고르지 않는다.
JSON: {{"desktop": 바탕화면 영역 상자, "icon": 아이콘 상자 또는 null, "icon_text": 보인 아이콘 글자 그대로,
"on_desktop": 바탕화면 바로가기이면 true, "confident": 확실할 때만 true}}""",
    'expand': """ADT-EYE의 뷰가드서버 장비 → My Sites → 사이트 {site} 경로에서 접힌 첫 마디를 찾는다.
즐겨찾기·로컬 장비는 제외한다. 펼쳐진 조상 아래 첫 접힌 마디의 펼침 삼각형만 고른다. 이미 모두 펼쳐져 있으면 triangle=null.
JSON: {{"device_list": 장비 목록 상자, "triangle": 펼침 삼각형 상자 또는 null,
"node": "server|sites|site", "node_text": 그 마디에 보인 글자 그대로, "parent_text": sites이면 뷰가드서버 장비, site이면 My Sites, server이면 null,
"collapsed": 접힌 마디일 때만 true, "under_favorites": 즐겨찾기 아래면 true 아니면 false,
"under_local": 로컬 장비 아래면 true 아니면 false, "confident": 확실할 때만 true}}""",
    'item': """ADT-EYE 왼쪽 뷰가드서버 장비 목록에서 사이트 {site} 아래 채널 {channel} 항목을 찾는다.
사이트 앞 [번호]는 무시한다. 즐겨찾기 묶음은 제외한다. 사이트가 접혀 항목이 안 보이면 item=null이다.
지정 채널 순번은 {index}다. 줄 글자가 '{index}. {channel}' 또는 이름 없이 '{index}.'인 항목만 고른다.
이름이 없어도 지정 사이트 아래 정확한 순번과 점을 읽으면 대상이다. 다른 순번·다른 채널명은 고르지 않는다.
JSON: {{"device_list": 상자, "item": 상자 또는 null, "item_text": 그 채널 줄 글자를 보이는 그대로, "site_text": 실제 보이는 사이트 줄 글자,
"under_favorites": 즐겨찾기 아래면 true 아니면 false, "confident": 확실할 때만 true}}""",
    'live': """방금 우클릭한 채널 항목 바로 옆에 뜬 메뉴에서 글자가 정확히 '라이브'인 줄만 찾는다.
검색/녹화 재생·새로고침·장비 추가/편집·채널 설정 등은 고르지 않는다. 메뉴나 라이브 줄이 안 보이면 null.
JSON: {{"menu": 상자 또는 null, "live_row": 상자 또는 null, "row_text": 그 줄 글자 그대로, "confident": 확실할 때만 true}}""",
    'plus': """ADT-EYE 제목 옆 위쪽 레이아웃 탭 줄의 '+'(새 레이아웃)만 찾는다.
탭 ×·되돌리기·오른쪽 화면 분할·설정 등은 제외한다. 확실히 안 보이면 null.
JSON: {{"tab_bar": 상자, "plus": 상자 또는 null, "confident": 확실할 때만 true}}""",
}


def control(ask, capture, kind, *, site_label, channel_label, app_icon_label=None, channel_index=None):
    """Locate one allowed control. Report raw model evidence and accept only a contained, confident exact target."""
    if kind == 'item' and (type(channel_index) is not int or channel_index < 1):
        return {'ok': False, 'reason': '채널 순번 없음 또는 잘못됨'}
    if kind == 'launch' and not app_icon_label:
        return {'ok': False, 'reason': '앱 아이콘 이름 없음'}
    prompt = CONTROL_PROMPTS[kind].format(site=site_label, channel=channel_label, icon=app_icon_label, index=channel_index)
    prompt += '\n상자는 마지막 이미지 전체 기준 0~1 비율 {"x": 왼쪽, "y": 위, "w": 너비, "h": 높이}다. JSON 한 개만 답한다.'
    try:
        answer = parse_json(ask(prompt, [('방금 캡처', capture)]))
    except Exception as error:
        return {'ok': False, 'reason': '위치 모델 오류:' + type(error).__name__}
    if answer is None:
        return {'ok': False, 'reason': '위치 모델 답 형식 오류'}
    container, target = {'item': ('device_list', 'item'), 'live': ('menu', 'live_row'), 'plus': ('tab_bar', 'plus'),
                         'launch': ('desktop', 'icon'), 'expand': ('device_list', 'triangle')}[kind]
    outer = valid_box(answer.get(container), smallest=0.001)
    box = valid_box(answer.get(target), smallest=0.001)
    accepted = answer.get('confident') is True and outer is not None and box is not None
    if accepted:
        x, y = box['x'] + box['w'] / 2, box['y'] + box['h'] / 2
        accepted = outer['x'] <= x <= outer['x'] + outer['w'] and outer['y'] <= y <= outer['y'] + outer['h']
    if kind == 'item':
        item_text = re.sub(r'\s+', '', str(answer.get('item_text', '')))
        expected = re.sub(r'\s+', '', f'{channel_index}.{channel_label}')
        accepted = (accepted and answer.get('under_favorites') is False
                    and _site_name(answer.get('site_text', '')) == _site_name(site_label)
                    and item_text in (expected, f'{channel_index}.'))
    elif kind == 'live':
        accepted = accepted and re.sub(r'\s+', '', str(answer.get('row_text', ''))) == '라이브'
    elif kind == 'launch':
        accepted = accepted and answer.get('on_desktop') is True and re.sub(r'\s+', '', str(answer.get('icon_text', ''))) == re.sub(r'\s+', '', app_icon_label)
    elif kind == 'expand':
        node = answer.get('node')
        labels = {'server': '뷰가드서버 장비', 'sites': 'My Sites', 'site': site_label}
        parents = {'sites': '뷰가드서버 장비', 'site': 'My Sites'}
        accepted = (accepted and answer.get('collapsed') is True and answer.get('under_favorites') is False
                    and answer.get('under_local') is False and node in labels
                    and _site_name(answer.get('node_text', '')) == _site_name(labels.get(node, ''))
                    and (node == 'server' or _squash(answer.get('parent_text', '')) == _squash(parents.get(node, ''))))
    return {'ok': bool(accepted), 'box': box if accepted else None, 'evidence': answer,
            'reason': '' if accepted else '안전한 위치 확인 불가:' + kind}
