local mocks=dofile("tests/mocks.lua")
local e=mocks.new(false).env
e.dofile=function(path) return assert(loadfile(path,"t",e))() end
local S,A=e.dofile("ssot.lua"),e.dofile("atomic.lua")
local cfg={controllers={}}
for id=1,4 do cfg.controllers[tostring(id)]="test-secret-123456" end
local api=S.new({},cfg,function() return 10000 end,"1")
local counters={}
local function call(id,op,fields)
  counters[id]=(counters[id] or 0)+1
  local m=A.copy(fields or {})
  m.v,m.type,m.expect,m.op=1,"ssot","ssot_reply",op
  m.boot,m.rid,m.counter,m.secret="boot",id..":"..counters[id],counters[id],"test-secret-123456"
  return assert(api.handle(id,m)),m
end
local function site(x,kind)
  return {kind=kind,pose={dim="minecraft:overworld",x=x,y=65,z=0,h=2},side="front"}
end
assert(call(4,"wh-site",{name="source",site=site(0,"source")}).ok,"warehouse sites must be configurable")
assert(call(4,"wh-site",{name="drop",site=site(4,"drop")}).ok)
for id=1,3 do assert(call(id,"sync",{pose=site(id,"source").pose}).ok) end
assert(call(4,"wh-stock",{name="source",stock={["minecraft:iron_ingot"]=10}}).ok)
for i=1,2 do
  assert(call(4,"wh-order",{key="order"..i,drop="drop",lines={{item="minecraft:iron_ingot",count=8,source="source"}}}).ok)
end
local first=call(1,"wh-claim").job
local second=call(2,"wh-claim").job
assert(first.lines[1].count==8 and second.lines[1].count==2,"stock was over-reserved")
assert(call(1,"wh-claim").job.token==first.token,"duplicate claim changed order")
assert(not call(2,"wh-progress",{token=first.token,line=1,picked=8,delivered=8}).ok,"foreign progress")
assert(call(1,"wh-progress",{token=first.token,line=1,picked=8,delivered=0}).ok)
local ack,msg=call(1,"wh-progress",{token=first.token,line=1,picked=8,delivered=8})
assert(ack.ok and api.handle(1,msg).ok,"duplicate acknowledgement failed")
assert(not call(1,"wh-progress",{token=first.token,line=1,picked=7,delivered=7}).ok,"progress regressed")
api=S.new(api.state(),cfg,function() return 50000 end,"2")
assert(call(1,"wh-claim").job.token==first.token,"restart lost active owner")
assert(call(1,"wh-finish",{token=first.token}).ok)
assert(call(1,"wh-lock",{name="drop"}).ok)
assert(not call(2,"wh-lock",{name="drop"}).ok,"bay has two owners")
assert(call(1,"wh-unlock",{name="drop"}).ok)
assert(call(2,"wh-lock",{name="drop"}).ok)
assert(call(1,"wh-unlock",{name="drop"}).ok,"a lost unlock acknowledgement must be retryable")
assert(not call(3,"wh-lock",{name="drop"}).ok,"an old unlock released another owner's bay")
assert(not call(4,"wh-site",{name="drop",site=site(5,"drop")}).ok,"occupied site changed")
assert(not call(4,"wh-order",{key="bad",drop="drop",lines={{item="stone",count=-1,source="source"}}}).ok)
print("PASS warehouse stock reservations, partial allocation, replay, bays and restart")
local failures=0
dofile("tests/warehouse-checks.lua")(function(name,run)
  local ok,err=pcall(run)
  print((ok and "PASS " or "FAIL ")..name..(ok and "" or ": "..tostring(err)))
  if not ok then failures=failures+1 end
end,mocks)
assert(failures==0,failures.." warehouse failures")
