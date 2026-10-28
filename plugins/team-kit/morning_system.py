"""One owner DM for Doctor changes, new error kinds, queued night maintenance and the 03:00 새벽 작업.

2026-10-28 사용자 결정: 평일 08:30(휴일 11:00) private-service-27. 새벽 작업(night_batch)의 진단 판정·자동 수정을
싣고, 이 글이 새벽 Paseo 작업의 스레드가 된다(결과·확인·롤백 버튼은 스레드에). 보낸 뒤 새벽에 보류한
글(기억 정리 학습 채널 보고·공개판 플러그인 질문)을 원래 채널에 올린다.
"""
import argparse
from contextlib import ExitStack
from datetime import datetime
import importlib.util
import json
from pathlib import Path
from zoneinfo import ZoneInfo


def module(name):
    spec = importlib.util.spec_from_file_location('morning_' + name, Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


D, E, Q, R = (module(name) for name in ('doctor', 'error_digest', 'morning_queue', 'learning_report'))


def unreported(home):
    path = home / 'watcher-state/night-batch.json'
    if path.is_symlink():
        raise ValueError('symlink state')
    nights = (json.loads(path.read_text()) if path.exists() else {}).get('nights') or {}
    return [nights[k] for k in sorted(nights) if not nights[k].get('reported')]


def mark_reported(home, days):
    path = home / 'watcher-state/night-batch.json'
    if not days or not path.exists():
        return
    with Q.locked(path):
        data = json.loads(path.read_text())
        for day in days:
            if day in data.get('nights', {}):
                data['nights'][day]['reported'] = True
        Q.atomic_write(path, json.dumps(data, ensure_ascii=False, indent=1))


def after_report(home):
    """Quiet-hours posts go out now, each step on its own so one failure never blocks the rest."""
    try:
        Q.flush_held(home, lambda channel, text: R.slack(home, 'chat.postMessage', {
            'channel': channel, 'text': text, 'unfurl_links': False, 'unfurl_media': False}))
    except Exception as exc:
        print(f'held posts kept ({type(exc).__name__})')
    try:
        module('starter_plugins').flush(home)
    except Exception as exc:
        print(f'starter plugin posts kept ({type(exc).__name__})')
CHANNEL = 'REPLACE_SLACK_ID'
LOG = '~/.local/state/mini-maintenance/maintenance.log'


VERDICTS = {'night_done': '판정', 'normal': '정상·이미 해결', 'owner_needed': '소유자 확인 필요', 'failed': '판정 실패'}


def render_nights(nights):
    lines, bad = [], False
    for night in nights:
        rows = night.get('diagnoses') or []
        if rows or night.get('carried'):
            lines.append(f"*새벽 진단 · {night['day'][5:].replace('-', '/')} 03:00*")
        for row in rows:
            label = VERDICTS.get(row['status'], row['status'])
            bad = bad or row['status'] in ('owner_needed', 'failed') or bool(row.get('fix_key'))
            head = f"  • {row['who']} · {label}" + (f" · 결함 `{row['fix_key']}`" if row.get('fix_key') else '')
            # assistant verdicts include the owner's action within 300 chars; keep that final line.
            short = R.layout.excerpt(row.get('short') or '', 400 if row.get('source') == 'limit_report' else 220)
            lines.append(head + (f'\n    ↳ {short}' if short and row['status'] != 'normal' else ''))
        if night.get('carried'):
            lines.append(f"  • 이월 {night['carried']}건 — 다음 새벽에 처리")
        if night.get('job'):
            bad = True
            lines.append('*새벽 자동 수정*\n' + '\n'.join(f'  • {R.layout.excerpt(t, 90)}' for t in night.get('items') or [])
                         + f"\n  ↳ Paseo `{night['job']}` — 결과와 확인·롤백 버튼은 이 글의 스레드에 올린다. 푸시는 확인 뒤다.")
        if night.get('check_error'):
            lines.append(f"  • 새벽 점검 읽기 실패: `{night['check_error']}`")
        retention = night.get('retention')
        if retention:
            if retention.get('error'):
                lines.append(f"*지난 대화 보존 (월요일)*\n  • 확인 실패: `{retention['error']}`")
            elif retention.get('total'):
                rows = ', '.join(f'{name} {count}개' for name, count in retention['rows'])
                lines.append(f"*지난 대화 보존 (월요일)*\n  • 1년 지난 대화 {retention['total']}개 보존 중 — {rows}\n"
                             '  ↳ 지운 대화는 없다. 그대로 두면 계속 보존한다. 정리하려면 진단담당에게 말해 줘.')
    return lines, bad


def render(doctor, errors, notices, nights=()):
    broken, recovered = doctor['broken'], doctor['recovered']
    night_lines, night_bad = render_nights(nights)
    if not (broken or recovered or errors or notices or night_lines):
        return ''
    bad = any(row['level'] in ('warning', 'error', 'critical', 'fail') for row in notices) or night_bad
    color = '🔴' if broken or bad else '🟡' if errors else '🟢'
    lines = [f'*{color} 진단담당 아침 시스템 보고*']
    lines.extend(night_lines)
    if broken or recovered:
        lines.append('*매일 점검*')
        for label, rows in (('새 문제', broken), ('회복', recovered)):
            for row in rows:
                lines.append(f"  • {label} · `{row['id']}`: {row['detail']}")
    if errors:
        lines.append('*새 오류 요약*\n과거 기록이며 현재 장애 여부는 별도 확인이 필요하다.')
        ordered = sorted(errors.values(), key=lambda row: (-row['count'], row['first_at']))
        for row in ordered[:10]:
            title, _ = E.explain(row['summary'])
            level = {'WARNING': '경고', 'ERROR': '오류', 'CRITICAL': '심각한 오류'}[row['level']]
            first = datetime.fromtimestamp(row['first_at'], E.KST).strftime('%m/%d %H:%M')
            line = f"  • {title} · {level} · {row['count']}건 · 첫 발생 {first} KST"
            if title == '뜻을 더 확인해야 하는 새 기록':
                line += '\n    ↳ ' + R.layout.excerpt(E.normalize(row['summary']), 100)
            lines.append(line)
        if len(ordered) > 10:
            lines.append(f'  • 외 {len(ordered) - 10}종 · gateway.error.log에서 확인')
    if notices:
        lines.append('*새벽 정비*')
        # Repeated retries share one line; do not turn a backlog into dozens of DMs.
        groups = {}
        for row in notices:
            key = (row['level'], row['title'], row['body'])
            groups[key] = groups.get(key, 0) + 1
        for (_, title, body), count in list(groups.items())[:12]:
            suffix = f' ({count}회)' if count > 1 else ''
            lines.append(f'  • {R.layout.excerpt(title, 80)}{suffix}: {R.layout.excerpt(body, 180)}')
        if len(groups) > 12:
            lines.append(f'  • 외 {len(groups) - 12}종 · 아래 정비 로그에서 확인')
        lines.append(f'  ↳ 로그: `{LOG}`')
    return '\n\n'.join(lines)


def run(root, home, agents, document, *, dry_run=False, now=None):
    root, home = Path(root), Path(home)
    now = now or datetime.now(ZoneInfo('Asia/Seoul'))
    queue = home / 'watcher-state/morning-queue.jsonl'
    with ExitStack() as stack:
        if not dry_run:
            # Also serialize against a manual legacy Doctor execution.
            stack.enter_context(Q.locked(home / 'watcher-state/morning-system.json'))
            stack.enter_context(Q.locked(home / 'watcher-state/doctor.json'))
        doctor = D.prepare(root, home, agents, document, now=now)
        errors = E.prepare(root, home, now=now.timestamp())
        sent, notices = Q.snapshot(queue)
        nights = unreported(home)
        text = render(doctor, errors['new'], notices, nights)
        if dry_run:
            return text
        if text:
            # Preserve the old error digest's durable unacknowledged send intent.
            # Confirmed signatures and Doctor baseline stay untouched on failure.
            if errors['new']:
                E.stage_pending(errors)
            receipt = R.slack(home, 'chat.postMessage', {'channel': CHANNEL, 'text': text,
                              'unfurl_links': False, 'unfurl_media': False})
            if not (isinstance(receipt, dict) and receipt.get('ok') is True
                    and receipt.get('ts') and receipt.get('channel') == CHANNEL):
                raise ValueError('morning delivery unconfirmed')
            if any(night.get('job') for night in nights):
                module('paseo_autofix').attach_thread(home, CHANNEL, str(receipt['ts']))
        mark_reported(home, [night['day'] for night in nights])
        # Like the legacy readers, an empty report silently refreshes health/initial
        # error history; no undelivered changes are acknowledged on this branch.
        D.atomic_state(home / 'watcher-state/doctor.json', doctor['state'])
        E.acknowledge(errors)
        Q.acknowledge(queue, sent)
    after_report(home)
    return ''


def main(argv=None, *, root=None, home=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    root = Path(root) if root else Path.home() / '.hermes'
    home = Path(home) if home else root / 'profiles/system-doctor'
    try:
        text = run(root, home, Path.home() / 'Library/LaunchAgents',
                   Path.home() / 'workspace/Hermes-desktop-pet/백그라운드-작업-목록.md', dry_run=args.dry_run)
        if text:
            print(text)
    except Exception as exc:
        print(json.dumps({'wakeAgent': False, 'error': type(exc).__name__}))
        return 1
    print(json.dumps({'wakeAgent': False}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
