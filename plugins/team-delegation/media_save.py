"""Save generated media to the owner's configured download folder, without overwrites."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import time

EXTENSIONS = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.mp4', '.mov', '.webm'}
DEFAULT_DEST = '~/Library/Mobile Documents/com~apple~CloudDocs/Hermes_starter_user_V1/다운로드'
SCHEMA = {
    'name': 'media_save',
    'description': '소유자가 다운을 선택하면 이번에 MEDIA로 전달한 이미지·영상을 고정 다운로드 폴더에 저장한다. '
                   'paths에는 전달한 파일의 절대경로 1~10개만 넣는다. 기존 파일은 덮어쓰지 않는다. 예약·배경에서는 사용할 수 없다.',
    'parameters': {'type': 'object', 'properties': {
        'paths': {'type': 'array', 'items': {'type': 'string'}, 'minItems': 1, 'maxItems': 10},
    }, 'required': ['paths'], 'additionalProperties': False},
}


def config(td):
    cfg = td._PLUGIN_CONTEXT.get_config('media_save', {}) if td._PLUGIN_CONTEXT else {}
    return cfg if isinstance(cfg, dict) else {}


def problem(td, name='media_save', args=None):
    if name != 'media_save':
        return None
    from hermes_constants import get_hermes_home
    home = Path(get_hermes_home()).resolve()
    if (config(td).get('enabled') is not True or td.personal_roles.profile(td) != 'personal-secretary'
            or home.name != 'personal-secretary'):
        return 'MEDIA_SAVE_DISABLED'
    # Reuse the shell policy's cron/Kanban/oneshot/diagnosis/background-review checks.
    if not td.selected_skills.owner_chat(td):
        return 'MEDIA_SAVE_OWNER_SLACK_REQUIRED'
    try:
        owner = td.video_job._owner(home)
    except Exception:
        return 'MEDIA_SAVE_OWNER_SLACK_REQUIRED'
    if not owner or td.get_session_env('HERMES_SESSION_USER_ID', '') != owner:
        return 'MEDIA_SAVE_OWNER_SLACK_REQUIRED'
    return None


def offered(td):
    return {'media_save'} if problem(td) is None else set()


def _record(home, result):
    """Paths, byte counts and fixed error codes only; never log chat or file contents."""
    path = home / 'logs/tool-policy.jsonl'
    path.parent.mkdir(parents=True, exist_ok=True)
    row = dict(at=time.time(), reason='media_save', saved=result['saved'],
               errors=[e['error'] for e in result['errors']])
    with path.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with path.open('a') as stream:
            stream.write(json.dumps(row, ensure_ascii=False) + '\n')


def _copy(source, folder):
    # Exclusive creation also handles concurrent calls and dangling symlink collisions.
    number = 1
    while True:
        name = source.name if number == 1 else f'{source.stem} ({number}){source.suffix}'
        dest = folder / name
        try:
            fd = os.open(dest, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            number += 1
            continue
        os.close(fd)
        break
    try:
        size = source.stat().st_size
        shutil.copy2(source, dest)
        if dest.stat().st_size != size or source.stat().st_size != size:
            raise ValueError('MEDIA_SAVE_SIZE_MISMATCH')
        return dict(source=str(source), dest=str(dest), bytes=size)
    except Exception:
        dest.unlink(missing_ok=True)
        raise


def handle(td, args):
    result = {'saved': [], 'errors': []}
    if error := problem(td):
        result['errors'].append({'error': error})
        return json.dumps(result, ensure_ascii=False)
    paths = args.get('paths') if isinstance(args, dict) else None
    if (not isinstance(paths, list) or not 1 <= len(paths) <= 10
            or set(args) != {'paths'}):
        result['errors'].append({'error': 'MEDIA_SAVE_INVALID_ARGUMENTS'})
        return json.dumps(result, ensure_ascii=False)
    from hermes_constants import get_hermes_home
    home = Path(get_hermes_home()).resolve()
    roots = [home / 'cache/generated/images', home / 'workspace']
    dest_value = config(td).get('dest', DEFAULT_DEST)
    folder = Path(dest_value).expanduser() if isinstance(dest_value, str) and dest_value else None
    if folder is None or not folder.is_absolute() or not folder.is_dir():
        result['errors'].append({'error': 'MEDIA_SAVE_DEST_MISSING'})
        return json.dumps(result, ensure_ascii=False)
    folder = folder.resolve()
    for value in paths:
        error = None
        try:
            if not isinstance(value, str) or not Path(value).is_absolute():
                error = 'MEDIA_SAVE_ABSOLUTE_PATH_REQUIRED'
            else:
                source = Path(value).resolve(strict=True)
                if not any(source.is_relative_to(root) for root in roots):
                    error = 'MEDIA_SAVE_SOURCE_REFUSED'
                elif not source.is_file():
                    error = 'MEDIA_SAVE_FILE_REQUIRED'
                elif source.suffix.lower() not in EXTENSIONS:
                    error = 'MEDIA_SAVE_EXTENSION_REFUSED'
                else:
                    result['saved'].append(_copy(source, folder))
        except FileNotFoundError:
            error = 'MEDIA_SAVE_FILE_MISSING'
        except ValueError as exc:
            error = 'MEDIA_SAVE_SIZE_MISMATCH' if str(exc) == 'MEDIA_SAVE_SIZE_MISMATCH' else 'MEDIA_SAVE_SOURCE_REFUSED'
        except (OSError, RuntimeError):
            error = 'MEDIA_SAVE_COPY_FAILED'
        if error:
            result['errors'].append({'source': value if isinstance(value, str) else None, 'error': error})
    _record(home, result)
    return json.dumps(result, ensure_ascii=False)
