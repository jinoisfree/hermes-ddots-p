"""One-off company work classification. Default is a read-only preview; never schedules itself."""
from pathlib import Path
import argparse
import importlib.util
import json
import sqlite3


def preview(path):
    with sqlite3.connect(Path(path).resolve().as_uri()+'?mode=ro', uri=True) as conn:
        conn.row_factory = sqlite3.Row
        columns = {r[1] for r in conn.execute('PRAGMA table_info(common_work)')}
        rows = conn.execute("SELECT common_id,title FROM common_work" +
                            (' WHERE scope_set_at IS NULL' if 'scope_set_at' in columns else '') +
                            ' ORDER BY created_at,common_id').fetchall()
        eligible=[]
        for row in rows:
            sources=conn.execute('SELECT source_id,metadata_json FROM source_links WHERE common_id=?',(row['common_id'],)).fetchall()
            owners=[json.loads(s['metadata_json']).get('owner_scope') for s in sources]
            notion=conn.execute("SELECT 1 FROM knowledge_refs WHERE common_id=? AND ref_type='notion_page' AND unlinked_at IS NULL",(row['common_id'],)).fetchone()
            if 'personal' in owners:continue
            if 'company' in owners or any(s['source_id'].startswith('obsidian:') for s in sources) or notion:eligible.append(row)
        return [{'common_id': r['common_id'], 'title': r['title'],
                 'scope': 'shared' if conn.execute("SELECT 1 FROM knowledge_refs WHERE common_id=? AND ref_type='notion_page' AND unlinked_at IS NULL", (r['common_id'],)).fetchone() else 'private'}
                for r in eligible]


def apply(path, rows):
    from common_work_links import CommonWorkStore
    store = CommonWorkStore(path)
    with store._connect() as conn:
        conn.execute('BEGIN IMMEDIATE')
        # Recheck the preview under lock. A concurrent link/transition requires another preview.
        for row in rows:
            current = conn.execute('SELECT scope_set_at FROM common_work WHERE common_id=?', (row['common_id'],)).fetchone()
            notion = conn.execute("SELECT 1 FROM knowledge_refs WHERE common_id=? AND ref_type='notion_page' AND unlinked_at IS NULL", (row['common_id'],)).fetchone()
            if not current or current['scope_set_at'] is not None or row['scope'] != ('shared' if notion else 'private'):
                raise ValueError('backfill_preview_changed')
        import time
        for row in rows:
            conn.execute('UPDATE common_work SET scope=?,scope_set_at=? WHERE common_id=?', (row['scope'],time.time(),row['common_id']))
            store._event(conn,row['common_id'],'scope_backfilled',row)


def report(home, rows):
    """At most one send attempt. A timeout is uncertain and must not be replayed automatically."""
    # learning_report.slack routes every report through slack_blocks.
    import work_content as content
    with content.ledger(home, 'work-scope-backfill-report') as (path,state):
        if state.get('report'):
            return state['report']
        state['report'] = {'status':'pending', 'rows':rows}
        content.save(path,state)
        spec = importlib.util.spec_from_file_location('_scope_learning_report', Path(home)/'plugins/team-kit/learning_report.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        lines = ['*🟢 업무 등급 분류 완료*', '', '*기존 업무*']
        lines += [f"• {r['title']} — {'공용(lv2)' if r['scope']=='shared' else '개인(lv1)'}" for r in rows]
        try:
            result = module.slack(home,'chat.postMessage',{'channel':'REPLACE_SLACK_ID','text':'\n'.join(lines)})
            if not result.get('ok'):
                raise RuntimeError('backfill_report_unverified')
            state['report'].update(status='sent',ts=result['ts'])
        except Exception:
            state['report']['status']='uncertain'
            content.save(path,state)
            raise
        content.save(path,state)
        return state['report']


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--db',type=Path,default=Path.home()/'.hermes/shared/common-work-links.sqlite3')
    p.add_argument('--home',type=Path,default=Path.home()/'.hermes/profiles/work-assistant')
    p.add_argument('--dry-run',action='store_true')
    p.add_argument('--apply',action='store_true')
    p.add_argument('--report',action='store_true')
    args=p.parse_args()
    if args.dry_run and args.apply:p.error('choose dry-run or apply')
    if args.report and not args.apply:p.error('--report requires --apply')
    rows=preview(args.db)
    output={'dry_run':not args.apply,'private':sum(r['scope']=='private' for r in rows),
            'shared':sum(r['scope']=='shared' for r in rows),'rows':rows}
    if args.apply:
        apply(args.db,rows)
        if args.report:output['report']=report(args.home,rows)
    print(json.dumps(output,ensure_ascii=False,indent=2))


if __name__=='__main__':main()
