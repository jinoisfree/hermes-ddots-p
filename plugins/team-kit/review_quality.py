"""Shared review contract; no model calls, writes, or automatic retries."""
POLICY = """[개선 판단 기준]
관찰 사실·원인 추정·미확인을 구분하고 각 주장에 실제 출처를 붙인다. 정상 동작·이미 해결됨 등 반대 근거도 확인한다.
파일이 없다는 이유만으로 결함이라 하지 말고 생성될 출력인지 확인한다. 오류 이름·경고 개선과 원인 수정·업무 복구는 별개다.
원래 사용자 문제, 이번 수정 범위, 완료 조건, 남는 문제를 먼저 고정한다. 실행 중 범위가 줄면 부분 해결로 보고한다.
구조 개선은 실제 운영 부담과 기대 효과·유지 비용·회귀 위험을 비교한다. 단순 중복·파일 크기만으로 개편하지 않는다.
최소 수정은 줄 수가 아니라 원인을 해결하는 데 필요한 가장 작은 부담이다. 중요한 단발 결함도 증거가 있으면 수정한다.
근거 부족은 정상·이미 해결됨의 증거가 아니다. 영향이 큰 미확인 문제에는 원인을 가를 다음 읽기 검사와 재개 조건을 남긴다.
추가 조사 판정만으로 미확인 원인의 코드나 로깅을 고치라고 지시하지 않는다. 계측 추가는 기존 읽기로 부족한 이유·범위·비용을 확인한 별도 제안이다.
검사 통과는 업무 복구의 증거가 아니다. 최종 변경 코드·재현 결과·실행 로그를 직접 대조하고 확인 범위 밖 성과를 말하지 않는다.
제안 0건도 정상이다. 미해결 문제는 확인·푸시만으로 종결하지 않고, 새 증거 없이 같은 수정 작업을 반복 생성하지 않는다.
"""

ANALYSIS_FIELDS = ('problem', 'scope', 'criterion', 'counterevidence', 'remaining', 'next_check')
RESULT_FIELDS = ('scope', 'evidence', 'remaining', 'next_check')
STATUSES = ('완료', '부분 해결', '검증 대기', '보류', '실패')


def text_fields(row, fields, required=()):
    return all(isinstance(row.get(k), str) and len(row[k]) <= 600
               and (k not in required or row[k].strip()) for k in fields)


def followups(jobs):
    """Derived from retained job results, independent of push/confirmation state.

    No fresh task is enqueued here. A later evidenced, complete result may explicitly
    resolve a reference; a rolled-back result never closes it.
    """
    closed = set()
    for job in jobs.values():
        if job.get('status') not in ('reported', 'confirmed', 'confirming'):
            continue
        result = job.get('result') or {}
        if result.get('schema_version') != 2:
            continue
        for row in result.get('items', []):
            if row.get('status') == '완료' and row.get('outcome') == 'resolved' and row.get('evidence'):
                closed.update(row.get('resolves', []))
    rows = []
    for key, job in jobs.items():
        result = job.get('result') or {}
        analyses = {r['n']: r for r in (job.get('analysis') or [])}
        results = {r['n']: r for r in result.get('items', [])}
        for n in sorted(set(analyses) | set(results)):
            row = results.get(n, analyses.get(n, {}))
            ref = f'{key}:{n}'
            if ref in closed or not (row.get('remaining') or row.get('next_check')):
                continue
            rows.append({'ref': ref, 'problem': analyses.get(n, {}).get('problem', ''),
                         'status': row.get('status', row.get('decision', '보류')),
                         'remaining': row.get('remaining', ''), 'next_check': row.get('next_check', ''),
                         'job_status': job.get('status', '')})
    return rows
