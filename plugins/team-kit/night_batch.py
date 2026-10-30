"""진단담당 03:00 새벽 작업 (2026-10-28 사용자 결정). Slack에는 아무것도 보내지 않는다.

  1. 낮에 기록만 해 둔 진단 요청(SNS담당·업무비서·개인비서, ``deferred: night``)을 오래된 순으로 최대 5건 판정한다.
     남은 요청은 다음 새벽으로 넘기고 아침 보고에 이월로 적는다.
  2. 매일 점검 변화와 지난 24시간 새 오류를 읽는다(상태 저장 없음, 기준은 08:30 보고가 확정).
  3. 확정된 진단 결함과 점검·오류 확인을 한 Paseo 작업(``night-<날짜>``)으로 묻지 않고 넘긴다.
     Paseo는 표식 커밋까지만 하고 푸시는 아침 보고 스레드의 확인 버튼 뒤다.
  4. 어제 조직개편안을 보내지 않고 만들어 Paseo에 바로 넘긴다(2026-10-29 사용자 결정, ``org_review.night``).
     08:30 조직개편안 보고가 그 스레드에 결과와 확인·롤백 버튼을 받는다.
  5. 월요일에는 지난 대화 보존 현황을 센다(본문을 읽거나 지우지 않는다).

결과는 ``watcher-state/night-batch.json``에 남고 08:30 ``morning_system``이 private-service-27으로 보고한다.
수동 확인: ``--dry-run`` (판정·Paseo·상태 저장 없음).
"""
import argparse
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import sys
import time
from zoneinfo import ZoneInfo

KST = ZoneInfo('Asia/Seoul')
NIGHT_LIMIT = 5
NAMES = {'sns-manager': 'SNS담당', 'work-assistant': '업무비서', 'personal-secretary': '개인비서'}


def module(name, path=None):
    spec = importlib.util.spec_from_file_location('night_' + name, path or Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def state_path(home):
    return Path(home) / 'watcher-state/night-batch.json'


def load(home):
    path = state_path(home)
    if path.is_symlink():
        raise ValueError('symlink state')
    data = json.loads(path.read_text()) if path.exists() else {}
    return {'nights': {}, **data}


def save(home, state, Q):
    path = state_path(home)
    # Keep two weeks; the morning report only reads unreported nights.
    keep = sorted(state['nights'])[-14:]
    state['nights'] = {k: state['nights'][k] for k in keep}
    Q.atomic_write(path, json.dumps(state, ensure_ascii=False, indent=1))


def pending_requests(DR):
    rows = [r for r in DR.saved_requests() if r.get('status') == 'pending' and r.get('deferred') == 'night']
    return sorted(rows, key=lambda r: r['created_at'])


def summary(r):
    status = r.get('status')
    return {'id': r['id'], 'who': NAMES.get(r.get('requester_profile'), '조직원'), 'kind': r.get('kind', ''),
            'source': r.get('source', ''),
            'status': status, 'short': str(r.get('short_verdict') or '')[:400], 'fix_key': r.get('fix_key') or '',
            'error': r.get('error', ''), 'created_at': r.get('created_at')}


def system_item(text):
    return {
        'title': '새벽 점검: 매일 점검 변화·지난 24시간 새 오류 확인',
        'profiles': ['system-doctor'],
        'evidence': text[:3000],
        'proposal': '점검·오류 기록에서 프로그램 결함으로 확인되는 것만 최소 수정한다.',
        'effect': '같은 오류·점검 실패가 다시 나지 않게 한다.',
        'rollback': '이 작업의 표식 커밋을 롤백 버튼으로 되돌린다.',
        'instruction': ('목표: 진단담당 새벽 점검의 매일 점검 변화와 지난 24시간 새 오류 중 프로그램 결함을 찾아 고친다. '
                        '근거: 위 evidence, ~/.hermes/logs/gateway.error.log, ~/.hermes/profiles/system-doctor/watcher-state/doctor.json, '
                        '~/.local/state/mini-maintenance/maintenance.log. 기록으로 재현·확인된 결함만 최소 수정하고 회귀 테스트를 더한다. '
                        '일시적인 네트워크·외부 서비스 오류, 이미 고쳐진 것, 원인이 불명확한 것은 보류하고 이유를 적는다. '
                        '자격 파일 값·로그 원문의 개인정보는 코드·커밋·결과에 옮기지 않는다. '
                        'AGENTS.md를 먼저 읽고 실행 원본 수정 후 ./sync, 관련 docs 갱신, 게이트웨이 Python 테스트, 필요 시 재시작 규칙을 따른다.'),
    }


def retention(root):
    script = Path(root) / 'profiles/system-doctor/scripts/session_retention_check.py'
    rows = module('retention', script).collect(Path(root), 365, time.time())
    total = sum(row[1] for row in rows)
    return {'total': total, 'rows': [[name, count] for name, count, *_ in rows if count]}


def run(root, home, agents, document, *, dry_run=False, now=None):
    root, home = Path(root), Path(home)
    now = now or datetime.now(KST)
    day = now.date().isoformat()
    Q, D, E, MS = module('morning_queue'), module('doctor'), module('error_digest'), module('morning_system')
    DR, A = module('diagnosis_requests'), module('paseo_autofix')
    lock = Q.locked(state_path(home)) if not dry_run else None
    if lock:
        lock.__enter__()
    try:
        state = load(home)
        if day in state['nights'] and not dry_run:
            return state['nights'][day]  # one 새벽 작업 a day; a relaunch never re-runs diagnoses
        requests = pending_requests(DR)
        todo, carried = requests[:NIGHT_LIMIT], requests[NIGHT_LIMIT:]
        results = []
        for r in todo:
            if dry_run:
                results.append({**summary(r), 'status': 'would_run'})
                continue
            try:
                done = DR.run(r['id'], night=True)
            except Exception as exc:
                done = {**r, 'status': 'failed', 'error': type(exc).__name__}
            results.append(summary(done))
        try:
            doctor = D.prepare(root, home, agents, document, now=now)
            errors = E.prepare(root, home, now=now.timestamp())
            checked = MS.render(doctor, errors['new'], []) if (doctor['broken'] or errors['new']) else ''
            check_error = ''
        except Exception as exc:  # the diagnoses above are already done; keep them
            checked, check_error = '', type(exc).__name__
        defects = [row for row in results if row['status'] == 'night_done' and row['fix_key']]
        items = [A.incident_item(DR.read(row['id']), row['fix_key'], str(DR.path(row['id'])), [])
                 for row in defects]
        if checked:
            items.append(system_item(checked))
        key = 'night-' + day
        queued = None
        if items and not dry_run:
            queued = A.enqueue_night(home, key, items, [row['id'] for row in defects])
        night = {'day': day, 'at': now.isoformat(), 'diagnoses': results, 'carried': len(carried),
                 'job': key if queued in ('queued', 'duplicate') else None,
                 'items': [i['title'] for i in items], 'check_error': check_error, 'reported': False}
        if not dry_run:
            # 2026-10-29 사용자 결정: 조직개편안도 새벽에 만들어 Paseo가 진행하고, 아침 보고에 확인·롤백만 묻는다.
            try:
                night['org_review'] = module('org_review').night(home=home, root=root, now=now)
            except Exception as exc:  # 08:30 daily tries the draft once more
                night['org_review'] = 'failed:' + type(exc).__name__
        if now.weekday() == 0:
            try:
                night['retention'] = retention(root)
            except Exception as exc:
                night['retention'] = {'error': type(exc).__name__}
        if not dry_run:
            state['nights'][day] = night
            save(home, state, Q)
        return night
    finally:
        if lock:
            lock.__exit__(None, None, None)


def main(argv=None, *, root=None, home=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    try:
        import dotenv  # noqa: F401
    except ImportError:
        import hermes_bootstrap  # noqa: F401  launchd's base Python -> the installed environment
    root = Path(root) if root else Path.home() / '.hermes'
    home = Path(home) if home else root / 'profiles/system-doctor'
    try:
        night = run(root, home, Path.home() / 'Library/LaunchAgents',
                    Path.home() / 'workspace/Hermes-desktop-pet/백그라운드-작업-목록.md', dry_run=args.dry_run)
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': type(exc).__name__}), flush=True)
        return 1
    print(json.dumps({'ok': True, **night}, ensure_ascii=False), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
