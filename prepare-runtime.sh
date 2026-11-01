#!/bin/bash
# Explicit opt-in only. The official installer owns the core, Python and CLI.
set -eu
STARTER_HOME="${HERMES_HOME:-$HOME/.hermes}"
STARTER_REPLACE_CLI=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf '%s\n' '--home에 경로가 필요합니다.' >&2; exit 2; }
      STARTER_HOME="$2"; shift 2 ;;
    --home=*) STARTER_HOME="${1#--home=}"; shift ;;
    --replace-cli) STARTER_REPLACE_CLI=true; shift ;;
    *) printf '%s\n' '실행 기반 준비에는 --home <경로>와 필요한 경우 --replace-cli만 지정하세요.' >&2; exit 2 ;;
  esac
done
case "$STARTER_HOME" in
  /*) ;;
  *) printf '%s\n' '--home에는 절대 경로를 사용하세요.' >&2; exit 2 ;;
esac
if [ -L "$STARTER_HOME" ] || [ -e "$STARTER_HOME/hermes-agent" ] || [ -L "$STARTER_HOME/hermes-agent" ]; then
  printf '%s\n' '기존 홈 링크·본체를 자동 교체하지 않습니다. 기존 설치를 점검하거나 새 홈을 지정하세요.' >&2
  exit 1
fi
if [ "$STARTER_REPLACE_CLI" = false ]; then
  for STARTER_COMMAND in hermes hermes-acp; do
    if [ -e "$HOME/.local/bin/$STARTER_COMMAND" ] || [ -L "$HOME/.local/bin/$STARTER_COMMAND" ]; then
      printf '%s\n' '기존 계정 CLI를 보존하고 중단합니다. 새 본체로 명령을 전환하려는 경우에만 --replace-cli를 추가하세요.' >&2
      exit 1
    fi
  done
fi
command -v curl >/dev/null 2>&1 || { printf '%s\n' '공식 설치기를 받으려면 curl이 필요합니다.' >&2; exit 1; }
STARTER_TEMP=$(mktemp -d)
trap 'rm -rf "$STARTER_TEMP"' EXIT
curl --fail --silent --show-error --location \
  'https://hermes-agent.nousresearch.com/install.sh' -o "$STARTER_TEMP/install.sh"
HERMES_HOME="$STARTER_HOME" HERMES_INSTALL_DIR="$STARTER_HOME/hermes-agent" \
  bash "$STARTER_TEMP/install.sh" --hermes-home "$STARTER_HOME" \
  --dir "$STARTER_HOME/hermes-agent" --non-interactive
printf '%s\n' '공식 설치기 실행을 마쳤습니다. 이어서 같은 --home으로 bash install.sh --check-runtime을 실행하세요.'
