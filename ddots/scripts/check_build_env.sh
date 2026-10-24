#!/bin/bash
# Sourced before compiling. Reuse the project's environment without installing or changing anything.
ddots_check_build_env() {
    local project_root="$1"
    if ! xcrun --find swiftc >/dev/null 2>&1; then
        printf 'Swift 빌드 도구가 없습니다. xcode-select --install로 명령행 도구를 설치해 주세요.\n' >&2
        return 1
    fi
    local pillow_check='from PIL import Image; import PIL; assert PIL.__version__ == "11.3.0"'
    if ! python3 -c "$pillow_check" >/dev/null 2>&1; then
        if "$project_root/.venv/bin/python3" -c "$pillow_check" >/dev/null 2>&1; then
            export PATH="$project_root/.venv/bin:$PATH"
        else
            printf '빌드에 Python 3와 Pillow 11.3.0이 필요합니다. 프로젝트 폴더에서 다음 명령을 실행해 주세요:\npython3 -m venv .venv\n.venv/bin/python3 -m pip install -r requirements-build.txt\n' >&2
            return 1
        fi
    fi
}
ddots_check_build_env "$ROOT" || exit 1
unset -f ddots_check_build_env
