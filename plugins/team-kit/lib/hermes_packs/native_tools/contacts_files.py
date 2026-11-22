"""Contact exports and recovery files, confined to the current employee's configured file reach."""
from __future__ import annotations

import json
import os
from pathlib import Path
import importlib.util as _ilu, pathlib as _pl, sys as _sys
from hermes_facility import team_registry as team


def roots() -> list[Path]:
    import hermes_yaml
    from hermes_constants import get_hermes_home
    from hermes_facility import app_registry
    home=Path(get_hermes_home())
    config = home / 'config.yaml'
    data = hermes_yaml.safe_load(config.read_text())
    settings = data.get('plugins',{}).get('entries',{}).get('team-kit',{}).get('settings',{}).get('files',{})
    root=app_registry.root_of(home);profile=app_registry.profile_of(home)
    if app_registry.explicit(root,profile):
        settings=app_registry.derived_settings(data,app_registry.grants(root,profile,data),app_registry.values(root,profile))['team-kit']['files']
    if settings.get('enabled') is not True:
        raise ValueError('file tools disabled')
    # The same enabled, existing, absolute folders as team-kit.files.folders.
    return [p.resolve(strict=True) for item in settings.get('folders', [])
            if (p := Path(str(item)).expanduser()).is_absolute() and p.is_dir()]


def export_folder(value) -> Path:
    """The existing folder the employee chose for an export: absolute, inside the file reach, no symbolic link."""
    if not isinstance(value, str) or not value or '\x00' in value or not os.path.isabs(value):
        raise ValueError('folder must be an absolute path')
    path = Path(value)
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError('folder path contains a symbolic link')
    if not path.is_dir():
        raise ValueError('folder does not exist')
    resolved = path.resolve(strict=True)
    if not any(resolved.is_relative_to(root) for root in roots()):
        raise ValueError('folder outside configured roots')
    return resolved


def backup_folder() -> Path:
    """The employee home's pre-delete backup shelf; it does not depend on the file reach."""
    from hermes_constants import get_hermes_home
    shelf = Path(get_hermes_home()) / 'backups'
    folder = shelf / 'contacts'
    for step in (shelf, folder):
        if step.is_symlink():
            raise ValueError('backup folder is a symbolic link')
        if not step.exists():
            step.mkdir(mode=0o700)
            step.chmod(0o700)
        if not step.is_dir():
            raise ValueError('backup folder is not a directory')
    if folder.stat().st_uid != os.getuid():
        raise ValueError('backup folder is owned by another user')
    folder.chmod(0o700)
    return folder.resolve(strict=True)


def filename(value: str, extension: str) -> str:
    # User supplied names never become paths. Reject instead of silently dropping traversal.
    if not value or value in {'.', '..'} or any(c in value for c in '/\\\x00'):
        raise ValueError('invalid file name')
    stem = value.removesuffix(extension).strip()[:160]
    if not stem or stem in {'.', '..'}:
        raise ValueError('invalid file name')
    return stem + extension


def write_unique(folder: Path, name: str, data: bytes) -> Path:
    """O_EXCL + O_NOFOLLOW prevents overwriting existing files, including dangling links."""
    for index in range(10000):
        initial = Path(name)
        path = folder / (name if index == 0 else f'{initial.stem}_{index}{initial.suffix}')
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            continue
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        except BaseException:
            path.unlink(missing_ok=True)
            raise
        return path
    raise ValueError('too many filename collisions')


def import_path(value: str) -> Path:
    path = Path(value).expanduser().resolve(strict=True)
    if not path.is_file() or path.suffix.lower() != '.vcf' or not any(path.is_relative_to(r) for r in roots()):
        raise ValueError('input outside configured roots or not a vCard')
    if not 0 < path.stat().st_size <= 5 * 1024 * 1024:
        raise ValueError('vCard must be between 1 byte and 5 MiB')
    return path


def group_backup(group: dict) -> bytes:
    return json.dumps({'identifier': group['identifier'], 'name': group['name'],
                       'member_ids': sorted(group['member_ids'])}, ensure_ascii=False, indent=2).encode()
