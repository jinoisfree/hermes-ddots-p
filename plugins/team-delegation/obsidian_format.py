"""Keep note headings, lists, colors, tables and inline emphasis when writing Markdown."""
from html.parser import HTMLParser
from html import escape
import re

class N:
 def __init__(self,t='',a=()): self.t=t;self.a=dict(a);self.c=[]
 def text(self):return ''.join(x if isinstance(x,str) else x.text() for x in self.c)
class Parser(HTMLParser):
 def __init__(self):super().__init__(convert_charrefs=True);self.root=N();self.stack=[self.root]
 def handle_starttag(self,t,a):
  n=N(t,a);self.stack[-1].c.append(n)
  if t not in ['br','img','hr','input','meta','link']:self.stack.append(n)
 def handle_endtag(self,t):
  for i in range(len(self.stack)-1,0,-1):
   if self.stack[i].t==t:self.stack=self.stack[:i];break
 def handle_data(self,d):self.stack[-1].c.append(d)
def norm(s):return ''.join(s.replace('\ufffc','').replace('☐','[ ]').replace('☑','[x]').split())
def inline(n):
 if isinstance(n,str):return escape(n)
 inner=''.join(inline(c) for c in n.c)
 if n.t=='font':
  style='color:'+n.a['color'] if 'color' in n.a else ''
  return '<span style="'+escape(style,quote=True)+'">'+inner+'</span>' if style else inner
 if n.t=='object':return inner
 if not n.t:return inner
 attrs={k:v for k,v in n.a.items() if k in ['style','href','src','colspan','rowspan','width','height']}
 astr=''.join(' '+k+'="'+escape(v,quote=True)+'"' for k,v in attrs.items())
 if n.t in ['br','img','hr']:return '<'+n.t+astr+'>'
 return '<'+n.t+astr+'>'+inner+'</'+n.t+'>'
def blocks(n,depth=0):
 if isinstance(n,str):return n if n.strip() else ''
 if n.t in ['ul','ol']:
  rows=[]
  for c in n.c:
   if isinstance(c,str):continue
   if c.t!='li':rows.append(blocks(c,depth+1));continue
   main=N();main.c=[x for x in c.c if isinstance(x,str) or x.t not in ['ul','ol']]
   value=inline(main).strip();plain=main.text().strip()
   mark=re.match(r'^(\[[ xX]\]|[☐☑])\s*',plain)
   lead='- ' if n.t=='ul' else '1. '
   if mark:
    value=re.sub(r'\[[ xX]\]\s*|[☐☑]','',value,count=1)
    lead+='[x] ' if mark[1].lower() in ('[x]','☑') else '[ ] '
   rows.append('  '*depth+lead+value)
   for sub in c.c:
    if not isinstance(sub,str) and sub.t in ['ul','ol']:rows.append(blocks(sub,depth+1))
  return '\n'.join(rows)+'\n'
 if n.t=='object':return ''.join(blocks(c,depth) for c in n.c)
 if n.t=='table':return inline(n).replace('\n','')+'\n\n'
 if n.t=='div' and any(not isinstance(c,str) and c.t in ['div','ul','ol','table','h1','h2','h3','blockquote'] for c in n.c):
  return ''.join(blocks(c,depth) for c in n.c)
 if n.t in ['div','h1','h2','h3']:
  value=''.join(inline(c) for c in n.c).strip()
  value=re.sub(r'(?:<br>)+$','',value)
  if not value:return '\n'
  if n.t.startswith('h'):return '#'*int(n.t[1])+' '+value+'\n\n'
  sizes=re.findall(r'font-size:\s*(\d+)px',value)
  if sizes and max(map(int,sizes))>=22 and len(n.text())<150:
   return ('# ' if max(map(int,sizes))>=30 else '## ')+value+'\n\n'
  # Keep each paragraph and inline emphasis, color, underline and line breaks.
  value=re.sub(r'^(\s*)([-#>]) ',lambda m: m[1]+'&#'+str(ord(m[2]))+'; ',value)
  value=re.sub(r'^(\s*)(\d+)\. ',r'\1\2&#46; ',value)
  value=re.sub(r'^ +',lambda m:'&nbsp;'*len(m[0]),value)
  return value+'\n\n'
 return inline(n)+'\n\n'

def convert(source):
 parser=Parser();parser.feed(source);parser.close()
 nodes=[n for n in parser.root.c if not isinstance(n,str) or n.strip()]
 if nodes and not isinstance(nodes[0],str) and nodes[0].t=='h1':nodes=nodes[1:]
 return re.sub(r'\n{3,}','\n\n',''.join(blocks(n) for n in nodes)).strip()+'\n'
