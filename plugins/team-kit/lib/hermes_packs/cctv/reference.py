"""Reference photos the owner teaches the check with, and the one tool that manages them.

A photo comes from the owner's latest Slack message or a recent inspection in that same conversation,
and the owner's words are quoted. Customer sessions, scheduled runs and one-shot sessions cannot store,
list or delete anything."""
import contextlib
import fcntl
import json
import os
import re
import shutil
import tempfile
import time
import uuid
from datetime import datetime
from pathlib import Path

from . import settings, state

LABELS = ('기준구도', '평소', '준비중', '진행중', '비', '비아님')
EXTENSIONS = ('.png', '.jpg', '.jpeg', '.webp')
MAX_BYTES = 10 * 1024 * 1024
NOTE_LIMIT = 200
ATTACHED = re.compile(r'\[Image attached at: ([^\]\n]+)\]')

SCHEMA = {
    'name': 'cctv_reference',
    'description': 'CCTV 참고 사진을 소유자가 고객 응대 방이나 DM에서 말한 대로 저장·조회·삭제한다. '
                   'label은 기준구도(카메라 구도 기준)·평소·준비중·진행중·비·비아님. 비·비아님은 학습 사진 수집 전용이며 판독·알림·상황 기록·고객 응대에 쓰지 않는다. '
                   "소유자가 '지금은 ○○ 상태야'라고 가르치면 이 대화에서 지시서 cctv_watch.teach_check_minutes가 정한 시간 안에 본 화면이 없을 때 먼저 cctv_now를 부르고, 그 화면을 from_check=true로 저장한다. "
                   '이름표가 불분명하면 묻는다. 첨부 사진은 소유자가 방금 보낸 글에 붙은 것만 받는다. '
                   'user_said에 소유자의 최신 글을 그대로 인용한다. 고객 대화·예약·단발 실행에서는 쓸 수 없다.',
    'parameters': {'type': 'object', 'properties': {
        'action': {'type': 'string', 'enum': ['add', 'list', 'remove']},
        'label': {'type': 'string', 'enum': list(LABELS)},
        'note': {'type': 'string', 'maxLength': NOTE_LIMIT},
        'image_path': {'type': 'string', 'description': '소유자 글의 사진 경로(사진 설명 아래 image_url: … 또는 [Image attached at: …]). 사진이 하나뿐이면 생략'},
        'from_check': {'type': 'boolean', 'description': '이 대화에서 방금 cctv_now로 확인한 화면을 저장. image_path와 함께 쓰지 않는다'},
        'id': {'type': 'string', 'description': 'remove할 참고 사진 번호(list로 확인)'},
        'user_said': {'type': 'string', 'description': '소유자 최신 글을 그대로 인용'},
    }, 'required': ['action'], 'additionalProperties': False},
}


def _index_path(home):
    return state.reference_folder(home) / 'index.json'


@contextlib.contextmanager
def _index(home):
    folder = state.reference_folder(home)
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / 'index.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            data = json.loads(_index_path(home).read_text(encoding='utf-8'))
        except FileNotFoundError:
            data = {'version': 1, 'items': []}

        def save():
            fd, temporary = tempfile.mkstemp(prefix='.index-', dir=folder)
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                    json.dump(data, stream, ensure_ascii=False, indent=1)
                os.replace(temporary, _index_path(home))
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        yield data['items'], save


def photos(home, label, limit):
    """Newest photos of one label, newest first."""
    with _index(home) as (items, _):
        chosen = [item for item in items if item['label'] == label]
    chosen.sort(key=lambda item: item['added_at'], reverse=True)
    return [state.reference_folder(home) / item['file'] for item in chosen[:limit]]


def _squash(text):
    return ''.join(str(text).split())


HINTS = {
    'CCTV_REFERENCE_CHECK_REQUIRED': ('이 대화에서 방금 본 화면이 아니에요. 이 대화에서 cctv_now로 지금 화면을 다시 확인한 뒤 저장하세요.'),
    'CCTV_REFERENCE_POLICY_INVALID': ('지시서 cctv_watch.enabled와 teach_check_minutes를 확인해 주세요. 같은 대화의 확인 화면을 저장할 수 있는 설정이 없거나 잘못됐어요.'),
    'CCTV_REFERENCE_IMAGE_REQUIRED': ('등록하려는 사진이 이번 소유자 글에 붙어 있지 않아요. "위 사진"처럼 앞 글이나 스레드의 이전 사진은 쓸 수 없으니, '
                                      '소유자에게 사진을 이번 글에 다시 함께 올려 달라고 안내하세요. 도구를 다시 부를 때는 이 글에 붙은 사진만 가리킵니다.'),
}


def conversation_key():
    """The gateway's conversation, with a top-level message serving as its own thread."""
    from hermes_governance import app_tools
    return (app_tools.env('HERMES_SESSION_CHAT_ID', ''),
            app_tools.env('HERMES_SESSION_THREAD_ID', '') or app_tools.env('HERMES_SESSION_MESSAGE_ID', ''))


def _checked_image(home):
    minutes = settings.teach_check_minutes()
    if minutes is None:
        raise ValueError('CCTV_REFERENCE_POLICY_INVALID')
    current = datetime.now().astimezone()
    record = state.load(home, current.date().isoformat()).get('last_ask') or {}
    chat, thread = conversation_key()
    try:
        checked = datetime.fromisoformat(record['checked_at']).astimezone()
        age = (current - checked).total_seconds()
        path = Path(record['capture']).resolve()
        valid = (record.get('ok') is True and record.get('identified') is True
                 and chat and thread and record.get('chat') == chat and record.get('thread') == thread
                 and checked.date() == current.date() and 0 <= age <= minutes * 60
                 and path.is_relative_to((state.folder(home) / 'captures').resolve()) and path.is_file())
    except (KeyError, TypeError, ValueError, OSError, OverflowError):
        valid = False
    if not valid:
        raise ValueError('CCTV_REFERENCE_CHECK_REQUIRED')
    return path, {'source': 'check', 'osd_time': record.get('osd_time')}


def _image(home, wanted, message, media):
    """The attached file the owner's message names, inside the staff member's own image cache.
    `media` holds the paths of the gateway's leading picture notes (already verified with the owner header);
    a path may also appear in the text itself as a native-image hint."""
    attached = [Path(p.strip()) for p in [*media, *ATTACHED.findall(message)]]
    attached = list(dict.fromkeys(attached))
    if wanted:
        attached = [p for p in attached if str(p) == str(wanted)]
    if len(attached) != 1:
        raise ValueError('CCTV_REFERENCE_IMAGE_REQUIRED')
    path = attached[0].resolve()
    caches = [(Path(home) / 'cache' / 'images').resolve(), (Path(home) / 'image_cache').resolve()]
    if (not any(path.is_relative_to(cache) for cache in caches) or path.suffix.lower() not in EXTENSIONS
            or not path.is_file() or path.stat().st_size > MAX_BYTES):
        raise ValueError('CCTV_REFERENCE_IMAGE_INVALID')
    return path


def _add(home, args, message, media):
    label, note = args.get('label'), str(args.get('note') or '')
    if label not in LABELS or len(note) > NOTE_LIMIT:
        raise ValueError('CCTV_REFERENCE_ARGUMENTS_INVALID')
    if type(args.get('from_check', False)) is not bool or (args.get('from_check') and 'image_path' in args):
        raise ValueError('CCTV_REFERENCE_ARGUMENTS_INVALID')
    if args.get('from_check'):
        source, metadata = _checked_image(home)
    else:
        source, metadata = _image(home, args.get('image_path'), message, media), {}
    identifier = uuid.uuid4().hex[:8]
    name = identifier + source.suffix.lower()
    with _index(home) as (items, save):
        shutil.copyfile(source, state.reference_folder(home) / name)
        items.append({'id': identifier, 'file': name, 'label': label, 'note': note, 'added_at': time.time(), **metadata})
        save()
    return {'ok': True, 'id': identifier, 'label': label, **({'osd_time': metadata['osd_time']} if metadata else {})}


def _remove(home, identifier):
    with _index(home) as (items, save):
        found = next((item for item in items if item['id'] == identifier), None)
        if found is None:
            raise ValueError('CCTV_REFERENCE_UNKNOWN')
        items.remove(found)
        save()
        (state.reference_folder(home) / found['file']).unlink(missing_ok=True)
    return {'ok': True, 'removed': identifier}


class Authority:
    """Who is talking: proven from the gateway session and the stored owner message, never from tool arguments."""

    def __init__(self, home):
        self.home = Path(home)

    def room_problem(self):
        from hermes_facility import owner_vault
        from hermes_governance import app_tools, write_policy
        if not write_policy.owner_chat(self.home, app_tools.env) or app_tools.env('HERMES_SESSION_PLATFORM', '').lower() != 'slack':
            return 'CCTV_REFERENCE_OWNER_CHAT_REQUIRED'
        chat = app_tools.env('HERMES_SESSION_CHAT_ID', '')
        if chat != owner_vault.text('channels.customer_room') and not chat.startswith('D'):
            return 'CCTV_REFERENCE_ROOM_REQUIRED'
        return None

    def owner_message(self, session_id):
        """The owner's latest message as the learning service verified it: {'text': ..., 'media': [...]}."""
        from hermes_team_services import learning
        found = learning.source(self.home, str(session_id or ''))
        return {'text': found['text'], 'media': list(found.get('media', []))}


def handle(home, args, *, session_id=None, authority=None, **_):
    authority = authority or Authority(home)
    try:
        refusal = authority.room_problem()
        if refusal:
            raise ValueError(refusal)
        action = args.get('action')
        if action == 'list':
            with _index(home) as (items, _save):
                return json.dumps({'ok': True, 'photos': [{k: item[k] for k in ('id', 'label', 'note', 'added_at')}
                                                           for item in items]}, ensure_ascii=False)
        if action not in ('add', 'remove'):
            raise ValueError('CCTV_REFERENCE_ARGUMENTS_INVALID')
        try:
            owner = authority.owner_message(session_id)
            message, media = owner['text'], owner['media']
        except (ValueError, OSError) as error:
            raise ValueError('CCTV_REFERENCE_OWNER_MESSAGE_UNVERIFIED') from error
        said = args.get('user_said')
        if not isinstance(said, str) or not said.strip() or _squash(said) not in _squash(message):
            raise ValueError('CCTV_REFERENCE_QUOTE_MISMATCH')
        result = _add(home, args, message, media) if action == 'add' else _remove(home, str(args.get('id') or ''))
        return json.dumps(result, ensure_ascii=False)
    except ValueError as error:
        reply = {'ok': False, 'error': str(error)}
        if str(error) in HINTS:
            reply['message'] = HINTS[str(error)]
        return json.dumps(reply, ensure_ascii=False)
