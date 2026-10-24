#!/bin/bash
# One private signing key per ddots release channel. Only its public half is committed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/fetch_sparkle.sh"
KEYS="$ROOT/.build/sparkle-2.10.0/bin/generate_keys"
ACCOUNT=io.github.hermes-ddots-p.ddots.updates
"$KEYS" --account "$ACCOUNT"
PUBLIC_KEY=$("$KEYS" --account "$ACCOUNT" -p)
python3 - "$ROOT/Resources/Info.plist" "$PUBLIC_KEY" <<'PY'
import base64, pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
key = sys.argv[2].strip()
assert len(base64.b64decode(key, validate=True)) == 32, 'Invalid public key'
info = plistlib.loads(path.read_bytes())
old = info.get('SUPublicEDKey')
if old and old != key:
    raise SystemExit('기존 공개 키와 다릅니다. 키를 교체하지 않았습니다. 원래 서명 키를 복구하세요.')
if not old:
    text = path.read_text()
    path.write_text(text.replace('</dict></plist>', f'<key>SUPublicEDKey</key><string>{key}</string>\n</dict></plist>'))
print('ddots 업데이트 공개 키 확인 완료. 비밀 키는 키체인에만 보관됩니다.')
PY
