#!/usr/bin/env python3
"""Update the installed pet, rolling back on failure and removing recovery copies after success."""
import argparse
from datetime import datetime
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = Path.home() / 'Applications/ddots.app'
IDENTITY = 'ddots Public Signing'
BACKUPS = Path.home() / 'Library/Application Support/ddots/backups'


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def verify(path, channel="private"):
    from update_channel import policy
    _, expected_bundle, expected_identity = policy(channel)
    if path.is_symlink() or not path.is_dir():
        raise RuntimeError('앱 경로가 폴더가 아니거나 심볼릭 링크입니다.')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(path))
    signature = run('/usr/bin/codesign', '-d', '--verbose=4', str(path))
    details = signature.stdout + signature.stderr
    if 'Signature=adhoc\n' in details:
        raise RuntimeError('임시 서명 빌드로는 설치본을 갱신하지 않습니다. bash scripts/setup-signing.sh를 한 번 실행한 뒤 다시 빌드해 주세요.')
    if f'Authority={expected_identity}\n' not in details or f'Identifier={expected_bundle}\n' not in details:
        raise RuntimeError('ddots Public Signing 서명 또는 번들 ID가 일치하지 않습니다.')


def stop(source, destination):
    # Other copies, including a pet running from dist, belong to the user.
    run(str(source / 'Contents/MacOS/ddots'), '--quit-app', str(destination))


def launch(path):
    run('/usr/bin/open', '-n', '-a', str(path))


def backup_folder(destination):
    """Recovery copies of the real install stay out of the Applications folder, where they look like old versions."""
    return BACKUPS if destination == DESTINATION.expanduser().absolute() else destination.parent


def prune(destination):
    pattern = re.compile(re.escape(destination.name) + r'\.bak-\d{8}-\d{6}-\d{6}$')
    for old in backup_folder(destination).iterdir():
        if pattern.fullmatch(old.name) and old.is_dir() and not old.is_symlink():
            shutil.rmtree(old)


def update(source, destination=DESTINATION):
    source = source.expanduser().absolute()
    destination = destination.expanduser().absolute()
    if source.resolve() == destination.resolve():
        raise RuntimeError('빌드 산출물과 설치 경로가 같습니다.')
    verify(source)  # Nothing changes unless the new build has the expected signature.
    if destination.is_symlink() or not destination.is_dir():
        raise RuntimeError('설치본이 없습니다. 먼저 scripts/install.py를 실행해 주세요.')
    # Preserve even a damaged old app for recovery; never delete the existing installation.
    folder = backup_folder(destination)
    folder.mkdir(parents=True, exist_ok=True)
    backup = folder / (destination.name + '.bak-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    stop(source, destination)  # Native NSRunningApplication.terminate(), 15-second wait, no forced kill.
    moved = False
    try:
        destination.rename(backup)
        moved = True
        run('/usr/bin/ditto', '--norsrc', '--noextattr', '--noqtn', str(source), str(destination))
        verify(destination)
        launch(destination)
    except BaseException:  # An interrupt in the middle of the copy must not leave half an app and no pet either.
        if moved:
            # open may have started the new app even if a later launch error was returned.
            # If it refuses to quit, retain both copies rather than overwrite a running app.
            stop(source, destination)
            if destination.exists():
                shutil.rmtree(destination)
            backup.rename(destination)
        # The pet was quit before anything was moved; the installation that is there is started again.
        if destination.is_dir():
            launch(destination)
        raise
    # Backup cleanup cannot trigger rollback after a successful launch.
    try:
        prune(destination)
    except OSError as error:
        print(f'갱신 완료, 이전 백업 정리 생략: {type(error).__name__}')
    print(f'설치본 갱신 완료: {destination}')


RELAY = 'io.github.hermes-ddots-p.ddots.relay'


def stop_relay():
    """A running share keeps the old binary open, and launchd holds on to what it knew of that binary:
    restarted in place, the new one was killed once for its signature and came back only ten seconds later.
    So the share is taken down before the app is replaced. Returns whether it was on."""
    service = f'gui/{os.getuid()}/{RELAY}'
    if subprocess.run(['/bin/launchctl', 'print', service], capture_output=True).returncode != 0:
        return False
    subprocess.run(['/bin/launchctl', 'bootout', service], capture_output=True)
    return True


def start_relay(destination=DESTINATION):
    """Registers the share again from the app now installed, which also writes its launch item anew."""
    started = subprocess.run([str(destination / 'Contents/MacOS/ddots'), '--relay-enable'], capture_output=True)
    if started.returncode != 0:
        # An app that cannot do it (a rollback to a damaged copy, say) still gets its old launch item back.
        item = Path.home() / f'Library/LaunchAgents/{RELAY}.plist'
        started = subprocess.run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', str(item)], capture_output=True)
    print('대화 공유 항목 재시작' if started.returncode == 0 else '대화 공유 항목을 다시 켜지 못했습니다. 메뉴의 "다른 Mac과 대화 공유…"에서 켜 주세요.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'dist/ddots.app')
    args = parser.parse_args()
    shared = stop_relay()
    try:
        update(args.source)
    finally:  # A failed update rolls back to the app that was there; its share comes back too.
        if shared:
            start_relay()


if __name__ == '__main__':
    main()
