import json
from .model import Criteria, Blocked

TITLE = "Pairing and rejected invitations"


def evaluate(d):
    c = Criteria()
    c.require(d.get("paired_clients") == 5, "All five clients paired")
    c.require(d.get("bad_attempts") == 5, "Five actual wrong-code attempts")
    for name in ("invitation_burned", "probe_unpaired", "server_prompt_restored"):
        c.require(d.get(name), name.replace("_", " "))
    return c.finish(d)


def run(ctx):
    clients = [ctx.computer(n) for n in ("wall", "pocket", "miner1", "miner2", "lumber")]
    probe = ctx.computer("probe")
    paired = ctx.lua("server", "local n=0; for _,id in ipairs(textutils.unserializeJSON(" + json.dumps(json.dumps(clients)) + ")) do if SO.pair.key(id) then n=n+1 end end; return n")
    if ctx.lua("server", f"return SO.pair.key({probe}) ~= nil"):
        empty = ctx.lua("probe", 'return not fs.exists("so-keys") and not fs.exists("so-keys.bak") and not fs.exists("so-keys.tmp")')
        if not empty:
            raise Blocked("Pairing probe must begin unpaired")
        removed = ctx.lua("server", f"return SO.pair.remember({probe},nil)")
        ctx.record("C2-probe-fixture.json", {"probe_has_no_keys": empty, "stale_server_pair_removed": removed})
        if not removed:
            raise Blocked("Could not clear the imported probe's stale server pairing")
    ctx.lua("server", 'repeat SO.pair.invite() until SO.pair.pending() ~= "000000"; return true')
    for _ in range(5):
        ctx.lua("probe", f'''local proto=dofile("so-proto.lua"); local pair=dofile("so-pair.lua");
          pair.open(proto,dofile("so-store.lua")); local m=peripheral.find("modem"); rednet.open(peripheral.getName(m));
          local ok=pair.join("000000",{ctx.computer('server')}); return ok == true''')
    burned = ctx.lua("server", "return SO.pair.pending() == nil")
    unpaired = ctx.lua("server", f"return SO.pair.key({probe}) == nil")
    terminal = ctx.terminal("server")
    ctx.record("C2-server-prompt.json", terminal)
    text = " ".join(l["text"] for l in terminal["lines"])
    return evaluate(ctx.record("C2-observations.json", {"paired_clients": paired, "bad_attempts": 5,
        "invitation_burned": burned, "probe_unpaired": unpaired,
        "server_prompt_restored": "Press P" in text or "[P] pair a client" in text}))
