#!/usr/bin/env python3
"""Preview or create ddots hooks. Existing configuration is never overwritten."""
import argparse
import json
import os
from pathlib import Path
import shlex

def config(provider: str, executable: Path) -> dict:
    events = ['UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'Stop', 'SessionEnd']
    events += ['Notification', 'StopFailure'] if provider == 'claude' else ['Interrupt']
    command = f'{shlex.quote(str(executable))} --hook {provider}'
    hooks = {}
    for event in events:
        group = {'hooks': [{'type': 'command', 'command': command, 'timeout': 2}]}
        if event == 'Notification':
            group['matcher'] = 'permission_prompt|idle_prompt'
        hooks[event] = [group]
    return {'hooks': hooks}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    executable = args.app.resolve() / 'Contents/MacOS/ddots'
    if not executable.is_file():
        parser.error(f'앱 실행 파일 없음: {executable}')
    targets = [('codex', args.home / '.codex/hooks.json'), ('claude', args.home / '.claude/settings.json')]
    # Inspect every target first, so a known conflict cannot leave half an installation.
    for provider, path in targets:
        desired = config(provider, executable)
        if path.exists() or path.is_symlink():
            try: existing = json.loads(path.read_text())
            except Exception: existing = None
            if existing == desired and not path.is_symlink():
                print(f'이미 같은 설정: {path}')
                continue
            if args.apply:
                parser.error(f'기존 설정 보존을 위해 중단: {path}. 기존 내용과 추가 항목을 검토한 뒤 별도로 병합해야 합니다.')
        print(json.dumps({'provider': provider, 'path': str(path), 'create_only': True, 'config': desired}, ensure_ascii=False, indent=2))
    if args.apply:
        for provider, path in targets:
            if path.exists():
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            data = (json.dumps(config(provider, executable), ensure_ascii=False, indent=2) + '\n').encode()
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as handle:
                handle.write(data)
            print(f'생성 완료: {path}')
        print('Codex 공식 훅은 /hooks에서 신뢰 검토가 필요합니다. 기존 작업을 중단하거나 재시작하지 않습니다.')

if __name__ == '__main__':
    main()
