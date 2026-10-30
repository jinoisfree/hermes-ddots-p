"""Display-only tool tiers. Never change registry, execution scope or tool_search config."""
import copy
import json
import re
import sqlite3
import threading
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

PINNED = frozenset('team_work skill_view skills_list session_search memory team_learn team_learn_review team_skill_review skill_manage cronjob_manage tool_call tool_search tool_describe'.split())
# Unverified writes and mixed read/write tools stay direct.
READS = frozenset('contacts_direct_lookup search_files google_calendar_color_get notes_read file_location folder_scan table_analyze doc_read pdf_render doc_compare reminders_direct_lookup apple_notes_direct_lookup reminders_read calendar_read mail_read file_list knowledge_ref_get common_work_get report_status linked_work_read team_recall slack_history work_crosscheck'.split())
VERIFIED_WRITES = frozenset({'apple_notes_direct_mutation', 'reminders_direct_mutation', 'calendar_direct_mutation', 'file_copy', 'folder_create'})
FILE = 'learning/tool-tiers.json'
MAX_TABLE = 6000
_LOCK = threading.RLock()
_SESSIONS = {}  # Deliberately resets on gateway restart; never expires an active snapshot.


def settings(home):
    from ruamel.yaml import YAML
    p = Path(home) / 'config.yaml'
    data = YAML(typ='safe').load(p.read_text()) if p.exists() else {}
    cfg = (data or {}).get('plugins', {}).get('entries', {}).get('team-kit', {}).get('settings', {}).get('tool_tiers', {})
    return cfg if cfg.get('enabled') is True else {}


def fn(schema):
    return schema.get('function', schema)


def line(schema):
    f = fn(schema)
    name = f['name']
    required = ','.join(f.get('parameters', {}).get('required', [])) or '-'
    suffix = ' · 해당 작업 요청 시 · 필수:' + required
    room = 160 - len(name) - 3 - len(suffix)
    if room < 8:
        return None
    purpose = re.sub(r'\s+', ' ', f.get('description', '')).strip() or '조회'
    return name + ' · ' + purpose[:room] + suffix


def pins(schemas, configured=()):
    from tools.tool_search import is_deferrable_tool_name, load_config_readonly
    defer = load_config_readonly().effective_defer_tools
    return set(PINNED) | set(configured) | {
        fn(s)['name'] for s in schemas if fn(s)['name'] not in (READS | VERIFIED_WRITES)
        or line(s) is None or not is_deferrable_tool_name(fn(s)['name'], defer)}


def classify(names, prior, count14, count30, pinned):
    first = prior is None
    old = (prior or {}).get('classes', {})
    result = {}
    for n in sorted(names):
        if n in pinned:
            tier = 'frequent'
        elif first:
            tier = 'frequent' if count14.get(n, 0) >= 5 else 'rare'
        elif n not in old:
            tier = 'frequent'
        elif count14.get(n, 0) >= 5:
            tier = 'frequent'
        elif old[n] == 'frequent' and count30.get(n, 0) == 0:
            tier = 'rare'
        else:
            tier = old[n]
        result[n] = tier
    return result


def usage(home, now=None):
    now = time.time() if now is None else now
    c14, c30 = Counter(), Counter()
    with sqlite3.connect(f'file:{Path(home)/"state.db"}?mode=ro', uri=True) as db:
        cols = {x[1] for x in db.execute('pragma table_info(messages)')}
        # Core stores the unwrapped name in tool results. Legacy bridge records can
        # be matched to their assistant call id without counting the call twice.
        idcol = 'tool_call_id' if 'tool_call_id' in cols else None
        callscol = 'tool_calls' if 'tool_calls' in cols else None
        mapping = {}
        if callscol:
            for raw, in db.execute("select tool_calls from messages where role='assistant' and timestamp>=?", (now-30*86400,)):
                try:
                    for call in json.loads(raw or '[]'):
                        f = call.get('function', {})
                        if f.get('name') != 'tool_call': continue
                        args = json.loads(f.get('arguments') or '{}')
                        entries = args.get('calls') or [args]
                        if len(entries) == 1: mapping[call.get('id')] = entries[0].get('name')
                except (ValueError, TypeError, AttributeError):
                    continue
        query = 'select tool_name,timestamp,' + (idcol or 'NULL') + " from messages where role='tool' and timestamp>=?"
        for name, stamp, callid in db.execute(query, (now-30*86400,)):
            if name == 'tool_call': name = mapping.get(callid)
            if not name: continue
            c30[name] += 1
            if stamp >= now-14*86400: c14[name] += 1
    return c14, c30


def rebuild(home, schemas, now=None, *, force=False):
    cfg = settings(home)
    if not cfg: return None
    now = time.time() if now is None else now
    path = Path(home)/FILE
    prior = json.loads(path.read_text()) if path.exists() else None
    date = datetime.fromtimestamp(now).strftime('%Y-%m-%d')
    if prior and prior.get('date') == date and not force: return prior
    c14,c30 = usage(home, now)
    classes = classify({fn(s)['name'] for s in schemas}, prior, c14,c30, pins(schemas,cfg.get('pinned',[])))
    old = (prior or {}).get('classes',{})
    changes = [{'name':n,'from':old.get(n),'to':v} for n,v in classes.items() if old.get(n)!=v]
    result = {'date':date,'criteria':{'promote_days':14,'promote_count':5,'demote_days':30,'demote_count':0},'classes':classes,'changes':changes}
    path.parent.mkdir(parents=True,exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');tmp.replace(path)
    if changes: print(json.dumps({'profile':Path(home).name,'date':date,'changes':changes},ensure_ascii=False))
    return result


def request(home, payload, *, session_id='', **context):
    cfg = settings(home)
    if not cfg or not session_id or context.get('auxiliary') or context.get('aux_task'):
        return None
    path = Path(home)/FILE
    if not path.exists(): return None
    incoming = payload.get('tools')
    if not isinstance(incoming,list): return None
    current = {fn(s)['name']:s for s in incoming}
    key = (str(Path(home).resolve()),session_id)
    with _LOCK:
        if key not in _SESSIONS:
            data = json.loads(path.read_text())
            pinned = pins(incoming,cfg.get('pinned',[]))
            rare, rows, total = set(), {}, 0
            for n in sorted(current):
                row = line(current[n])
                if data['classes'].get(n)=='rare' and n not in pinned and row and total+len(row)+1<=MAX_TABLE:
                    rare.add(n);rows[n]=row;total+=len(row)+1
            _SESSIONS[key] = {'order':list(current),'rare':rare,'rows':rows,'allowed':set(current)}
        snap = _SESSIONS[key]
        # Revocation is monotone in a session. Never resurrect a filtered tool.
        snap['allowed'].intersection_update(current)
        allowed = snap['allowed']
        rare = snap['rare'] & allowed
        kept = [copy.deepcopy(current[n]) for n in snap['order'] if n in allowed and n not in rare]
        if rare:
            from tools.tool_search import bridge_tool_schemas
            bridge = next(s for s in bridge_tool_schemas(len(rare)) if fn(s)['name']=='tool_call')
            bridge['function']['description'] += ('\nUse the table directly without tool_search: tool_call(calls=[{name, arguments}]). '
                'Only pre-execution argument errors return parameters for correction. Never automatically retry an execution error or ambiguous result.\n'
                + '\n'.join(snap['rows'][n] for n in sorted(rare)))
            kept = [s for s in kept if fn(s)['name']!='tool_call'] + [bridge]
    result = dict(payload);result['tools']=kept
    return {'request':result,'source':'team-kit.tool_tiers','reason':'session-frozen display only'}


def validated_inventory(home, measured, expected=None):
    """Validate the *final* request, not prompt_probe's pre-final-filter inventory."""
    if not any(row.get('source') == 'team-delegation' for row in measured.trace):
        raise RuntimeError('Required team-delegation final filter did not complete')
    schemas = measured.payload.get('tools')
    if not isinstance(schemas, list) or not schemas:
        raise RuntimeError('Missing final tool inventory')
    names = [fn(s)['name'] for s in schemas]
    if len(set(names)) != len(names):
        raise RuntimeError('Duplicate tools in final inventory')
    if expected is None or set(names) != set(expected):
        raise RuntimeError('Final Slack inventory mismatch')
    return schemas


def strict_inventory(payload, callbacks, context):
    """Same request chain as core, but propagate every callback failure to the CLI."""
    current = copy.deepcopy(payload)
    trace = []
    for callback in callbacks:
        result = callback(request=copy.deepcopy(current), original_request=copy.deepcopy(payload), **context)
        if result is None:
            continue
        if isinstance(result, dict) and result.get('tool_tiers_error'):
            raise RuntimeError('Tool tiers display failed: '+result['tool_tiers_error'])
        if not isinstance(result, dict) or not isinstance(result.get('request'), dict):
            raise RuntimeError('Invalid request middleware result')
        current = result['request']
        trace.append({'source': result.get('source', ''), 'count': len(current.get('tools', []))})
    from types import SimpleNamespace
    return SimpleNamespace(payload=current, trace=trace)


def main():
    """One profile per process: registry/config state must not leak across profiles."""
    import os
    from ruamel.yaml import YAML
    import model_tools
    from hermes_cli.middleware import apply_llm_request_middleware
    home = Path(os.environ['HERMES_HOME'])
    config = YAML(typ='safe').load((home/'config.yaml').read_text())
    schemas = model_tools.get_tool_definitions(enabled_toolsets=config['platform_toolsets']['slack'],
        disabled_toolsets=config.get('agent',{}).get('disabled_toolsets'),quiet_mode=True,skip_tool_search_assembly=True)
    payload = {'tools':schemas,'messages':[{'role':'user','content':'Tool inventory measurement.'}]}
    from hermes_cli.plugins import _delivery_manager
    context = dict(provider='claude-subscription',platform='slack',session_id='',api_call_count=None,
                   middleware_schema_version='hermes.middleware.v1',telemetry_schema_version='hermes.observer.v1')
    strict = strict_inventory(payload, list(_delivery_manager()._middleware.get('llm_request', [])), context)
    measured = apply_llm_request_middleware(payload,provider='claude-subscription',platform='slack',session_id='')
    expected = [fn(s)['name'] for s in strict.payload['tools']]
    filtered = validated_inventory(home, measured, expected)
    if measured.payload['tools'] != strict.payload['tools']:
        raise RuntimeError('Final schema differs between strict and gateway chains')
    import sys
    if '--check' in sys.argv:
        print(json.dumps({'profile':home.name,'validated_count':len(filtered),'trace':strict.trace},ensure_ascii=False))
        return
    if '--measure' in sys.argv:
        import importlib.util
        spec = importlib.util.spec_from_file_location('tier_sizes',Path(__file__).with_name('prompt_probe.py'))
        probe = importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)
        displayed = request(home,{'tools':filtered},session_id='tier-size-measurement')['request']['tools']
        data = json.loads((home/FILE).read_text())
        print(json.dumps({'profile':home.name,'count':len(filtered),'pinned':sorted(pins(filtered,settings(home).get('pinned',[])) & set(data['classes'])),
            'frequent':sum(t=='frequent' for t in data['classes'].values()),'rare':sorted(n for n,t in data['classes'].items() if t=='rare'),
            'displayed_count':len(displayed),'before':probe.size(filtered),'after':probe.size(displayed)},ensure_ascii=False))
        return
    rebuild(home,filtered,force='--refresh' in sys.argv)



if __name__ == '__main__':
    main()
