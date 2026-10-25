import json
import os
import re
from .model import Criteria, Blocked

TITLE = "Pair2 pairing and rejected invitations"

# Isolated client globals let one native modem exercise distinct rednet senders.
# Every exchange still crosses the modem and the real server's pair2 handler.
ATTEMPT = '''local code,server,sender=...
  local modem=assert(peripheral.find("modem"));local channel=sender % 65500
  local opened=modem.isOpen(channel);modem.open(channel)
  local env=setmetatable({}, {__index=_ENV})
  env.os=setmetatable({getComputerID=function() return sender end}, {__index=os})
  env.os.pullEvent=function(filter)
    while true do
      local e={os.pullEvent()}
      if e[1]=="modem_message" and e[3]==channel and type(e[5])=="table" then
        local m=e[5]
        if m.nRecipient==sender and m.nSender==server and m.sProtocol=="so" then
          e={"rednet_message",server,m.message,"so"}
        end
      end
      if not filter or e[1]==filter then return table.unpack(e) end
    end
  end
  local sent={}
  env.rednet={send=function(target,wire,protocol)
    sent[#sent+1]=wire.t
    modem.transmit(target % 65500,channel,{nMessageID=math.random(1,2147483647),
      nRecipient=target,nSender=sender,message=wire,sProtocol=protocol})
  end}
  env.dofile=function(path) return assert(loadfile(path,"t",env))() end
  local function attempt()
    local proto=env.dofile("so-proto.lua");local pair=env.dofile("so-pair.lua")
    pair.open(proto,env.dofile("so-store.lua"))
    local ok,why=pair.join(code,server)
    return {ok=ok==true,reason=why or "",messages=sent}
  end
  local ok,result=pcall(attempt)
  if not opened then modem.close(channel) end
  if not ok then error(result) end
  return result'''


# Route A footer "[P] pair" with no live code in the pair leader; older builds print "Press P".
# The code screen's footer reads "[P] new code", so it never counts as the prompt.
def prompt_restored(terminal):
    lines = [l.get("text", "") for l in terminal.get("lines", [])]
    text = " ".join(lines)
    if "Press P" in text or "[P] pair a client" in text:
        return True
    if not any(re.search(r"\[P\] pair(?:\s|$)", line) for line in lines):
        return False
    live = [m.group(1) for line in lines for m in re.finditer(r"\bpair [\u00b7.]+ (\S+)", line)]
    return all(code == "-" for code in live)


def evaluate(d):
    c = Criteria()
    c.require(d.get("paired_clients") == 5, "All five existing clients paired")
    attempts = d.get("attempts", [])
    wrong = [a for a in attempts if a.get("reason") == "wrong code" and a.get("ok") is False]
    c.require(len(wrong) == 10, "Ten observed wrong-code rejections")
    c.require([a.get("live") for a in wrong] == [True] * 9 + [False], "Invitation burns on the tenth wrong code only")
    c.require(len({a.get("sender") for a in wrong}) >= 4, "Wrong codes span multiple senders")
    c.require(d.get("minute_limited"), "Sender limited to three tries per minute")
    c.require(d.get("sender_limited"), "Three wrong codes block one sender without burning the invitation")
    c.require(d.get("probe_unpaired"), "Rejected probe remains unpaired")
    success = d.get("success", {})
    c.require(success.get("ok"), "Fresh pair2 invitation succeeds")
    c.require(d.get("server_key_saved"), "Server saves the paired probe")
    c.require(bool(attempts) and all(a.get("messages") and set(a["messages"]) == {"pair2"} for a in [*attempts, success]), "Clients send only pair2")
    c.require(d.get("server_prompt_restored"), "Server prompt restored after burn")
    return c.finish(d)


def run(ctx):
    if os.environ.get("GATEB_C2_REPAIR") == "1":
        from .c2_repair import run as repair
        return repair(ctx)
    clients = [ctx.computer(n) for n in ("wall", "pocket", "miner1", "miner2", "lumber")]
    probe, server = ctx.computer("probe"), ctx.computer("server")
    paired = ctx.lua("server", "local n=0; for _,id in ipairs(textutils.unserializeJSON(" + json.dumps(json.dumps(clients)) + ")) do if SO.pair.key(id) then n=n+1 end end; return n")
    empty = ctx.lua("probe", 'return not fs.exists("so-keys") and not fs.exists("so-keys.bak") and not fs.exists("so-keys.tmp")')
    if not empty:
        raise Blocked("Pairing probe must begin unpaired")
    if not ctx.lua("server", f"return SO.pair.remember({probe},nil)"):
        raise Blocked("Could not clear the imported probe's stale server pairing")
    senders = [n for n in range(60000, 65500) if str(n) not in ctx.manifest["computers"]][:8]
    ctx.lua("server", 'repeat SO.pair.invite() until SO.pair.pending() ~= "000000"; return true')
    attempts = []

    def attempt(sender, code="000000"):
        result = ctx.lua("probe", f"return assert(load({json.dumps(ATTEMPT)}))({json.dumps(code)},{server},{sender})")
        result.update(sender=sender, live=ctx.lua("server", "return SO.pair.pending() ~= nil"))
        attempts.append(result)
        ctx.record("C2-attempts.json", attempts)
        return result

    def cooldown():
        start = ctx.game_clock()
        if not ctx.wait(lambda: ctx.game_clock() - start >= 61000, 90):
            raise Blocked("Pairing budget clock did not advance through one minute")

    first = senders[0]
    attempt(first)
    attempt(first)
    limited = attempt(first)
    minute_limited = limited["reason"] == "busy" and limited["live"] and limited["messages"] == ["pair2"]
    cooldown()
    third = attempt(first)
    cooldown()
    limited = attempt(first)
    sender_limited = (third["reason"] == "wrong code" and third["live"] and
                      limited["reason"] == "busy" and limited["live"] and limited["messages"] == ["pair2"])
    for sender in senders[1:]:
        attempt(sender)
    unpaired = ctx.lua("server", f"return SO.pair.key({probe}) == nil")
    # The terminal redraws on the next tick after the burn.
    restored = bool(ctx.wait(lambda: prompt_restored(ctx.terminal("server")), 10))
    ctx.record("C2-server-prompt.json", ctx.terminal("server"))
    code = ctx.lua("server", "return SO.pair.invite()")
    success = attempt(probe, code)
    attempts.pop()
    return evaluate(ctx.record("C2-observations.json", {"paired_clients": paired, "attempts": attempts,
        "minute_limited": minute_limited, "sender_limited": sender_limited, "probe_unpaired": unpaired,
        "success": success, "server_key_saved": ctx.lua("server", f"return SO.pair.key({probe}) ~= nil"),
        "server_prompt_restored": restored}))
