# ddots

Hermes와 함께 쓰는 macOS 데스크톱 앱입니다. Apple Silicon, macOS 13 이상이 필요합니다.

## 설치 (권장)

1. 이 저장소의 Releases에서 최신 `ddots-<버전>-arm64.zip`을 내려받아 풀고 `ddots.app`을 응용 프로그램 폴더로 옮깁니다.
2. 처음 열 때 macOS가 확인되지 않은 개발자의 앱이라며 막습니다. 시스템 설정 → 개인정보 보호 및 보안에서 '그래도 열기'를 한 번 누릅니다. 자체 서명 앱이라 처음 한 번만 필요합니다.
3. 그 뒤 새 버전은 앱의 업데이트 버튼이나 쉬는 동안의 자동 설치로 받습니다. 공개 저장소의 서명된 릴리스와 update-feed를 확인하며 GitHub 토큰은 필요 없습니다. 브라우저로 새 ZIP을 직접 받아 바꾸면 확인 창이 다시 뜰 수 있습니다.

## 직접 빌드

Swift 빌드 도구(Xcode 명령줄 도구)가 필요합니다.

```sh
python3 -m venv .venv
.venv/bin/python3 -m pip install -r requirements-build.txt
bash scripts/setup-signing.sh 'ddots Public Signing'
bash scripts/build.sh
bash scripts/test.sh
```

직접 빌드한 앱은 그 Mac에서 만든 인증서로 서명되므로, 공식 릴리스의 자동 업데이트와 이어지지 않을 수 있습니다. 공식 업데이트를 받으려면 릴리스 앱을 설치하세요.

설치된 앱이나 개인 설정은 이 저장소에 저장하지 않습니다. 설정 방법은 docs/설정.md를 참고하세요.
