local mocks=dofile("tests/mocks.lua")
local env=mocks.new(false).env
env.dofile=function(path) return assert(loadfile(path,"t",env))() end
local S,A=env.dofile("ssot.lua"),env.dofile("atomic.lua")
local clock,counters=10000,{}
local cfg={controllers={["1"]="test-secret-123456",["2"]="test-secret-123456",["3"]="test-secret-123456"}}
local api=S.new({},cfg,function() return clock end,"1")
local function p(x,y,z) return {dim="minecraft:overworld",x=x,y=y,z=z} end
local function call(id,op,fields)
  counters[id]=(counters[id] or 0)+1
  local m=A.copy(fields or {})
  m.v,m.type,m.expect,m.op=1,"ssot","ssot_reply",op
  m.boot,m.rid,m.counter="boot",id..":"..counters[id],counters[id]
  m.secret="test-secret-123456"
  return assert(api.handle(id,m)),m
end
local zone={min=p(0,64,1),max=p(11,66,5),spacing=4}
assert(call(1,"mine-config",{zone=zone}).ok,"configure bounded mine")
local tasks={}
for id=1,3 do
  assert(call(id,"sync",{pose=p(id*4-3,65,0)}).ok)
  local r,m=call(id,"mine-lease") assert(r.ok and r.task,"get distinct strip")
  tasks[id]=r.task
  assert(api.handle(id,m).task.token==r.task.token,"replayed lease changed task")
  assert(call(id,"mine-lease").task.token==r.task.token,"duplicate claim allocated another strip")
  assert(call(id,"mine-progress",{token=r.task.token,progress=0}).ok)
end
assert(tasks[1].max.x<tasks[2].min.x and tasks[2].max.x<tasks[3].min.x)
assert(not call(1,"mine-config",{zone=zone}).ok,"cannot replace occupied mine")
assert(not call(2,"mine-progress",{token=tasks[1].token,progress=1}).ok,"foreign token")
assert(call(1,"mine-progress",{token=tasks[1].token,progress=0}).ok)
clock=clock+31000
assert(not call(1,"mine-progress",{token=tasks[1].token,progress=1}).ok,"expired claim advanced")
assert(not call(2,"mine-renew",{token=tasks[1].token}).ok,"foreign renewal")
assert(call(1,"mine-renew",{token=tasks[1].token}).ok,"active owner could not renew")
api=S.new(api.state(),cfg,function() return clock end,"2")
local resumed=call(1,"mine-lease") assert(resumed.task.token==tasks[1].token,"lost active claim on restart")
assert(call(1,"mine-progress",{token=tasks[1].token,progress=2}).ok)
assert(not call(1,"mine-progress",{token=tasks[1].token,progress=1}).ok,"progress regressed")
assert(not call(1,"mine-finish",{token=tasks[1].token}).ok,"unfinished strip completed")
assert(call(1,"mine-progress",{token=tasks[1].token,progress=5}).ok)
assert(call(1,"mine-finish",{token=tasks[1].token}).ok)
assert(not call(1,"mine-lease").task,"duplicated exhausted strip")
assert(not call(1,"mine-progress",{token=tasks[1].token,progress=5}).ok,"stale finished token")
local state=api.state()
assert(state.mining.tasks[1].status=="done" and state.mining.tasks[1].progress==5)
print("PASS mining allocation, ownership, expiry, replay and restart")
local failures=0
dofile("tests/mining-checks.lua")(function(name,run)
  local ok,err=pcall(run)
  print((ok and "PASS " or "FAIL ")..name..(ok and "" or ": "..tostring(err)))
  if not ok then failures=failures+1 end
end,mocks)
assert(failures==0,failures.." mining failures")
