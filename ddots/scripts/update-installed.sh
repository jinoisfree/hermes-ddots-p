#!/bin/bash
# Always replaces the installed app, even with the same version. install.py and upgrade.sh skip an unchanged version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/update_installed.py" "$@"
