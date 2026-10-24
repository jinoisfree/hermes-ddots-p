#!/bin/bash
# Fetch the latest main, build it apart from the running app, and install it in place of the previous version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PULL=1
FORCE=()
for argument in "$@"; do
    case "$argument" in
        --no-pull) PULL=0 ;;
        --force) FORCE=(--force) ;;
        *) printf '사용법: bash scripts/upgrade.sh [--no-pull] [--force]\n' >&2; exit 2 ;;
    esac
done
if [ "$PULL" = 1 ]; then
    if [ "$(git -C "$ROOT" branch --show-current)" != main ]; then
        printf 'main 브랜치에서 실행해 주세요.\n' >&2
        exit 1
    fi
    if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
        printf '커밋하지 않은 변경이 있어 받지 않습니다. 정리하거나 --no-pull로 지금 폴더를 그대로 설치하세요.\n' >&2
        exit 1
    fi
    git -C "$ROOT" pull --ff-only origin main
fi
BUILD="$ROOT/.build/update/ddots.app"
rm -rf "$BUILD"
DDOTS_BUILD_OUTPUT="$BUILD" bash "$ROOT/scripts/build.sh"
python3 "$ROOT/scripts/install.py" --source "$BUILD" ${FORCE[@]+"${FORCE[@]}"}
