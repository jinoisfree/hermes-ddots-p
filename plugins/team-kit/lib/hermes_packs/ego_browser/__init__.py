"""Fixed ego-browser CLI operations; page JavaScript and arbitrary scripts are never inputs."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit
from hermes_facility import app_registry
from hermes_governance import app_tools, write_policy

ACTIONS = ('tabs','open','read','screenshot','find','click','type','submit','finish')


def command(profile, args, conversation):
    action=args.get('action')
    if action not in ACTIONS or set(args)-{'action','page','url','selector','text'}:raise ValueError('EGO_ARGUMENT_INVALID')
    label=args.get('page','p1')
    if not isinstance(label,str) or not re.fullmatch(r'p[1-9][0-9]*',label):raise ValueError('EGO_PAGE_INVALID')
    selector=args.get('selector');text=args.get('text','')
    for value in (selector,text):
        if value is not None and (not isinstance(value,str) or len(value)>10000 or '\x00' in value):raise ValueError('EGO_ARGUMENT_INVALID')
    if action in ('click','type','submit','find') and not selector:raise ValueError('EGO_SELECTOR_REQUIRED')
    name='Hermes app '+profile+' '+hashlib.sha256(json.dumps(conversation,sort_keys=True).encode()).hexdigest()[:16]
    script='const task=await taskSpace('+json.dumps(name)+');const page=task.page('+json.dumps(label)+');\n'
    if action=='tabs': operation='console.log(JSON.stringify((await task.tabs()).map(t=>({label:t.label,title:t.title,url:t.url}))));'
    elif action=='open':
        url=args.get('url');parsed=urlsplit(url) if isinstance(url,str) else None
        if not parsed or parsed.scheme not in ('https','http') or not parsed.hostname or parsed.username or parsed.password:raise ValueError('EGO_URL_INVALID')
        operation='await page.goto('+json.dumps(url)+');console.log((await page.snapshot()).slice(0,500000));'
    elif action=='read':operation='console.log((await page.snapshot()).slice(0,500000));'
    elif action=='screenshot':operation='console.log(JSON.stringify({screenshot:await page.screenshot()}));'
    elif action=='find':operation='console.log((await page.snapshot()).split("\\n").filter(line=>line.toLowerCase().includes('+json.dumps(selector.lower())+')).slice(0,100).join("\\n"));'
    elif action=='click':operation='await page.click('+json.dumps(selector)+');console.log(await page.snapshot());'
    elif action=='type':operation='await page.fill('+json.dumps(selector)+','+json.dumps(text)+');console.log(await page.snapshot());'
    elif action=='submit':operation='await page.press('+json.dumps(selector)+',"Enter");console.log(await page.snapshot());'
    else:operation='await task.finish({keep:[]});console.log("finished");'
    return ['ego-browser','nodejs','-e',script+operation]


def handle(home, args, *, runner=None, **context):
    try:
        table=app_registry.load_catalog()
        connected=app_registry.grants(app_registry.root_of(home),app_registry.profile_of(home))
        if not any(b in connected and item['service']=='ego_browser' for b,item in table.items()):raise ValueError('APP_NOT_CONNECTED')
        argv=command(app_registry.profile_of(home),args,app_tools.conversation())
        kind=write_policy.classify('ego_browser',args)
        if kind!=write_policy.READ:
            if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
            if not app_tools.authorized('ego_browser',args):raise ValueError('APP_APPROVAL_REQUIRED')
        result=(runner or subprocess.run)(argv,capture_output=True,text=True,timeout=30,check=False)
        if result.returncode:raise ValueError('EGO_EXECUTION_FAILED')
        output = result.stdout + getattr(result, 'stderr', '')
        if len(output.encode())>1024*1024:raise ValueError('RESULT_TOO_LARGE')
        return json.dumps({'ok':True,'result':output},ensure_ascii=False)
    except (ValueError,OSError,subprocess.TimeoutExpired) as exc:
        return json.dumps({'ok':False,'error':str(exc) if isinstance(exc,ValueError) else 'EGO_EXECUTION_FAILED'})


SCHEMA={'name':'ego_browser','description':'연결한 ego lite의 탭·페이지를 읽고 승인 뒤 누르거나 입력합니다. JavaScript 원문은 받지 않습니다.',
 'parameters':{'type':'object','properties':{'action':{'enum':list(ACTIONS)},'page':{'type':'string'},'url':{'type':'string'},'selector':{'type':'string'},'text':{'type':'string'}},'required':['action'],'additionalProperties':False}}
