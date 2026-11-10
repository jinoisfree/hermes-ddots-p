"""Notion's existing journal and inverse writer, bound to app result decisions."""
from contextlib import contextmanager
from contextvars import ContextVar
from copy import deepcopy
from hermes_governance import app_tools,app_results,write_policy
from hermes_facility import app_registry

_SELECTED=ContextVar('notion_result_entry',default=None)


def selected():return _SELECTED.get()


@contextmanager
def selection(key):
    token=_SELECTED.set(key)
    try:yield
    finally:_SELECTED.reset(token)


def tree(n,home,identifier,opener,depth=0,budget=None,version=None):
    """Complete bounded subtree for created data; never delete a later owner's edit."""
    budget=[500] if budget is None else budget
    if depth>20 or budget[0]<=0:raise n.NotionError('NOTION_CREATED_STATE_LIMIT')
    block=n.request(home,'GET','blocks/'+identifier,opener=opener,version=version)
    budget[0]-=1
    result={'block':deepcopy(block),'children':[]}
    if block.get('has_children'):
        children=n.append_children_snapshot(home,identifier,opener,version=version)
        if children is None:raise n.NotionError('NOTION_CREATED_STATE_UNVERIFIED')
        result['children']=[tree(n,home,b['id'],opener,depth+1,budget,version=version) for b in children]
    return result


def page(n,home,identifier,opener,version=None):
    value=n.request(home,'GET','pages/'+identifier,opener=opener,version=version)
    children=n.append_children_snapshot(home,identifier,opener,version=version)
    if children is None:raise n.NotionError('NOTION_CREATED_STATE_UNVERIFIED')
    budget=[500]
    return {'page':value,'children':[tree(n,home,b['id'],opener,budget=budget,version=version) for b in children]}


def capture(n,home,inverse,opener):
    action=inverse['action']
    if action=='create':inverse['app_after']=page(n,home,inverse['page_id'],opener)
    elif action=='append':
        inverse['app_after']={key:tree(n,home,key,opener) for key in inverse['block_ids']}


def complete(result):
    if result.get('ok') is not True:return False
    verify=result.get('verification',{})
    if verify.get('error') or any(p.get('matches') is not True for p in verify.get('properties',{}).values()):return False
    for field in ('blocks_match','images_match'):
        if verify.get(field) is False:return False
    if any(b.get('matches') is not True for b in verify.get('edited_blocks',{}).values()):return False
    return result.get('attachment_loss') is not True


def result(entry,result):
    if result.get('ok') and entry.get('app_ready') and not entry.get('consumed'):
        result.update(undo_key=entry['key'],message=write_policy.result_text('Notion 변경을 저장했어요.',entry['key']))
    return result


def restore(n,home,config,entry,opener=None):
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    if app_registry.tool_granted(home,'notion') is False:raise ValueError('APP_NOT_CONNECTED')
    if not n.enabled(config) or n.writable(config)==set():raise ValueError('APP_NOT_CONNECTED')
    if not entry.get('app_ready'):raise ValueError('NOTION_CHANGE_UNVERIFIED')
    try:
        with selection(entry['key']),app_tools.host_source(home):
            n.work_scope_guard(entry['request'])
            n.work_block_scope(home,entry['request'],opener)
            return n.rollback(config,home,{'action':'rollback','key':entry['key']},opener,chat=True,require_snapshot=False)
    except n.NotionError as error:
        return {'ok':False,'error':str(error),'skipped':True}


def register(ctx,home,n,config):
    app_results.register(ctx,home,'notion',lambda entry:restore(n,home,config(),entry))
