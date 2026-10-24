#!/usr/bin/env python3
"""Install or replace ddots, then remove its older copies. The public assistant-pet is a different app and is never touched."""
import argparse
import importlib.util
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
NAME = 'ddots.app'
EXECUTABLE = 'ddots'
BUNDLE_ID = 'io.github.hermes-ddots-p.ddots'


def info(app):
    try:
        with open(app / 'Contents/Info.plist', 'rb') as file:
            return plistlib.load(file)
    except Exception:
        return {}


def is_current(app):
    return app.is_dir() and not app.is_symlink() and info(app).get('CFBundleIdentifier') == BUNDLE_ID


def version(app):
    return info(app).get('CFBundleShortVersionString'), info(app).get('CFBundleVersion')


def binary(app):
    return app / 'Contents/MacOS' / EXECUTABLE


def outdated(folders, destination):
    """Other ddots copies and leftover recovery backups beside the app."""
    found = []
    backup = re.compile(re.escape(NAME) + r'\.bak-\d{8}-\d{6}-\d{6}$')
    for folder in folders:
        if not folder.is_dir():
            continue
        for item in sorted(folder.iterdir()):
            if (backup.fullmatch(item.name) or (item.name == NAME and item.resolve() != destination.resolve())) and is_current(item):
                found.append(item)
    return found


def ask(command, timeout=40):
    """Maintenance options answer and exit; a build that opens a window instead is stopped by the timeout."""
    try:
        return subprocess.run([str(part) for part in command], capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return None


def login_enabled(app):
    if app.suffix != '.app' or not binary(app).is_file():
        return False
    answer = ask([binary(app), '--login-status'])
    return answer is not None and 'login=enabled' in answer.stdout


def retire(app, tool):
    """Quit only what runs from this folder, drop its login item, then delete it. A copy that will not quit is left alone."""
    if app.suffix == '.app':
        # The new build does the quitting: the old one would quit every app sharing its identifier.
        quit_ = ask([tool, '--quit-app', app])
        if quit_ is None or quit_.returncode != 0:
            raise RuntimeError(f'실행 중인 이전 버전을 종료하지 못해 그대로 둡니다: {app}')
        if binary(app).is_file():
            ask([binary(app), '--disable-login'])
    shutil.rmtree(app)
    print(f'이전 버전 삭제: {app}')


def load_updater():
    spec = importlib.util.spec_from_file_location('update_installed', ROOT / 'scripts/update_installed.py')
    updater = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(updater)
    return updater


def check_signature(app):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def copy(source, destination):
    subprocess.run(['/usr/bin/ditto', '--norsrc', '--noextattr', '--noqtn', str(source), str(destination)], check=True)


def install(source, destination, folders, force=False):
    """Returns the older copies that could not be removed."""
    # Copies in these folders other than the destination count as older ones and are removed. With a destination
    # somewhere else, the real installation would be taken for one of them.
    if destination.parent.resolve() not in [folder.resolve() for folder in folders]:
        raise RuntimeError(f'응용 프로그램 폴더 안에만 설치합니다: {destination}')
    updater = load_updater()
    check_signature(source)
    if not is_current(source):
        raise RuntimeError(f'ddots 빌드가 아닙니다: {source}')
    old = outdated(folders, destination)
    existing = destination.exists() or destination.is_symlink()
    login = any(login_enabled(app) for app in old + ([destination] if existing else []))
    # The new version is in place and verified before anything older is deleted.
    if existing and not force and is_current(destination) and version(source) == version(destination):
        print('이미 최신 버전입니다: {} ({})'.format(*version(destination)))
    elif existing:
        shared = updater.stop_relay()
        try:
            updater.update(source, destination)
        finally:  # A failed update rolls back to the app that was there; its share comes back too.
            if shared:
                updater.start_relay(destination)
    else:
        try:
            updater.verify(source)
        except (RuntimeError, subprocess.CalledProcessError):
            print('주의: ddots Public Signing 서명이 아닙니다. 이후 버전 올리기는 bash scripts/setup-signing.sh 실행 후 다시 빌드해야 합니다.')
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            copy(source, destination)
            check_signature(destination)
        except Exception:
            shutil.rmtree(destination, ignore_errors=True)
            raise
    kept = []
    for app in old:
        try:
            retire(app, binary(destination))
        except (RuntimeError, OSError) as error:
            kept.append(app)
            print(f'이전 버전을 지우지 못했습니다: {app} ({error})', file=sys.stderr)
    if not existing:
        updater.launch(destination)
        print(f'설치 완료: {destination}')
    # Removing a copy can drop the login item of the same app; restore what the user had chosen.
    if login and not login_enabled(destination):
        ask([binary(destination), '--enable-login'])
        print('로그인 시 실행: ' + ('유지' if login_enabled(destination) else '다시 켜지 못했습니다. 옵션에서 확인해 주세요.'))
    return kept


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=Path.home() / 'Applications' / NAME)
    parser.add_argument('--source', type=Path, default=ROOT / 'dist' / NAME)
    parser.add_argument('--force', action='store_true', help='같은 버전이어도 다시 설치합니다.')
    args = parser.parse_args()
    try:
        kept = install(args.source, args.destination, [Path.home() / 'Applications', Path('/Applications')], args.force)
    except subprocess.CalledProcessError as error:
        sys.exit(f'설치 중단: {(error.stderr or "").strip() or error}')
    except RuntimeError as error:
        sys.exit(f'설치 중단: {error}')
    sys.exit(1 if kept else 0)


if __name__ == '__main__':
    main()
