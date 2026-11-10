"""Exact file inverses for the document pack; snapshots live only in app-undo."""
import base64
from contextvars import ContextVar
import hashlib
import json
import os
from pathlib import Path
import stat
import time
import uuid
from hermes_governance import app_undo, app_tools, write_policy

_EXPECTED = ContextVar('document_write_expected', default=None)
_MADE = ContextVar('document_created_directories', default=None)


def make_directories(path, *, exist_ok=True):
    path = Path(path)
    if path.is_symlink(): raise ValueError('APP_UNDO_SYMLINK')
    if not path.parent.is_dir(): make_directories(path.parent)
    try: path.mkdir()
    except FileExistsError:
        if not exist_ok or not path.is_dir(): raise
    else:
        if _MADE.get() is not None:
            info=path.stat(); _MADE.get().append({'path':str(path),'device':info.st_dev,'inode':info.st_ino})
WRITES = frozenset({'folder_create','file_move','file_copy','doc_edit','pdf_pages','doc_convert','doc_fill'})
MAX_SNAPSHOT = 100 * 1024 * 1024


def fingerprint(path):
    path = Path(path)
    if path.is_symlink(): return {'kind':'symlink','to':str(path.readlink())}
    if not path.exists(): return None
    if path.is_dir():
        return {'kind':'directory', 'entries':{str(p.relative_to(path)):fingerprint(p)
                for p in sorted(path.iterdir())}}
    if not path.is_file(): raise ValueError('APP_UNDO_FILE_TYPE')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024), b''): digest.update(chunk)
    return {'kind':'file','sha256':digest.hexdigest(),'size':path.stat().st_size,'mode':stat.S_IMODE(path.stat().st_mode)}


def snapshot(path):
    state = fingerprint(path)
    if state is None: return None
    if state['kind'] != 'file' or state['size'] > MAX_SNAPSHOT: raise ValueError('APP_UNDO_SNAPSHOT_LIMIT')
    data = Path(path).read_bytes()
    if hashlib.sha256(data).hexdigest() != state['sha256']: raise ValueError('APP_UNDO_CONCURRENT_CHANGE')
    return {'fingerprint':state, 'bytes':base64.b64encode(data).decode(), 'mode':stat.S_IMODE(Path(path).stat().st_mode)}


def assert_unchanged(path):
    expected = _EXPECTED.get()
    if expected is not None and str(path) in expected and fingerprint(path) != expected[str(path)]:
        raise ValueError('APP_UNDO_CONCURRENT_CHANGE')


def target_paths(files, config, tool, args):
    roots = files.folders(config)
    def target(value):
        path = files.inside(value, roots)
        if path is None: raise ValueError('APP_OUT_OF_SCOPE')
        if files._linked(path, roots): raise ValueError('APP_UNDO_SYMLINK')
        return str(path)
    if tool == 'file_move': return [(target(m['from']), target(m['to'])) for m in files._moves(args)]
    if tool == 'folder_create': return [target(args['path'])]
    if tool == 'doc_edit': return [target(args.get('save_as') or args['path'])]
    if tool == 'doc_fill': return [target(args['output_dir'])]
    return [target(args['to'])]


def execute(home, config, files, tool, args, handler, **context):
    """The dispatcher gate proves consent; scope is rechecked by this pack and its handler."""
    if tool not in WRITES or write_policy.classify(tool,args) == write_policy.READ:
        return handler(config,args,**context)
    if not write_policy.owner_chat(home,app_tools.env):
        return json.dumps({'ok':False,'error':'APP_OWNER_CHAT_REQUIRED'})
    try:
        if reason := files.problem(tool,args,files.folders(config)): raise ValueError(reason)
        with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home)) as (data,save):
            paths = target_paths(files,config,tool,args)
            before = {}; expected = {}
            if tool == 'file_move':
                for source,destination in paths:
                    expected[source] = fingerprint(source); expected[destination] = fingerprint(destination)
                    if expected[destination] is not None: raise ValueError('APP_UNDO_DESTINATION_EXISTS')
                inverse = {'moves':[]}
            elif tool == 'doc_fill':
                output = Path(paths[0])
                expected[paths[0]] = {'entries':{p.name:None for p in output.iterdir()}} if output.exists() else None
                inverse = {'files':{}}
            else:
                for path in paths:
                    before[path] = snapshot(path)
                    expected[path] = before[path]['fingerprint'] if before[path] else None
                inverse = {'files':before}
            entry = dict(key=uuid.uuid4().hex,created_at=time.time(),conversation=app_tools.conversation(),
                         journal_kind='files',tool=tool,target=paths,before=before,after={},inverse=inverse,status='pending',consumed=False)
            data['entries'].append(entry); save()  # prove durable storage before any write
            token = _EXPECTED.set(expected); created = []; made_token = _MADE.set(created)
            try:
                result = json.loads(handler(config,args,**context))
            except Exception:
                entry['status']='uncertain';entry['inverse']['directories']=list(created);save();raise
            finally:
                _EXPECTED.reset(token); _MADE.reset(made_token)
                entry['inverse']['directories'] = created
            if tool == 'file_move':
                for move in result.get('moved',[]):
                    pair = (move['from'],move['to'])
                    if pair not in paths: raise ValueError('APP_UNDO_RESULT_INVALID')
                    entry['after'][move['to']] = fingerprint(move['to'])
                    inverse['moves'].insert(0,{'from':move['to'],'to':move['from']})
            else:
                # A failed handler does not prove who created a destination that
                # appeared since preflight. Never offer to delete that file.
                affected = result.get('created',[]) if tool == 'doc_fill' else (paths if result.get('ok') is True else [])
                if not isinstance(affected,list): raise ValueError('APP_UNDO_RESULT_INVALID')
                for path in affected:
                    target_paths(files,config,'folder_create',{'path':path})
                    if tool == 'doc_fill':
                        parent = Path(paths[0]); rel = Path(path).relative_to(parent)
                        if len(rel.parts) != 1 or rel.name in (expected[paths[0]] or {}).get('entries',{}):
                            raise ValueError('APP_UNDO_RESULT_INVALID')
                        inverse['files'][path] = None
                    entry['after'][path] = fingerprint(path)
            entry['status']='done' if result.get('ok') else ('partial' if entry['after'] else 'uncertain');save()
            if entry['after']:
                summary = (f"양식을 채워 새 파일 {len(entry['after'])}개를 만들었어요. 누락 값이 있는 파일: {result.get('with_missing',0)}개."
                           if tool == 'doc_fill' else files.approval(tool,args,files.folders(config))['message'].removeprefix('승인하면 '))
                result.update(undo_key=entry['key'],message=write_policy.result_text(summary,entry['key']))
            return json.dumps(result,ensure_ascii=False)
    except (ValueError,OSError,KeyError,TypeError):
        return json.dumps({'ok':False,'error':'APP_UNDO_FILE_WRITE_FAILED','instruction':'자동으로 재시도하지 말고 실제 파일 상태를 확인하세요.'},ensure_ascii=False)


def restore(home, config, files, entry):
    """Restore only values that still equal this operation's after snapshot."""
    results = []
    for move in entry['inverse'].get('moves',[]):
        source,dest = move['from'],move['to']
        target_paths(files,config,'file_move',{'moves':[move]})
        if not Path(source).exists() and fingerprint(dest) == entry['after'][source]:
            results.append({'target':source,'status':'restored','already':True}); continue
        if fingerprint(source) != entry['after'][source] or Path(dest).exists():
            results.append({'target':source,'status':'skipped','reason':'UNDO_CONFLICT'}); continue
        files._move_exclusive(Path(source),Path(dest))
        results.append({'target':source,'status':'restored'})
    for name,before in reversed(list(entry['inverse'].get('files',{}).items())):
        target_paths(files,config,'folder_create',{'path':name})
        path=Path(name)
        observed=fingerprint(path)
        if observed == (before['fingerprint'] if before else None):
            results.append({'target':name,'status':'restored','already':True}); continue
        if observed != entry['after'].get(name):
            results.append({'target':name,'status':'skipped','reason':'UNDO_CONFLICT'}); continue
        if before is None:
            if path.is_dir(): path.rmdir()
            else: path.unlink(missing_ok=True)
        else:
            from hermes_facility.config_assembly import atomic_write
            atomic_write(path,base64.b64decode(before['bytes'],validate=True)); os.chmod(path,before['mode'])
        results.append({'target':name,'status':'restored'})
    if all(r['status']=='restored' for r in results):
        for directory in reversed(entry['inverse'].get('directories', [])):
            path=Path(directory['path'])
            target_paths(files,config,'folder_create',{'path':str(path)})
            if not path.exists(): continue
            info=path.stat()
            if info.st_dev == directory['device'] and info.st_ino == directory['inode']:
                try: path.rmdir()
                except OSError: pass  # Another file now uses this parent; preserve it.
    return {'ok':all(r['status']=='restored' for r in results),'results':results}
