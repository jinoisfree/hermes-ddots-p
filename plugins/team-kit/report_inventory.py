"""Read-only report inventory. No imports of runners, network, credential reads or writes."""
import argparse
from datetime import datetime, timedelta
import json
from pathlib import Path
import plistlib
import re
from zoneinfo import ZoneInfo

KST = ZoneInfo('Asia/Seoul')

def read(path):
    return json.loads(path.read_text())

def home_for(root, profile):
    return root if profile == 'default' else root / 'profiles' / profile

def delivery(home, row, now):
    """Only durable delivery evidence counts. Cron ok is never a delivery receipt."""
    if not row.get('state'):
        return '개별 기록 확인 필요'
    path = home / row['state']
    if not path.exists():
        return '전달 기록 없음'
    data = read(path)
    reports = data.get('reports')
    if reports is not None:
        if not reports:
            return '전달 기록 없음'
        key = max(reports)
        report = reports[key]
    else:
        report = data; key = report.get('day', '')
    parts = report.get('parts') or []
    sent = sum(bool(p.get('ts')) for p in parts)
    if report.get('outcome') == 'skipped_empty' and report.get('complete'):
        return key + ' 정상 생략(0건)'
    if report.get('complete') and sent and sent == len(parts):
        return key + ' 전달 확인'
    if sent:
        return key + f' 일부 전달({sent}/{len(parts)})'
    if any(p.get('attempted_at') for p in parts):
        return key + ' 전달 확인 불가(조회 후 복구)'
    return key + ' 생성됨·전달 대기'

def config_scalar(path, key):
    """Read only plain scalar mapping paths used by the catalog, without YAML dependencies.

    Unsupported syntax is reported as a mismatch, never silently treated as configured.
    """
    stack=[]
    for line in path.read_text().splitlines():
        match=re.match(r'^( *)([A-Za-z0-9_-]+):(?: +([^#]*))?',line)
        if not match:continue
        depth=len(match[1])
        while stack and stack[-1][0]>=depth:stack.pop()
        stack.append((depth,match[2]))
        if '.'.join(x[1] for x in stack)==key:
            value=(match[3] or '').strip().strip('"\'')
            return {'true':True,'false':False}.get(value,value)
    return None


def inspect(root, agents, *, now=None, catalog=None):
    root, agents = Path(root), Path(agents)
    now = now or datetime.now(KST)
    catalog = catalog or read(Path(__file__).with_name('report_catalog.json'))
    output=[]; issues=[]; known=set()
    for row in catalog['reports']:
        home=home_for(root,row['profile']); entry=dict(row)
        try:
            if row.get('job'):
                known.add((row['profile'],row['job']))
                jobs=read(home/'cron/jobs.json')['jobs']
                job=next((j for j in jobs if j['id']==row['job']),None)
                if job is None: issues.append(row['id']+': 예약 없음')
                else:
                    entry['run_status']=job.get('last_status') or '실행 기록 없음'
                    entry['last_run_at']=job.get('last_run_at')
                    if 'expected_deliver' in row and job.get('deliver')!=row['expected_deliver']:
                        issues.append(row['id']+': 예약 전달 위치 불일치')
                    if bool(job.get('enabled'))!=row['enabled']:issues.append(row['id']+': 활성 상태 불일치')
                    if job.get('schedule')!=row['expected_schedule']:issues.append(row['id']+': 예약 시각 불일치')
                    if (job.get('script') or '')!=row['script']:issues.append(row['id']+': 실행 경로 불일치')
            if row.get('launch'):
                p=agents/(row['launch']+'.plist')
                if not p.exists():issues.append(row['id']+': launchd 파일 없음')
                else:
                    d=plistlib.loads(p.read_bytes())
                    if d.get('Disabled'):issues.append(row['id']+': launchd 비활성')
                    if any(d.get(k)!=v for k,v in row.get('expected_launch',{}).items()):issues.append(row['id']+': launchd 시각 불일치')
            for key, expected in row.get('config_checks', {}).items():
                if config_scalar(home/'config.yaml',key)!=expected:
                    issues.append(row['id']+': 실제 설정 불일치 ('+key.rsplit('.',1)[-1]+')')
            entry['delivery']=delivery(home,row,now)
            if row.get('required'):
                # Before today's report, yesterday's delivery should cover the day before yesterday.
                previous=(now.date()-timedelta(days=2)).isoformat()
                path=home/row['state']
                if path.exists():
                    store=read(path)
                    data=store.get('reports',{})
                    report=data.get(previous)
                    if report is None and store.get('start_date', previous) <= previous:
                        issues.append(row['id']+': 지난 보고 기록 없음')
                    if report is not None and not report.get('complete'):
                        issues.append(row['id']+': 지난 보고 전달 미완료')
            if '일부 전달' in entry['delivery'] or '전달 확인 불가' in entry['delivery']:
                issues.append(row['id']+': '+entry['delivery'])
        except (OSError,ValueError,KeyError,TypeError):
            entry['delivery']='점검 실패(원문 생략)';issues.append(row['id']+': 설정·기록 읽기 실패')
        output.append(entry)
    for p in root.glob('profiles/*/cron/jobs.json'):
        try:
            for job in read(p)['jobs']:
                if (p.parent.parent.name,job['id']) not in known and not job.get('name','').startswith('wait-'):
                    issues.append(p.parent.parent.name+': 목록에 없는 예약 '+job['id'])
        except (OSError,ValueError,KeyError,TypeError):issues.append(p.parent.parent.name+': 예약 읽기 실패')
    return {'checked_at':now.isoformat(),'reports':output,'issues':issues,
            'limits':'로컬 설정·저장된 전달 영수증 점검. Slack 실시간 도착·launchd 등록 여부는 별도 확인.'}

def markdown(result):
    lines=['| 담당 | 보고 | 종류 | 발송 시각·조건 | 전달 위치 | 최근 전달 근거 |', '|---|---|---|---|---|---|']
    for row in result['reports']:
        values=[row[k] for k in ['owner','title','kind','send','channel','delivery']]
        lines.append('| '+' | '.join(str(v).replace('|','/').replace('\n',' ') for v in values)+' |')
    lines += ['','점검: '+('이상 없음' if not result['issues'] else '; '.join(result['issues'])),result['limits']]
    return '\n'.join(lines)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path.home()/'.hermes')
    parser.add_argument('--agents',type=Path,default=Path.home()/'Library/LaunchAgents')
    parser.add_argument('--json',action='store_true');parser.add_argument('--check',action='store_true')
    args=parser.parse_args();result=inspect(args.root,args.agents)
    print(json.dumps(result,ensure_ascii=False,indent=2) if args.json else markdown(result))
    return int(bool(result['issues'])) if args.check else 0

if __name__=='__main__':raise SystemExit(main())
