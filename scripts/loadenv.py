import re,shlex,sys
bad=[]
for i,l in enumerate(open(sys.argv[1]),1):
    s=l.strip()
    if not s or s.startswith('#'): continue
    m=re.match(r'^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$',s)
    if not m: bad.append(i); continue
    v=m.group(2)
    if len(v)>1 and v[0]==v[-1] and v[0] in '"\'': v=v[1:-1]
    print(f"export {m.group(1)}={shlex.quote(v)}")
print(f"echo 'malformed .env lines: {bad}' >&2")
