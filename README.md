# Hermes 직원 설치 도우미

공개 Hermes에 필요한 직원과 도구를 연결하는 한국어 설치 도우미입니다.
개인 계정·기억·대화·회사 자료는 포함하지 않습니다.

| slug | 표시 이름 | 특징 | 필요한 서비스 |
|---|---|---|---|
| llm-wiki | LLM 위키 | 근거를 모아 재사용할 지식으로 정리 | Slack, 모델 제공자, 위키 저장소(선택) |
| personal-secretary | 개인비서 | 개인 일정·메일과 AI 아이디어를 정리 | Slack, 모델 제공자, 개인 메일·일정(선택) |
| sns-manager | SNS 담당 | SNS 초안과 소식을 살피는 담당 | Slack, 모델 제공자, SNS 계정(선택) |
| system-doctor | 시스템 관리·진단 | 읽기 전용 점검으로 오류 원인을 좁힘 | Slack, 모델 제공자, 로컬 진단 도구(선택) |
| work-assistant | 회사업무 담당 | 업무 자료·마감·회신 대기를 한데 정리 | Slack, 모델 제공자, 회사 메일·일정(선택), Notion(선택) |

1. 아래 실행 기반 준비·점검을 마치고 `hermes setup`에서 사용할 모델을 연결합니다.
2. 이 폴더에서 `bash install.sh`를 실행합니다. 직원 번호와 필요한 도구 팩을 고르면 됩니다.
3. 설치 도우미가 안내하는 Slack 앱을 직원별로 만듭니다. 각 직원 폴더의
   `slack-manifest.json`을 사용하고 Socket Mode 앱 토큰과 Bot User OAuth 토큰을 준비합니다.
4. `bash install.sh --agents <고른 직원들> --connect-slack`으로 연결합니다.
   토큰 입력은 화면에 표시되지 않습니다. 기본 채널은 이름 대신 Slack의 `is_general`로 찾고,
   같은 워크스페이스인지 확인한 뒤 참여·저장을 묻습니다. 메시지는 보내지 않습니다.
5. `hermes gateway start`로 시작한 뒤 Slack 기본 채널에서 질문해 보세요.
   선택이 필요한 답변에는 승인·거절·의견·확인 버튼을 쓸 수 있습니다.
   의견을 누른 뒤 같은 스레드에 지시를 적고, 다른 직원은 멘션해서 부릅니다.

처음 설치하는 홈에는 다음 명령으로 본체·Python·CLI를 먼저 준비합니다. Python이 아직 없어도
시작할 수 있으며, [공식 Hermes 설치기](https://hermes-agent.nousresearch.com/docs/getting-started/installation)에
실제 설치를 위임합니다. 이 명령은 모델 로그인이나 게이트웨이 시작을 하지 않습니다.

```sh
bash install.sh --prepare-runtime --home "$HOME/.hermes"
export PATH="$HOME/.local/bin:$PATH"
bash install.sh --check-runtime --home "$HOME/.hermes"
```

기존 본체가 있으면 준비 명령을 다시 실행하지 말고 `--check-runtime`으로 먼저 확인합니다.
준비 명령은 기존 본체·홈 링크를 자동 교체하지 않습니다. 기존 홈을 옮기면 그 안의
본체·Python·실행 경로도 영향을 받으므로, 이동이나 전환 전에 별도 홈에서 실행 기반과
기존 기능 보존을 검증하세요. `--home`을 지정한 경우 뒤의 모든 명령에도 같은 값을 사용합니다.
관리 Python을 찾을 수 없을 때는 `HERMES_STARTER_PYTHON`에 확인된 Python 실행 경로를 지정할 수 있습니다.
공식 설치기는 계정의 공통 CLI도 등록하므로, 기존 `hermes`·`hermes-acp` 명령이 있으면
준비 명령은 중단합니다. 기존 운영을 종료하고 새 본체로 CLI까지 전환하기로 정한 경우에만
`--prepare-runtime --replace-cli`를 사용하세요. 기존 환경을 유지하는 별도 홈 시험에는 쓰지 않습니다.

```sh
# 설치 전 미리 보기: 파일과 Slack을 바꾸지 않습니다.
bash install.sh --agents work-assistant,personal-secretary --packs files-docs,notion --dry-run

# 설치 및 선택한 직원의 Slack 연결
bash install.sh --agents work-assistant,personal-secretary --packs files-docs,notion --connect-slack

# 설치 도우미가 관리하는 코드·파일 연결만 확인
bash install.sh --check

# 실제 본체·Python·CLI 실행 확인
bash install.sh --check-runtime
```

업무 비서를 고르면 멘션 없는 새 질문의 기본 담당이 됩니다. 다른 기본 직원을 원하면
처음 설치할 때 `--default <직원>`으로 정합니다. 기존 기본 직원은 옮기지 않습니다.
설치 홈을 바꾸려면 `--home <폴더>`를 더하고 그 홈으로 Hermes를 실행하세요.
직원을 추가할 때 기존 금고·이름·설정 값은 유지하고 없는 항목만 더합니다.

도구 팩은 파일·문서, Notion, 메일, 일정, 메모, 연결 업무, 진단, SNS, 맥 기본 도구로 나뉩니다.
필요한 계정과 접근 권한을 설치 화면에서 안내합니다. 맥 전용 팩은 다른 운영체제에서 제외합니다.
팩을 골라도 계정 확인·허용 폴더·대화 승인 검사는 유지됩니다. 자동 DM·게시·감시·보고 예약은
설치기가 켜지 않습니다. 기존 사용자 파일은 새 템플릿으로 바꾸지 않습니다.

업데이트는 진행 중인 대화·예약을 마친 뒤 게이트웨이를 중지하고 새 배포 폴더에서 실행합니다.

```sh
hermes gateway stop
bash install.sh --update --dry-run
bash install.sh --update
bash install.sh --check
hermes gateway start
```

업데이트 대상은 설치 기록에 있는 코드뿐입니다. 금고, 토큰, USER.md·MEMORY.md, 학습·스킬,
대화, 예약·운영 장부를 보존합니다. 직접 고친 코드나 알 수 없는 파일이 있으면 덮어쓰지 않고
중단합니다. 코드 원본은 한 창고에 두고 직원별 연결을 사용합니다.

Slack·계정 연결은 사용자의 환경에서 확인해야 합니다. 본체 확장점이 달라져 버튼 연결이
지원되지 않으면 선택지를 글로 보냅니다. 실제 첫 응답·버튼·업데이트 확인 전에는 설치가
완료됐다고 보지 마세요. 공개 앱의 배포·업데이트는 별도 안내를 따릅니다.

`quiet-logs`는 기존 로그 필터와 함께 Slack의 홈 채널 미설정 안내만 생략합니다.
현재 언어의 `gateway.notify.no_home_channel` 번역에 `platform=Slack`,
`sethome_cmd=/hermes sethome`을 넣은 결과와 전체 문구가 정확히 같을 때만 적용합니다.
다른 안내·다른 플랫폼·추가 내용이 있는 글은 그대로 전달하며 홈 채널 설정은 바꾸지 않습니다.

Google 계정 연결용 안내: [Hermes Gmail](gmail/index.html) · [개인정보처리방침](gmail/privacy.html).

## ddots 앱

이 저장소의 ddots/에 앱 소스와 빌드·검사 스크립트를 포함합니다. 앱 빌드와 업데이트 안내는 ddots/README.md를 참고하세요. 공개 앱 릴리스는 소스 자동 갱신과 별도로 승인 후 게시합니다.
