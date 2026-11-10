"""Single-note writes use the same private app ledger as multi-tool work bundles."""
import json
from pathlib import Path
import subprocess
import time
import uuid
from hermes_facility import app_registry, app_scope
from hermes_governance import app_tools, app_undo, write_policy

LIMITATION='메모 앱이 서식을 다시 정리해서 자동으로 똑같이 되돌릴 수는 없어요'

def snapshot(td, identifier, context):
    value=td._note_snapshot(identifier,context.get('runner') or subprocess.run)
    if not value: raise ValueError('APP_UNDO_SNAPSHOT_UNAVAILABLE')
    metadata=td.personal_scopes.native_metadata(td,'notes',{'note_id':identifier},context)
    folder=metadata.get('current')
    if not isinstance(folder,dict) or not folder.get('id'): raise ValueError('APP_SCOPE_UNVERIFIED')
    return dict(value,folder=folder)


def binding(home, source):
    explicit=app_registry.explicit(app_registry.root_of(home),app_registry.profile_of(home))
    return app_scope.bind(home,source=source if explicit else None)


def execute(home, td, args, next_call, context):
    if args.get('action') not in ('create','update','move'):return next_call(args)
    if not write_policy.owner_chat(home,app_tools.env): return td._error('APP_OWNER_CHAT_REQUIRED',mutation_calls=0)
    attempted=False
    try:
        with binding(home,args.get('source')):
            # The old ownership rule and the selected app containers both run before snapshot content is read.
            if td.personal_scopes.config(td) is not None:
                checked=td.personal_scopes.authorize_mutation(td,'notes',args,context)
            else: checked=app_scope.mutation(td,'notes',args,context) or dict(args)
            source='obsidian' if td.obsidian_notes.selected(td) else 'apple_notes'
            kind=write_policy.classify('apple_notes_direct_mutation',args,state={'source':source})
            backup_only=kind!=write_policy.REVERSIBLE
            if backup_only and not app_tools.authorized('apple_notes_direct_mutation',args):
                return json.dumps(dict(ok=False,approval_required=True,mutation_calls=0,
                    error='APP_APPROVAL_REQUIRED',message=LIMITATION+'\n승인하면 수정합니다.\n[[버튼: 승인 | 거절]]'),ensure_ascii=False)
            with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home)) as (data,save):
                before=snapshot(td,args['note_id'],context) if args.get('action')!='create' else None
                if '_bundle_before' in context and before!=context['_bundle_before']:raise ValueError('APP_UNDO_BEFORE_CHANGED')
                inverse=({'action':'delete','note_id':None} if before is None else
                    {'action':'move','note_id':args['note_id'],'folder':'id:'+before['folder']['id']} if source=='apple_notes' and args['action']=='move' else
                    {'action':'restore','note_id':args['note_id'],'title':before['title'],'body_html':before['body_html']})
                entry=dict(key=uuid.uuid4().hex,created_at=time.time(),conversation=app_tools.conversation(),
                    journal_kind='memo_backup' if backup_only else 'memo',tool='apple_notes_direct_mutation',target=args.get('note_id'),
                    source=source,before=before,after=None,inverse=None if backup_only else inverse,status='pending',consumed=False)
                if backup_only:entry['limitation']=LIMITATION;entry['reference_only']=True
                data['entries'].append(entry);save()
                try:
                    attempted=True
                    result=json.loads(next_call(dict(checked,approved=True)))
                    if result.get('ok') is not True:
                        entry['status']='uncertain';save();return json.dumps(result,ensure_ascii=False)
                    identifier=result.get('target_id') or result.get('result',{}).get('note_id')
                    if not identifier: raise ValueError('APP_UNDO_TARGET_UNVERIFIED')
                    inverse=None if backup_only else dict(inverse,note_id=identifier)
                    entry.update(target=identifier,inverse=inverse);save()
                    after=snapshot(td,identifier,context)
                    entry.update(target=identifier,after=after,inverse=inverse,status='done');save()
                except Exception:
                    entry['status']='uncertain';save();raise
                if backup_only:
                    result.pop('undo_key',None)
                    result.update(message='메모 변경을 저장했어요.\n'+LIMITATION,rollback_limitations=LIMITATION)
                else:result.update(undo_key=entry['key'],message=write_policy.result_text('메모 변경을 저장했어요.',entry['key']))
                return json.dumps(result,ensure_ascii=False)
    except Exception as error:
        return td._error(str(error) if isinstance(error,ValueError) else 'APP_UNDO_MEMO_FAILED',reflection_unknown=attempted,mutation_calls=None if attempted else 0)


def restore(home,td,entry,context=None):
    context=context or {}
    if entry.get('reference_only'):raise ValueError('APP_UNDO_NOT_REVERSIBLE')
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    if app_registry.tool_granted(home,'apple_notes_direct_mutation') is False:raise ValueError('APP_NOT_CONNECTED')
    def cleanup():
        from hermes_governance import app_results
        return app_results.unlink_created(td,'notes',entry['target'],context)
    if entry['before'] is None and entry.get('native_done'):return cleanup()
    with binding(home,entry['source']):
        if ('obsidian' if td.obsidian_notes.selected(td) else 'apple_notes') != entry['source']:
            raise ValueError('APP_SOURCE_MISMATCH')
        args={'action':'update','note_id':entry['target']}
        if td.personal_scopes.config(td) is not None:
            td.personal_scopes.authorize_mutation(td,'notes',args,context)
        else: app_scope.mutation(td,'notes',args,context)
        observed=snapshot(td,entry['target'],context)
        move_only=entry['source']=='apple_notes' and entry['inverse']['action']=='move'
        # A move owns the folder field only. It never restores a saved body over
        # later content; destructive creation undo still compares the full snapshot.
        current_value=observed['folder'] if move_only else observed
        before_value=entry['before']['folder'] if move_only else entry.get('before')
        after_value=entry['after']['folder'] if move_only else entry['after']
        if current_value == before_value: return {'ok':True,'already':True}
        if current_value != after_value: return {'ok':False,'error':'UNDO_CONFLICT','skipped':True}
        inverse=dict(entry['inverse'],approved=True,_skip_common_work=True,_rollback=True)
        if entry['source']=='apple_notes' and inverse['action'] in ('delete','move'):
            context=dict(context,_memo_expected=observed)
        result=json.loads(td._apple_notes_direct_mutation(inverse,**context))
        if result.get('ok') is not True:return result
        if entry['before'] and entry['source']=='apple_notes' and inverse['action']!='move' and observed['folder']['id'] != entry['before']['folder']['id']:
            moved=dict(action='move',note_id=entry['target'],folder='id:'+entry['before']['folder']['id'],
                       approved=True,_skip_common_work=True,_rollback=True)
            result=json.loads(td._apple_notes_direct_mutation(moved,**context))
        if result.get('ok') is True and entry['before']:
            restored=snapshot(td,entry['target'],context)
            if (restored['folder'] if move_only else restored) != before_value:
                return {'ok':False,'error':'APP_UNDO_READBACK_MISMATCH'}
        if result.get('ok') is True and entry['before'] is None:
            app_undo.progress(home,entry,native_done=True)
            return cleanup()
        return result


def register(ctx,home,td):
    from hermes_governance import app_results
    def inverse(entry):
        with app_tools.host_source(home):return restore(home,td,entry)
    app_results.register(ctx,home,'memo',inverse)
