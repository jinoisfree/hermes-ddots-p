#!/bin/bash
set -eu
STARTER_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ "${1:-}" = --prepare-runtime ]; then
  shift
  exec bash "$STARTER_DIR/prepare-runtime.sh" "$@"
fi
STARTER_HOME="${HERMES_HOME:-$HOME/.hermes}"
STARTER_EXPECT_HOME=false
for STARTER_ARG in "$@"; do
  if [ "$STARTER_EXPECT_HOME" = true ]; then STARTER_HOME="$STARTER_ARG"; STARTER_EXPECT_HOME=false
  elif [ "$STARTER_ARG" = --home ]; then STARTER_EXPECT_HOME=true
  elif [[ "$STARTER_ARG" == --home=* ]]; then STARTER_HOME="${STARTER_ARG#--home=}"
  fi
done
# The official installer owns Python; it need not publish python3 on PATH.
if [ -n "${HERMES_STARTER_PYTHON:-}" ]; then
  exec "$HERMES_STARTER_PYTHON" "$STARTER_DIR/install.py" "$@"
fi
for STARTER_PYTHON in "$STARTER_HOME"/tools/python-*/bin/python3; do
  if [ -x "$STARTER_PYTHON" ]; then exec "$STARTER_PYTHON" "$STARTER_DIR/install.py" "$@"; fi
done
if command -v python3 >/dev/null 2>&1; then exec python3 "$STARTER_DIR/install.py" "$@"; fi
printf '%s\n' 'Python이 없습니다. 먼저 bash install.sh --prepare-runtime --home <설치 홈>을 실행하세요.' >&2
exit 1
