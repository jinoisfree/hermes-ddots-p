# 일정 팩

일정 조회·쓰기·색 지정 함수는 호출별 `Services`로 계정·승인·캐시 위치를 받는다.
Google 계정 검증은 `google_calendar_accounts.py`, macOS 실행 소스는 두 EventKit
Swift 파일에 있다. `QUERY_SOURCE`·`MUTATION_SOURCE`는 이 팩의 소스를 가리킨다.
기존 native 바이너리 캐시·일정 식별자·토큰·되돌리기 장부 위치는 바꾸지 않는다.

소유자 대화의 생성 예외, 수정·삭제 승인과 개인/회사 계정 경계는 호스트가 그대로
적용한다. Zoom 알림과 연결 업무의 기존 배경 예외만 유지하며 일반 배경 쓰기를
허용하지 않는다. Zoom 감시도 같은 조회 소스를 쓰되 실행/중복 방지 상태는 자기
홈에 보존한다. EventKit은 macOS 전용이며 Google API 계정 연결과 구분한다.
