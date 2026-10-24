#!/bin/bash
# Pin both the release and archive digest; a normal build never follows "latest".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DEST="$ROOT/.build/sparkle-$VERSION"
if [ -f "$DEST/.verified-$SHA256" ]; then exit 0; fi
mkdir -p "$ROOT/.build"
STAGING=$(mktemp -d "$ROOT/.build/sparkle-download.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 120 --retry 2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
    -o "$STAGING/archive.tar.xz"
ACTUAL=$(shasum -a 256 "$STAGING/archive.tar.xz" | awk '{print $1}')
if [ "$ACTUAL" != "$SHA256" ]; then
    printf 'Sparkle 다운로드 지문이 일치하지 않습니다.\n' >&2
    exit 1
fi
mkdir "$STAGING/unpacked"
tar -xJf "$STAGING/archive.tar.xz" -C "$STAGING/unpacked"
codesign --verify --deep --strict "$STAGING/unpacked/Sparkle.framework"
touch "$STAGING/unpacked/.verified-$SHA256"
rm -rf "$DEST"
mv "$STAGING/unpacked" "$DEST"
