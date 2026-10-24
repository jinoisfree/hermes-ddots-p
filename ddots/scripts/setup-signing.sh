#!/bin/bash
# One local identity, reused across builds. Private material only exists in a private temporary directory and Keychain.
set -euo pipefail
IDENTITY="${1:-ddots Public Signing}"
if [[ ! "$IDENTITY" =~ ^[A-Za-z0-9\ ._-]+$ ]] || [ "$#" -gt 1 ]; then
    printf '유효한 서명 이름 하나를 지정하세요.\n' >&2; exit 1
fi
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -p codesigning "$KEYCHAIN" | /usr/bin/grep -Fq "\"$IDENTITY\""; then
    printf '기존 서명 인증서를 유지합니다: %s\n' "$IDENTITY"
    exit 0
fi
umask 077
SIGNING_TEMP=$(mktemp -d /private/tmp/ddots-signing.XXXXXX)
trap 'rm -rf "$SIGNING_TEMP"' EXIT
cat > "$SIGNING_TEMP/certificate.conf" <<CONF
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = $IDENTITY
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF
if security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$SIGNING_TEMP/cert.pem" 2>/dev/null; then
    printf '인증서는 있지만 개인 키를 찾지 못했습니다. 로그인 키체인을 확인하세요.\n' >&2
    exit 1
else
    openssl rand -base64 32 > "$SIGNING_TEMP/password"
    openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 -sha256 \
        -config "$SIGNING_TEMP/certificate.conf" -keyout "$SIGNING_TEMP/key.pem" -out "$SIGNING_TEMP/cert.pem" 2>/dev/null
    # macOS Keychain does not import the default PBES2 container from OpenSSL 3.
    # Only this short-lived, random-password transport uses legacy container encryption.
    openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -name "$IDENTITY" -inkey "$SIGNING_TEMP/key.pem" -in "$SIGNING_TEMP/cert.pem" \
        -out "$SIGNING_TEMP/identity.p12" -passout "file:$SIGNING_TEMP/password"
    security import "$SIGNING_TEMP/identity.p12" -k "$KEYCHAIN" -P "$(cat "$SIGNING_TEMP/password")" -T /usr/bin/codesign >/dev/null
fi
# A local designated requirement pins the leaf certificate; no system trust override is needed.
if security find-identity -p codesigning "$KEYCHAIN" | /usr/bin/grep -Fq "\"$IDENTITY\""; then
    printf '서명 정체성 확인: %s\n' "$IDENTITY"
else
    printf '서명 정체성을 확인하지 못했습니다.\n' >&2; exit 1
fi
