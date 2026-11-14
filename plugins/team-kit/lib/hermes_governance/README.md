# 공통 승인·실행 정책

`runtime`은 실행 예산, `approval`은 기존 승인/쓰기 경계, `browser`는 주소·화면·
브라우저 동작 경계, `owner_context`는 직책·소유자 문맥과 기존 정책 안내를 맡는다.
모든 함수는 호출별 `Services`를 받고 승인 사전·잠금·현재 플러그인 문맥을 전역에
보관하지 않는다. 상태의 소유자는 원래 호스트다. `contracts`는 도구 스키마와
정책 문구를 원래 평가 순서로 호스트마다 새로 만든다. 권한·문구를 수정하지 않는다.

기존 공개 함수/훅 이름과 정책 등록은 team-delegation의 얇은 연결이 유지한다.
팩을 끈다고 공통 승인 정책을 우회할 수 없다. 이 라이브러리는 별도 도구 팩이 아니다.

`proposal_decisions`는 배경 작업이 올린 제안의 버튼 판정을 맡는다. 제안은 직원 사물함 `state/proposals.json`
장부에 `posting → pending → applying → applied | rejected | held | refused | failed`로 남고(대체되면 `superseded`),
`pre_gateway_dispatch` 훅이 누른 사람·채널·스레드·만료·상태를 확인한 뒤 플러그인이 등록한 실행기를 부른다.
배경 작업은 `post`로 올리기만 하며 실행기를 직접 부르지 않는다. 의견 버튼은 장부를 바꾸지 않고 일반 대화로 넘긴다.
