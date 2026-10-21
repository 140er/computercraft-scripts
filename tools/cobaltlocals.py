# Cobalt (CC: Tweaked) counts the 200-local limit across nested functions:
# locals active in every enclosing function + the nested function's own.
import sys, lupa
L = lupa.lua52.LuaRuntime(encoding=None)
dump = L.eval("function(s,n) local f,e=load(s,'='..n) if not f then return nil,e end return string.dump(f) end")
def parse(b):
    p = 18; si, st = b[7], b[8]
    def ri():
        nonlocal p; v = int.from_bytes(b[p:p+si],'little'); p += si; return v
    def rs():
        nonlocal p; n = int.from_bytes(b[p:p+st],'little'); p += st; s = b[p:p+n]; p += n; return s
    def func():
        nonlocal p
        line = ri(); ri(); p += 3
        n = ri(); code = [int.from_bytes(b[p+4*i:p+4*i+4],'little') for i in range(n)]; p += 4*n
        n = ri()
        for _ in range(n):
            t = b[p]; p += 1
            if t == 1: p += 1
            elif t == 3: p += 8
            elif t == 4: rs()
        n = ri(); kids = [func() for _ in range(n)]
        n = ri(); p += 2*n
        rs(); n = ri(); p += si*n
        n = ri(); lv = []
        for _ in range(n): rs(); a = ri(); c = ri(); lv.append((a, c))
        n = ri()
        for _ in range(n): rs()
        return dict(line=line, code=code, kids=kids, lv=lv)
    return func()
def active(f, pc): return sum(1 for a, c in f['lv'] if a <= pc < c)
def depth(f):
    best = (max([active(f, a) for a, c in f['lv']] or [0]), f['line'])
    for pc, ins in enumerate(f['code']):
        if ins & 0x3F == 37:  # OP_CLOSURE
            d, ln = depth(f['kids'][ins >> 14])
            # +1: the local being declared for "local f = function" counts in Cobalt too
            best = max(best, (active(f, pc) + 1 + d, ln))
    return best
rc = 0
for path in sys.argv[1:]:
    r = dump(open(path, 'rb').read(), path.split('/')[-1].encode())
    if not isinstance(r, bytes): print(path, r); rc = 1; continue
    d, ln = depth(parse(r))
    flag = "TOO MANY" if d > 200 else ("close" if d > 190 else "ok")
    print(f"{path.split('/')[-1]:16} {d:4} locals (deepest at function line {ln}) {flag}")
    if d > 200: rc = 1
sys.exit(rc)
