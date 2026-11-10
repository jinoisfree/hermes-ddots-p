"""Structured sdef automation. No model-supplied AppleScript or JavaScript."""
import json
import os
from pathlib import Path
import re
import time
import uuid
import xml.etree.ElementTree as ET
from hermes_facility import app_registry, mac_executor
from hermes_governance import app_tools, app_undo, write_policy
from . import discovery, catalog, snapshot

_CACHE = {}
FORBIDDEN = {'doshellscript', 'runscript', 'dojavascript', 'executejavascript', 'loadscript',
             'constructor', 'prototype', '__proto__', 'eval', 'function'}
MAX_LIMIT = 100


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9 ]{0,79}', value): raise ValueError('APP_IDENTIFIER_INVALID')
    if value.replace(' ', '').lower() in FORBIDDEN: raise ValueError('APP_COMMAND_FORBIDDEN')
    return value


def js_name(value, plural=False):
    words = identifier(value).split()
    result = words[0] + ''.join(w[:1].upper() + w[1:] for w in words[1:])
    return result


def describe_file(path, version=''):
    path = Path(path)
    stamp = (str(path), version, path.stat().st_mtime_ns, path.stat().st_size)
    if stamp in _CACHE: return _CACHE[stamp]
    if path.stat().st_size > 2 * 1024 * 1024: raise ValueError('APP_SDEF_TOO_LARGE')
    result = describe_xml(ET.parse(path).getroot())
    _CACHE.clear() if len(_CACHE) >= 100 else None
    _CACHE[stamp] = result
    return result


def describe_xml(xml):
    # Only Apple's fixed standard dictionary may be included; never follow caller-controlled URIs.
    includes = xml.findall('.//{http://www.w3.org/2001/XInclude}include')
    if any(n.get('href') == 'file:///System/Library/ScriptingDefinitions/CocoaStandard.sdef' for n in includes):
        standard = Path('/System/Library/ScriptingDefinitions/CocoaStandard.sdef')
        if standard.is_file(): xml.insert(0, ET.parse(standard).getroot())
    classes, commands = {}, {}
    for node in xml.findall('.//class'):
        name = identifier(node.attrib['name'])
        classes[name] = dict(plural=identifier(node.get('plural') or name + 's'), inherits=node.get('inherits'),
            properties={identifier(p.attrib['name']): dict(access=p.get('access','rw'), type=p.get('type')) for p in node.findall('property')},
            elements=[e.get('type') for e in node.findall('element')])
    for node in xml.findall('.//command'):
        try: name = identifier(node.attrib['name'])
        except ValueError: continue
        direct = node.find('direct-parameter')
        commands[name] = dict(parameters=[identifier(p.attrib['name']) for p in node.findall('parameter')],
            direct_parameter=None if direct is None else dict(type=direct.get('type') or next((t.get('type') for t in direct.findall('type')), None), optional=direct.get('optional') == 'yes'))
    for node in xml.findall('.//class-extension'):
        target = classes.get(node.get('extends'))
        if target:
            target['properties'].update({identifier(p.attrib['name']): dict(access=p.get('access','rw'), type=p.get('type')) for p in node.findall('property')})
            target['elements'].extend(e.get('type') for e in node.findall('element'))
    for name, value in classes.items():
        seen = {name}; parent = value.get('inherits')
        while parent and parent in classes:
            if parent in seen: raise ValueError('APP_SDEF_INVALID')
            seen.add(parent)
            for prop, metadata in classes[parent]['properties'].items(): value['properties'].setdefault(prop, metadata)
            value['elements'] = list(dict.fromkeys(value['elements'] + classes[parent]['elements']))
            parent = classes[parent].get('inherits')
    result = dict(classes=classes, commands=commands)
    return result


def dictionary(bundle, roots=None):
    path = discovery.locate(bundle, roots)
    if path is None: raise ValueError('APP_MISSING')
    resources = path / 'Contents/Resources'
    files = sorted(resources.glob('*.sdef'))
    if not files:
        from .sdef import from_bundle
        return describe_xml(ET.fromstring(from_bundle(path)))
    info = discovery.read_plist(path / 'Contents/Info.plist') or {}
    return describe_file(files[0], str(info.get('CFBundleShortVersionString','')))


def path_script(classes, path, variable='target'):
    if not isinstance(path, list) or len(path) > 12: raise ValueError('APP_PATH_INVALID')
    source = []
    current_class = classes.get('application', {})
    for part in path:
        if not isinstance(part, dict) or set(part) != {'class','by','value'}: raise ValueError('APP_PATH_INVALID')
        name, by, value = part['class'], part['by'], part['value']
        if name not in classes or by not in ('name','id','index'): raise ValueError('APP_PATH_INVALID')
        if current_class.get('elements') and name not in current_class['elements']: raise ValueError('APP_PATH_INVALID')
        if by == 'index':
            if type(value) is not int or not 1 <= value <= 100000: raise ValueError('APP_PATH_INVALID')
        elif not isinstance(value, str) or len(value)>1000 or any(c in value for c in '"&\r\n\x00'):
            raise ValueError('APP_PATH_INVALID')
        collection = js_name(classes[name]['plural'])
        source.append(variable+'='+variable+'[' + json.dumps(collection) + ']' + (
            '[' + str(value-1) + '];' if by=='index' else '.by' + by.title() + '(' + json.dumps(value) + ');'))
        current_class = classes[name]
    return source, current_class


def compile_script(bundle, spec, args, *, receipt=None, snapshot_read=False, expected=None):
    action = args.get('action'); classes = spec['classes']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{1,250}', bundle): raise ValueError('APP_INVALID')
    path = args.get('path', [])
    if not isinstance(path, list) or len(path) > 12: raise ValueError('APP_PATH_INVALID')
    source = ['const a=Application(' + json.dumps(bundle) + ');',
        'if(!a.running()){ObjC.import("AppKit");const w=$.NSWorkspace.sharedWorkspace;'+
        'const u=w.URLForApplicationWithBundleIdentifier('+json.dumps(bundle)+');'+
        'w.launchApplicationAtURLOptionsConfigurationError(u,$.NSWorkspaceLaunchWithoutActivation|$.NSWorkspaceLaunchAndHide,$.NSDictionary.dictionary,null);}',
        'let target=a;']
    path_lines, current_class = path_script(classes, path)
    source.extend(path_lines)
    creation_snapshot=action=='create' and operation_kind(args,spec)==write_policy.REVERSIBLE
    if snapshot_read or creation_snapshot or expected and 'snapshot' in expected:
        source.append(snapshot.source(classes))
    if snapshot_read:
        if not path: raise ValueError('APP_PATH_INVALID')
        source.append('JSON.stringify(objectSnapshot(target,'+json.dumps(path[-1]['class'])+',0));')
        return '\n'.join(source)
    if expected is not None:
        if 'snapshot' in expected:
            observed = 'objectSnapshot(target,'+json.dumps(path[-1]['class'])+',0)'
            wanted = expected['snapshot']
        else:
            names = {k:js_name(k) for k in expected['properties']}
            source.append('const guardValues=target.properties();')
            observed = 'Object.fromEntries(Object.entries('+json.dumps(names)+').map(([k,v])=>[k,guardValues[v]]))'
            wanted = expected['properties']
        source.append('if(JSON.stringify('+observed+')!=='+json.dumps(json.dumps(wanted,ensure_ascii=False,separators=(',',':')))+'){JSON.stringify({__hermes_conflict:true});}else{')
    collection_read = action == 'read' and args.get('class') is not None
    if collection_read:
        name = args['class']
        if name not in classes or name not in current_class.get('elements', []): raise ValueError('APP_CLASS_INVALID')
        source.append('target=target[' + json.dumps(js_name(classes[name]['plural'])) + '];')
        current_class = classes[name]
    props = args.get('properties', [])
    if action in ('create','update'):
        if not isinstance(props, dict) or not props or len(props)>40: raise ValueError('APP_PROPERTIES_INVALID')
        target_class = classes.get(args.get('class'), {}) if action=='create' else current_class
        for name in props:
            identifier(name)
            if name not in target_class.get('properties', {}) or target_class['properties'][name]['access']=='r': raise ValueError('APP_PROPERTY_REFUSED')
            if not isinstance(props[name], (str,int,float,bool,type(None))) or isinstance(props[name], str) and len(props[name])>100000: raise ValueError('APP_VALUE_INVALID')
        mapping = {js_name(k):v for k,v in props.items()}
        if action=='create':
            if args.get('class') not in classes: raise ValueError('APP_CLASS_INVALID')
            if receipt is not None: source.append(snapshot.receipt_source(receipt))
            make = spec['commands'].get('make', {}).get('parameters', [])
            if 'named' in make:
                if set(props) != {'name'}: raise ValueError('APP_CREATE_UNSUPPORTED')
                source.append('const made=a.make({new:' + json.dumps(args['class']) + ',named:' + json.dumps(props['name']) + (',at:target' if path else '') + '});')
            else:
                source.append('const made=a.make({new:' + json.dumps(args['class']) + (',at:target' if path else '') + ',withProperties:' + json.dumps(mapping,ensure_ascii=False) + '});')
            names = {k: js_name(k) for k in props}
            has_id = 'id' in target_class.get('properties',{})
            if has_id:
                source.append('const createdId=made.id();'+('recordCreated(createdId);' if receipt is not None else ''))
            source.append('const names='+json.dumps(names)+';const values=made.properties();JSON.stringify({'+
                ('id:createdId,' if has_id else '')+
                ('snapshot:objectSnapshot(made,'+json.dumps(args['class'])+',0),' if creation_snapshot else '')+
                'properties:Object.fromEntries(Object.entries(names).map(([k,v])=>[k,values[v]]))});')
        else:
            for key,value in mapping.items(): source.append('target[' + json.dumps(key) + ']=' + json.dumps(value,ensure_ascii=False) + ';')
            source.append('const values=target.properties();const names='+json.dumps({k:js_name(k) for k in props})+';JSON.stringify({properties:Object.fromEntries(Object.entries(names).map(([k,v])=>[k,values[v]]))});')
    elif action=='read':
        limit=args.get('limit',20)
        if type(limit) is not int or not 1<=limit<=MAX_LIMIT:raise ValueError('APP_LIMIT_INVALID')
        if not isinstance(props,list) or len(props)>40: raise ValueError('APP_PROPERTIES_INVALID')
        for prop in props:
            identifier(prop)
            if prop not in current_class.get('properties',{}):raise ValueError('APP_PROPERTY_REFUSED')
        source.append('const names='+json.dumps({p:js_name(p) for p in props})+';'+
            'function row(item){const values=item.properties();return Object.keys(names).length?Object.fromEntries(Object.entries(names).map(([k,v])=>[k,values[v]])):values;}')
        if collection_read:
            source.append('const total=target.length;const items=[];for(let i=0;i<Math.min(total,'+str(limit)+');i++){items.push(row(target[i]));}JSON.stringify({items,total,limit_reached:total>items.length});')
        else: source.append('JSON.stringify(row(target));')
    elif action=='delete':
        if not path:raise ValueError('APP_PATH_INVALID')
        source.append('a.delete(target);JSON.stringify({deleted:true});')
    elif action=='command':
        name=identifier(args.get('name')); params=args.get('args',{})
        if name not in spec['commands'] or not isinstance(params,dict):raise ValueError('APP_COMMAND_INVALID')
        for key in params:
            if identifier(key) not in spec['commands'][name]['parameters']:raise ValueError('APP_ARGUMENT_INVALID')
        direct = spec['commands'][name].get('direct_parameter')
        if 'direct' in args and direct is None: raise ValueError('APP_ARGUMENT_INVALID')
        if direct is not None and not direct.get('optional') and 'direct' not in args: raise ValueError('APP_ARGUMENT_REQUIRED')
        call = []
        if 'direct' in args:
            value = args['direct']
            if isinstance(value, dict):
                if set(value) != {'path'} or direct.get('type') != 'specifier': raise ValueError('APP_ARGUMENT_INVALID')
                lines, _ = path_script(classes, value['path'], 'directTarget')
                source.extend(['let directTarget=a;', *lines]); expression = 'directTarget'
            else:
                if not isinstance(value, (str,int,float,bool,list,type(None))): raise ValueError('APP_ARGUMENT_INVALID')
                expression = json.dumps(value, ensure_ascii=False, allow_nan=False)
            if direct.get('type') in ('file','alias'):
                if not isinstance(value, str) or not Path(value).is_absolute(): raise ValueError('APP_ARGUMENT_INVALID')
                expression = 'Path('+expression+')'
            call.append(expression)
        if params: call.append(json.dumps({js_name(k):v for k,v in params.items()},ensure_ascii=False,allow_nan=False))
        source.append('JSON.stringify(a['+json.dumps(js_name(name))+']('+','.join(call)+'));')
    else:raise ValueError('APP_ACTION_INVALID')
    if expected is not None: source.append('}')
    return '\n'.join(source)


def granted(home, bundle):
    if bundle not in app_registry.grants(app_registry.root_of(home), app_registry.profile_of(home)):raise ValueError('APP_NOT_CONNECTED')
    item=catalog.load_catalog().get(bundle,{})
    if item.get('route') in ('excluded','none','cli'):raise ValueError('APP_UNAVAILABLE')
    if item.get('scope'):raise ValueError('APP_SCOPED_TOOL_REQUIRED')


def operation_kind(args, spec):
    kind=write_policy.classify('mac_app',args)
    if args.get('action')=='create':
        classes=spec['classes'];target=classes.get(args.get('class'),{})
        if 'id' not in target.get('properties',{}):return write_policy.EXTERNAL
        pending=[args.get('class')];seen=set()
        while pending:
            name=pending.pop()
            if name in seen:continue
            seen.add(name);node=classes.get(name)
            if node is None or any(p.get('access')=='w' for p in node['properties'].values()):return write_policy.EXTERNAL
            pending.extend(node.get('elements',[]))
    return kind


def undo_entry(home, key=None):
    with app_undo.partition(app_undo.path_for(home),'mac_app',legacy=app_undo.legacy_paths(home)) as (data,save):
        return next((e for e in reversed(data['entries']) if not e.get('consumed') and e.get('conversation')==app_tools.conversation() and (key is None or e.get('key')==key)),None)


def approval(home, args):
    owner=write_policy.owner_chat(home,app_tools.env)
    if args.get('action')=='undo':
        if not owner:return {'action':'block','message':'APP_OWNER_CHAT_REQUIRED'}
        entry=undo_entry(home,args.get('key'))
        if not entry:return {'action':'block','message':'UNDO_EXPIRED'}
        reason=app_undo.authorization(entry,app_tools.conversation())
        if reason=='OK':return None
        return write_policy.gate('mac_app',{'action':'undo'},owner=owner) if reason=='UNDO_APPROVAL_REQUIRED' else {'action':'block','message':reason}
    try:
        spec=dictionary(args.get('app')) if args.get('action')=='create' else {}
        kind=operation_kind(args,spec)
    except (ValueError,OSError):return {'action':'block','message':'APP_SDEF_INVALID'}
    checked=args if kind!=write_policy.EXTERNAL else {**args,'action':'external'}
    return write_policy.gate('mac_app',checked,owner=owner,unattended=write_policy.background(app_tools.env))


def restore(home,args,run):
    if not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
    with app_undo.partition(app_undo.path_for(home),'mac_app',legacy=app_undo.legacy_paths(home)) as (data,save):
        entry=next((e for e in reversed(data['entries']) if not e.get('consumed') and e.get('conversation')==app_tools.conversation() and (not args.get('key') or e.get('key')==args['key'])),None)
        if not entry:raise ValueError('UNDO_EXPIRED')
        if entry.get('status')!='applied':raise ValueError('APP_UNDO_NOT_READY')
        reason=app_undo.authorization(entry,app_tools.conversation(),approved=app_tools.authorized('mac_app',args))
        if reason!='OK':raise ValueError(reason)
        bundle=entry['target'];granted(home,bundle);spec=dictionary(bundle)
        inverse=entry['inverse'];after=entry['after']
        expected={'snapshot':after['snapshot']} if entry['arguments']['action']=='create' else {'properties':after['properties']}
        result=run(compile_script(bundle,spec,inverse,expected=expected))
        if isinstance(result,dict) and result.get('__hermes_conflict'):return {'ok':False,'error':'UNDO_CONFLICT','skipped':True}
        if not isinstance(result,dict) or (inverse['action']=='delete' and result.get('deleted') is not True):raise ValueError('APP_UNDO_UNVERIFIED')
        if inverse['action']=='update' and result.get('properties')!=entry['before']:raise ValueError('APP_UNDO_UNVERIFIED')
        entry['consumed']=True;save()
        return {'ok':True,'result':result}


def handle(home, args, *, execute=None, **context):
    try:
        if not isinstance(args,dict) or set(args)-{'action','app','path','properties','limit','class','name','args','direct','key'}:raise ValueError('APP_ARGUMENT_INVALID')
        run=execute or (lambda code:mac_executor.execute(app_registry.root_of(home),code))
        if args.get('action')=='undo':return json.dumps(restore(home,args,run),ensure_ascii=False)
        if args.get('action')=='apps':
            selected=app_registry.grants(app_registry.root_of(home),app_registry.profile_of(home))
            return json.dumps({'ok':True,'apps':[a for a in discovery.scan() if a['bundle_id'] in selected]},ensure_ascii=False)
        bundle=args.get('app');granted(home,bundle);spec=dictionary(bundle)
        if args.get('action')=='describe':return json.dumps({'ok':True,**spec},ensure_ascii=False)
        kind=operation_kind(args,spec)
        if kind!=write_policy.READ and not write_policy.owner_chat(home,app_tools.env):raise ValueError('APP_OWNER_CHAT_REQUIRED')
        if kind in (write_policy.DELETE,write_policy.EXTERNAL) and not app_tools.authorized('mac_app',args):raise ValueError('APP_APPROVAL_REQUIRED')
        script=compile_script(bundle,spec,args)
        if kind==write_policy.REVERSIBLE:
            # The pending row and inverse template are durable BEFORE the effect.
            with app_undo.ledger(app_undo.path_for(home),legacy=app_undo.legacy_paths(home)) as (data,save):
                before=run(compile_script(bundle,spec,{**args,'action':'read','properties':list(args['properties'])})) if args.get('action')=='update' else None
                if before is not None and (not isinstance(before,dict) or set(before)!=set(args['properties']) or any(not isinstance(v,(str,int,float,bool,type(None))) for v in before.values())):raise ValueError('APP_BEFORE_UNVERIFIED')
                entry=dict(key=uuid.uuid4().hex,created_at=time.time(),consumed=False,journal_kind='mac_app',
                    conversation=app_tools.conversation(),tool='mac_app',target=bundle,arguments=args,before=before,
                    after=None,status='pending',inverse=({'action':'delete','app':bundle,'path':args.get('path',[]),'created_class':args['class']} if args['action']=='create' else {**args,'properties':before}))
                receipt=None
                if args['action']=='create':
                    from hermes_facility.config_assembly import checked_path, atomic_write
                    root=app_registry.root_of(home).resolve()
                    receipt=checked_path(root,'state/connections/mac-app-receipts/'+entry['key']+'.json')
                    atomic_write(receipt,b'{}')
                    entry['receipt']=str(receipt.relative_to(root))
                    script=compile_script(bundle,spec,args,receipt=receipt)
                data['entries'].append(entry);save()
                captured=False
                try:
                    result=run(script)
                    if not isinstance(result,dict) or not isinstance(result.get('properties'),dict) or set(result['properties'])!=set(args['properties']):raise ValueError('APP_AFTER_UNVERIFIED')
                    if args['action']=='create':
                        identifier=result.get('id')
                        if not isinstance(identifier,(str,int)) or isinstance(identifier,bool) or not str(identifier):raise ValueError('APP_ID_INVALID')
                        entry['native_target']=identifier;save()
                        if not isinstance(result.get('snapshot'),dict) or set(result['snapshot'])!={'properties','declared','elements'}:raise ValueError('APP_AFTER_UNVERIFIED')
                        entry['inverse']={'action':'delete','app':bundle,'path':args.get('path',[])+[{'class':args['class'],'by':'id','value':str(identifier)}]}
                        compile_script(bundle,spec,entry['inverse'],expected={'snapshot':result['snapshot']})
                    entry.update(after=result,status='applied');save();captured=True
                except BaseException:
                    # A worker can time out AFTER make(). Recover only its fixed
                    # ID receipt; never find a supposedly new object by name.
                    if receipt is not None and receipt.exists():
                        fd=os.open(receipt,os.O_RDONLY|os.O_NOFOLLOW)
                        with os.fdopen(fd) as stream:
                            try: progress=json.loads(stream.read(4097))
                            except ValueError: progress={}
                        if isinstance(progress,dict) and type(progress.get('id')) in (str,int):entry['native_target']=progress['id']
                    entry['status']='uncertain';save();captured=True;raise
                finally:
                    if receipt is not None and captured:
                        receipt.unlink(missing_ok=True)
        else:result=run(script)
        return json.dumps({'ok':True,'result':result,**({'message':write_policy.result_text('앱에 변경한 내용을 저장했어요.',entry['key'])} if kind==write_policy.REVERSIBLE else {})},ensure_ascii=False)
    except (ValueError,OSError,KeyError,TypeError) as exc:
        return json.dumps({'ok':False,'error':str(exc) if isinstance(exc,ValueError) else 'APP_EXECUTION_FAILED'})


SCHEMA={'name':'mac_app','description':'연결한 Mac 앱의 사전을 보고 구조화한 경로로 읽고 다룹니다. 스크립트 원문은 받지 않습니다.',
 'parameters':{'type':'object','properties':{'action':{'type':'string','enum':['apps','describe','read','create','update','delete','command','undo']},
 'app':{'type':'string'},'path':{'type':'array','items':{'type':'object','properties':{'class':{'type':'string'},'by':{'enum':['name','id','index']},'value':{}},'required':['class','by','value'],'additionalProperties':False}},
 'key':{'type':'string','pattern':'^[0-9a-f]{32}$'},
 'direct':{'description':'Command direct parameter, when declared by the app dictionary.'},
 'class':{'type':'string','description':'For read, enumerate this child collection up to limit; for create, the object class.'},'properties':{'oneOf':[{'type':'object'},{'type':'array','items':{'type':'string'}}]},'limit':{'type':'integer','minimum':1,'maximum':100},'name':{'type':'string'},'args':{'type':'object'}},'required':['action'],'additionalProperties':False}}


def register_result(ctx,home):
    from hermes_governance import app_results
    def inverse(entry):
        args={'action':'undo','key':entry['key']}
        with app_tools.native('mac_app',args):
            return restore(home,args,lambda code:mac_executor.execute(app_registry.root_of(home),code))
    app_results.register(ctx,home,'mac_app',inverse)
