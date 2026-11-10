"""Fixed JXA for bounded, complete dictionary object guards (never caller code)."""
import json


def source(classes):
    shape = {name: {'properties': sorted(value['properties']),
                    'elements': {child: classes[child]['plural'] if child in classes else None for child in value.get('elements', [])}}
             for name, value in classes.items()}
    def camel(name):
        words = name.split()
        return words[0] + ''.join(word[:1].upper() + word[1:] for word in words[1:])
    for value in shape.values():
        value['properties'] = {name: camel(name) for name in value['properties']}
        value['elements'] = {name: camel(plural) if plural else None for name, plural in value['elements'].items()}
    return 'const snapshotShape=' + json.dumps(shape) + r''';
let snapshotCount=0;
function frozen(value,depth){
 if(depth>20)throw Error('APP_SNAPSHOT_LIMIT');
 if(value===null||typeof value==='string'||typeof value==='boolean')return value;
 if(typeof value==='number'&&Number.isFinite(value))return value;
 if(value instanceof Date)return {$date:value.toISOString()};
 if(Array.isArray(value))return value.map(x=>frozen(x,depth+1));
 if(typeof value!=='object'||(Object.getPrototypeOf(value)!==Object.prototype&&Object.getPrototypeOf(value)!==null))throw Error('APP_SNAPSHOT_UNSUPPORTED');
 const out=Object.create(null);Object.keys(value).sort().forEach(k=>{out[k]=frozen(value[k],depth+1);});return out;
}
function objectSnapshot(item,kind,depth){
 if(depth>6||++snapshotCount>200)throw Error('APP_SNAPSHOT_LIMIT');
 const shape=snapshotShape[kind];if(!shape)throw Error('APP_SNAPSHOT_UNSUPPORTED');
 const properties=frozen(item.properties(),0);
 // Read every declared property too: an app omitting one from properties() is
 // not evidence that the omitted property has stayed unchanged.
 const declared={};Object.keys(shape.properties).sort().forEach(k=>{declared[k]=frozen(item[shape.properties[k]](),0);});
 const elements={};Object.keys(shape.elements).sort().forEach(k=>{
  if(!shape.elements[k])throw Error('APP_SNAPSHOT_UNSUPPORTED');
  const list=item[shape.elements[k]],total=list.length;
  if(!Number.isInteger(total)||total<0||total>200)throw Error('APP_SNAPSHOT_LIMIT');
  elements[k]=[];for(let i=0;i<total;i++)elements[k].push(objectSnapshot(list[i],k,depth+1));
 });
 const result={properties,declared,elements};
 if(JSON.stringify(result).length>524288)throw Error('APP_SNAPSHOT_LIMIT');
 return result;
}
'''


def receipt_source(path):
    # A private, pending-ledger-owned receipt survives worker/caller failure.
    return ('ObjC.import("Foundation");'
            'ObjC.bindFunction("umask",["unsigned short",["unsigned short"]]);'
            'ObjC.bindFunction("open",["int",["char *","int"]]);'
            'ObjC.bindFunction("fsync",["int",["int"]]);'
            'ObjC.bindFunction("close",["int",["int"]]);$.umask(63);'
            'const receiptPath=' + json.dumps(str(path)) + ';'
            'function recordCreated(id){if(!((typeof id===\'string\'&&id.length>0)||Number.isInteger(id)))throw Error("APP_ID_INVALID");'
            'const bytes=$(JSON.stringify({id:id})).dataUsingEncoding($.NSUTF8StringEncoding);'
            'if(!bytes.writeToFileOptionsError(receiptPath,1,null))throw Error("APP_RECEIPT_FAILED");'
            'for(const path of [receiptPath,' + json.dumps(str(path.parent)) + ']){'
            'const fd=$.open(path,0);if(fd<0)throw Error("APP_RECEIPT_FAILED");'
            'const status=$.fsync(fd);$.close(fd);if(status!==0)throw Error("APP_RECEIPT_FAILED");}}')
