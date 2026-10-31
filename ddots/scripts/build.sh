#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANNEL="${DDOTS_BUILD_CHANNEL:-public}"
if [ "${1:-}" = "--channel" ] && [ "$#" = 2 ]; then CHANNEL="$2"; elif [ "$#" != 0 ]; then exit 2; fi
case "$CHANNEL" in private|public) ;; *) printf '알 수 없는 빌드 채널\n' >&2; exit 2;; esac
source "$ROOT/scripts/check_build_env.sh"
bash "$ROOT/scripts/fetch_sparkle.sh"
SPARKLE="$ROOT/.build/sparkle-2.10.0"
BUILD="$ROOT/.build"
STAGING=$(mktemp -d /private/tmp/ddots-build.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/ddots.app"
OUTPUT="${DDOTS_BUILD_OUTPUT:-$ROOT/dist/ddots.app}"
mkdir -p "$BUILD/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources/Pet" "$APP/Contents/Frameworks"
python3 "$ROOT/scripts/prepare_assets.py"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$BUILD/module-cache" -target arm64-apple-macosx13.0 -framework AppKit -framework SwiftUI -framework WebKit -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks "$ROOT"/Sources/*.swift -o "$BUILD/ddots"
cp "$BUILD/ddots" "$APP/Contents/MacOS/ddots"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
python3 "$ROOT/scripts/update_channel.py" "$APP/Contents/Info.plist" --channel "$CHANNEL"
cp "$ROOT/docs/slack-app-manifest.json" "$APP/Contents/Resources/"
python3 "$ROOT/scripts/build_info.py" "$APP/Contents/Resources/BuildInfo.json"
cp "$ROOT/Resources/Pet/"* "$APP/Contents/Resources/Pet/"
cp "$BUILD/assets/spritesheet.png" "$APP/Contents/Resources/Pet/"
cp "$ROOT/Resources/workspace.png" "$APP/Contents/Resources/"
cp "$ROOT/Resources/sns-manager-room.png" "$APP/Contents/Resources/"
cp "$ROOT/Resources/academy-room.png" "$APP/Contents/Resources/"
cp "$ROOT/Resources/report-room.png" "$APP/Contents/Resources/"
cp "$ROOT/Resources/secret-room.png" "$APP/Contents/Resources/"
cp "$ROOT/Resources/fried-shrimp.png" "$APP/Contents/Resources/"
cp "$BUILD/assets/ddots.icns" "$APP/Contents/Resources/ddots.icns"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
if [ -f "$ROOT/Resources/연결안내.html" ]; then cp "$ROOT/Resources/연결안내.html" "$APP/Contents/Resources/"; fi
IDENTITY="${DDOTS_SIGNING_IDENTITY:-}"
if [ "$CHANNEL" = public ]; then
    IDENTITY='ddots Public Signing'
    if ! security find-identity -p codesigning | grep -Fq "\"$IDENTITY\""; then
        printf '공개 코드 서명 정체성이 필요합니다.\n' >&2; exit 1
    fi
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -p codesigning | awk '/"ddots Public Signing"/ { print $2; exit }')
    if [ -z "$IDENTITY" ] && security find-certificate -c 'ddots Public Signing' >/dev/null 2>&1; then
        printf 'assistant-pet 인증서의 개인 키를 찾지 못했습니다. 로그인 키체인을 확인하세요.\n' >&2
        exit 1
    fi
    IDENTITY="${IDENTITY:--}"
fi
# Sign nested code from the inside out. Framework symlinks must survive packaging.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$IDENTITY" "$FRAMEWORK/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" "$FRAMEWORK/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" "$FRAMEWORK/Autoupdate"
codesign --force --sign "$IDENTITY" "$FRAMEWORK/Updater.app"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$(dirname "$OUTPUT")"
# ditto adds to a folder that is already there, so the copy is made beside the output and takes its place whole.
rm -rf "$OUTPUT.new"
ditto --norsrc --noextattr --noqtn "$APP" "$OUTPUT.new"
codesign --verify --deep --strict "$OUTPUT.new"
rm -rf "$OUTPUT"
mv "$OUTPUT.new" "$OUTPUT"
if [ "$IDENTITY" = "-" ]; then
    printf '주의: 임시 서명(ad-hoc)으로 빌드했습니다. 설치본 갱신과 키체인 권한 유지에는 bash scripts/setup-signing.sh 뒤 다시 빌드해야 합니다.\n' >&2
fi
printf '빌드·서명 검증 완료: %s (서명: %s)\n' "$OUTPUT" "$IDENTITY"
