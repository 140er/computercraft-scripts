"""Wait for the product's start checks, then verify that START was accepted."""
import json

from .model import Blocked

# A tall setup frame keeps all READY checks on one page. Read the product's
# count rather than maintaining a second copy of its readiness rules.
SNAPSHOT = '''local role=ROLE
local mod=SO.mods[role=="mining" and "mine" or role]
local screen=assert(SO.mods.display.screen(role))
local frame=screen.render(120,80,{id="gateb-readiness",[role]={page="setup"}})
local checks,passed,total={},nil,nil
for i,row in ipairs(frame.rows) do
  local text=row.text:sub(62)
  if i==3 then passed,total=text:match("READY.-(%d+)/(%d+)")
  elseif i>3 and i<76 and text:match("%S") then checks[#checks+1]=text end
end
passed,total=tonumber(passed),tonumber(total)
local disk,reason=SO.mods.state.canStart()
local workers,known={},true
for id,row in pairs(mod.turtleView()) do
  local status=SO.mods.lease.status(tonumber(id))
  local ok=type(row.fuel)=="number" and row.fuel~=0 and row.pose~=nil
    and SO.pair.key(tonumber(id))~=nil and not status.uncertain and not status.lost
  workers[id]={fuel=row.fuel,ready=ok==true}
  known=known and ok
end
return {ready=disk==true and total~=nil and total>0 and passed==total and known==true
    and next(workers)~=nil,disk_ready=disk==true,disk_reason=reason,
  passed=passed,total=total,checks=checks,workers=workers,running=mod.mapView().running==true,
  alert=SO.mods.state.get(role=="mining" and "mine.alert" or "lumber.alert")}
'''


def snapshot(ctx, role, start=False):
    code = SNAPSHOT.replace("ROLE", json.dumps(role))
    if start:
        code = 'SO.mods.display.screen(' + json.dumps(role) + ').input({text="start"});' + code
    return ctx.lua("server", code)


def start_job(ctx, role):
    if role not in ("mining", "lumber"):
        raise ValueError("Readiness is only defined for mining and lumber")
    for attempt in (1, 2):
        latest = None

        def ready():
            nonlocal latest
            latest = snapshot(ctx, role)
            return latest if latest.get("ready") else None

        if not ctx.wait(ready, 60):
            ctx.record(f"{role}-start-{attempt}-readiness.json", latest)
            raise Blocked(f"{role} readiness did not arrive before START")
        ctx.record(f"{role}-start-{attempt}-readiness.json", latest)
        result = ctx.record(f"{role}-start-{attempt}-result.json", snapshot(ctx, role, start=True))
        if result.get("running"):
            return
        # START checks disk admission before readiness. Retry a readiness refusal
        # once after fresh reports; preserve disk refusals and persistent failures.
        if attempt == 2 or not result.get("disk_ready") or result.get("ready"):
            raise Blocked(f"{role} START refused; see {role}-start-{attempt}-result.json")
