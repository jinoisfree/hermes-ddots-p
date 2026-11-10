"""One allowlisted Contacts.app writer, with field-local compare before write.

Inputs are data literals in a fixed grammar, never caller-provided scripts.
Native Contacts is used elsewhere for reads; it is never a fallback writer.
"""
import json
from hermes_facility import mac_executor

SCALARS={'given_name':'first name','family_name':'last name','organization':'organization',
         'department':'department','job_title':'job title','note':'note'}
ADDRESS={'street':'street','city':'city','state':'state','postal_code':'zip','country':'country','country_code':'country code'}
READ="""const a=Application('com.apple.AddressBook');const p=a.people.byId(ID);
if(!p.exists())throw Error('CONTACTS_NOT_FOUND');
function val(x){return x===undefined?null:x;}
JSON.stringify({id:p.id(),display_name:p.name(),given_name:val(p.firstName()),family_name:val(p.lastName()),
organization:val(p.organization()),department:val(p.department()),job_title:val(p.jobTitle()),note:val(p.note()),
phones:p.phones().map(r=>({label:val(r.label()),value:val(r.value())})),
emails:p.emails().map(r=>({label:val(r.label()),value:val(r.value())})),
addresses:p.addresses().map(r=>({id:r.id(),street:val(r.street()),city:val(r.city()),state:val(r.state()),
postal_code:val(r.zip()),country:val(r.country()),country_code:val(r.countryCode()),label:val(r.label())}))});"""


def connection_metadata(root):
    """Read at most one contact identifier and return only a bounded count."""
    value=mac_executor.execute(root, "const people=Application('com.apple.AddressBook').people;"
        "const first=people[0];const count=first.exists() ? (first.id() ? 1 : -1) : 0;"
        "JSON.stringify({ok:count>=0,count:Math.max(0,count)});")
    if not isinstance(value,dict) or value.get('ok') is not True or type(value.get('count')) is not int or value['count'] not in (0,1):
        raise ValueError('CONTACTS_APP_READ_UNVERIFIED')
    return dict(ok=True,count=value['count'])


def read(home,identifier,*,kind='contact',contact_ids=()):
    script=READ.replace('ID',json.dumps(identifier,ensure_ascii=False))
    if kind=='group':
        script="const a=Application('com.apple.AddressBook');const g=a.groups.byId("+json.dumps(identifier)+");if(!g.exists())throw Error('CONTACTS_GROUP_NOT_FOUND');"+\
            'for(const id of '+json.dumps(list(contact_ids))+')if(!a.people.byId(id).exists())throw Error("CONTACTS_NOT_FOUND");'+\
            'JSON.stringify({id:g.id(),name:g.name(),member_ids:g.people().map(p=>p.id()).sort()});'
    value=mac_executor.execute(home,script)
    if not isinstance(value,dict) or value.get('id')!=identifier:raise ValueError('CONTACTS_APP_READ_UNVERIFIED')
    return value


def literal(value):
    if value is None:return 'missing value'
    if not isinstance(value,str) or any(ord(c)<32 and c not in '\n\r\t' for c in value):
        raise ValueError('CONTACTS_TEXT_UNSUPPORTED: 이 연락처 글자 형식은 쓸 수 없어요.')
    value=value.replace('\\','\\\\').replace('"','\\"')
    for char,term in (('\r','return'),('\n','linefeed'),('\t','tab')):value=value.replace(char,'" & '+term+' & "')
    return '"'+value+'"'


def selected(record,fields):
    result={}
    for key,wanted in fields.items():
        if key=='address':
            row=(record['addresses'] or [None])[0]
            result[key]=None if row is None else {'id':row['id'],**{k:row.get(k) for k in wanted if k!='id'}}
        else:result[key]=record[key]
    return result


def plan(record,args):
    changes={key:args[key] for key in SCALARS if key in args}
    if args.get('clear_note'):changes['note']=''
    for key in ('phones','emails'):
        if 'replace_'+key in args:changes[key]=args['replace_'+key]
        if 'add_'+key in args:
            rows=list(record[key]);normalize=(lambda v:''.join(c for c in (v or '') if c.isdigit())) if key=='phones' else (lambda v:(v or '').strip().lower())
            for row in args['add_'+key]:
                if normalize(row['value']) not in [normalize(r['value']) for r in rows]:rows.append(row)
            changes[key]=rows
    if 'address' in args:changes['address']=args['address']
    if 'image_path' in args:changes['image_path']=args['image_path']
    return changes


def render(identifier,expected,changes,*,kind='contact'):
    """All comparisons precede all assignments. Caller can request only these fields."""
    if kind=='group':return render_group(identifier,expected,changes)
    guard=[];writes=[]
    for key,value in expected.items():
        if key=='display_name':guard.append(f'if (name of p) is not ({literal(value)}) then return "CONTACTS_IDENTITY_MISMATCH"')
        elif key in SCALARS:guard.append(f'if ({SCALARS[key]} of p) is not ({literal(value)}) then return "CONTACTS_ORIGINAL_CHANGED"')
        elif key in ('phones','emails'):
            noun='phone' if key=='phones' else 'email'
            guard.append(f'if (count {key} of p) is not {len(value)} then return "CONTACTS_ORIGINAL_CHANGED"')
            for i,row in enumerate(value,1):
                for prop in ('label','value'):guard.append(f'if ({prop} of item {i} of {key} of p) is not ({literal(row[prop])}) then return "CONTACTS_ORIGINAL_CHANGED"')
        elif key=='address':
            if value is None:guard.append('if (count addresses of p) is not 0 then return "CONTACTS_ORIGINAL_CHANGED"')
            else:
                guard.extend(['if (count addresses of p) is 0 then return "CONTACTS_ORIGINAL_CHANGED"',f'if (id of item 1 of addresses of p) is not {literal(value["id"])} then return "CONTACTS_ORIGINAL_CHANGED"'])
                for field,old in value.items():
                    if field!='id':guard.append(f'if ({ADDRESS.get(field,field)} of item 1 of addresses of p) is not ({literal(old)}) then return "CONTACTS_ORIGINAL_CHANGED"')
        else:raise ValueError('CONTACTS_FIELD_UNSUPPORTED')
    for key,value in changes.items():
        if key in SCALARS:writes.append(f'set {SCALARS[key]} of p to ({literal(value)})')
        elif key in ('phones','emails'):
            noun='phone' if key=='phones' else 'email';writes.append(f'delete every {noun} of p')
            for row in value:writes.append(f'make new {noun} at end of {key} of p with properties {{label:({literal(row["label"])}), value:({literal(row["value"])})}}')
        elif key=='address':
            if value is None:writes.append('delete item 1 of addresses of p')
            elif expected.get('address') is None:
                props=', '.join(f'{ADDRESS[k]}:({literal(v)})' for k,v in value.items() if k!='id')
                writes.append('make new address at end of addresses of p with properties {'+props+'}')
            else:
                for field,new in value.items():
                    if field!='id':writes.append(f'set {ADDRESS[field]} of item 1 of addresses of p to ({literal(new)})')
        elif key=='image_path':writes.append(f'set image of p to (read POSIX file {literal(value)} as TIFF picture)')
        else:raise ValueError('CONTACTS_FIELD_UNSUPPORTED')
    return '\n'.join(['try','tell application "Contacts"',f'set p to person id {literal(identifier)}',
        'considering case',*guard,*writes,'save','end considering','end tell','return "OK"',
        'on error errorText number errorNumber','return "CONTACTS_APP_WRITE_FAILED:" & errorNumber','end try'])


def apply(home,identifier,expected,changes,*,kind='contact'):
    answer=mac_executor.execute(home,render(identifier,expected,changes,kind=kind),language='AppleScript')
    if answer!='OK':raise ValueError(str(answer))
    return read(home,identifier,kind=kind)


def render_group(identifier,expected,changes):
    guard=[];writes=[]
    for key,value in expected.items():
        if key=='name':guard.append(f'if (name of g) is not {literal(value)} then return "CONTACTS_ORIGINAL_CHANGED"')
        elif key=='member_ids':
            guard.append(f'if (count people of g) is not {len(value)} then return "CONTACTS_ORIGINAL_CHANGED"')
            for sid in value:guard.append(f'if (id of people of g) does not contain {literal(sid)} then return "CONTACTS_ORIGINAL_CHANGED"')
        else:raise ValueError('CONTACTS_FIELD_UNSUPPORTED')
    for key,value in changes.items():
        if key=='name':
            guard.extend(['ignoring case','repeat with otherGroup in groups',f'if (id of otherGroup) is not {literal(identifier)} and (name of otherGroup) is {literal(value)} then return "CONTACTS_GROUP_EXISTS"','end repeat','end ignoring'])
            writes.append('set name of g to '+literal(value))
        elif key=='member_ids':
            old=set(expected[key]);wanted=set(value)
            for sid in sorted(old|wanted):
                guard.append(f'if not (exists person id {literal(sid)}) then return "CONTACTS_NOT_FOUND"')
            writes.extend(f'remove person id {literal(sid)} from g' for sid in sorted(old-wanted))
            writes.extend(f'add person id {literal(sid)} to g' for sid in sorted(wanted-old))
        else:raise ValueError('CONTACTS_FIELD_UNSUPPORTED')
    return '\n'.join(['try','tell application "Contacts"',f'set g to group id {literal(identifier)}','considering case',
        *guard,*writes,'save','end considering','end tell','return "OK"','on error errorText number errorNumber',
        'return "CONTACTS_APP_WRITE_FAILED:" & errorNumber','end try'])
