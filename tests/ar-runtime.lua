local checks={}
if fs.exists("checks.json") then
  local h=assert(fs.open("checks.json","r")) checks=textutils.unserializeJSON(h.readAll()) h.close()
end
local serial=0
local function check(name,fn)
  local ok,err=pcall(fn)
  checks[#checks+1]={name=name,ok=ok,error=not ok and tostring(err) or nil}
  local h=assert(fs.open("checks.json","w")) h.write(textutils.serializeJSON(checks)) h.close()
  assert(ok,name..": "..tostring(err))
end
local function request(peer,op)
  serial=serial+1
  local deadline=os.clock()+30
  repeat
    rednet.send(peer,{op=op,rid=serial},"ar_test")
    local from,msg=rednet.receive("ar_reply",1)
    if from==peer and msg.rid==serial then return msg end
  until os.clock()>deadline
  error("owner response timeout: "..peer)
end
local function hud(state)
  for _,id in ipairs(state.ids) do if id:find("ssot-ar:",1,true) then return true end end
  return false
end
local function untilOwner(owner,other)
  local deadline=os.clock()+60
  repeat
    local current,standby=request(owner,"inspect"),request(other,"inspect")
    if hud(current) and not hud(standby) then
      assert(current.rejected==0 and standby.rejected==0)
      return
    end
    sleep(1)
  until os.clock()>deadline
  error("owner "..owner.." did not draw alone")
end
if not fs.exists("restart-ready.json") then
check("AR feature assertions on CraftOS Lua",function() dofile("tests/ar-hud-unit.lua") end)
local function read(path)
  local h=assert(fs.open(path,"r")) local text=h.readAll() h.close() sleep(0) return text
end
for _,path in ipairs({"tests/chat-checks.lua","tests/install-checks.lua"}) do
  assert(loadfile(path,"t",_ENV))()(check,read,dofile("tests/mocks.lua"))
end
check("HUD keys persist layers and require confirmation for travel",function()
  local H=dofile("ar-hud.lua")
  local cfg=H.defaults() cfg.enabled=true
  local actions,saves={},0
  local controls=H.controls(cfg,function() saves=saves+1 return true end,
    function(action) actions[#actions+1]=action return true end,function() end)
  for key,field in pairs({p="proHud",t="xrayTurtles",o="xrayOres",a="xrayTunnels"}) do
    local before=cfg[field]
    assert(controls.key(key))
    assert(cfg[field]~=before,"layer did not toggle")
  end
  assert(saves==4)
  controls.key("h") assert(#actions==0)
  controls.key("h") assert(actions[1]=="hub")
  controls.key("r") assert(#actions==1)
  controls.key("r") assert(actions[2]=="recharge")
  local failed=H.controls(cfg,function() return false,"disk full" end,function() end,function() end)
  local before=cfg.proHud
  failed.key("p") assert(cfg.proHud==before,"failed save changed layer")
end)
check("UUID authorization and one-use public confirmation",function()
  local uuid="00000000-0000-4000-8000-000000000001"
  local cfg={chatEnabled=true,chatAllowlist={[uuid]="Jeffreyy2"}}
  local replies,actions={},{}
  local chat=dofile("chat-control.lua").new(cfg,{
    save=function() return true end,
    reply=function(_,text) replies[#replies+1]=text end,
    execute=function(action) actions[#actions+1]=action return true end,
    now=function() return 1000 end,
  })
  chat:event("chat","Jeffreyy2","!hub","00000000-0000-4000-8000-000000000002",false)
  assert(#actions==0 and #replies==0,"display name authorized an intruder")
  chat:event("chat","Jeffreyy2","!hub",uuid,false)
  assert(#actions==0,"public chat bypassed confirmation")
  local token=assert(replies[#replies]:match("!confirm%s+(%S+)"))
  chat:event("chat","Jeffreyy2","!confirm "..token,uuid,false)
  assert(#actions==1 and actions[1]=="hub","confirmed action was not delivered")
  chat:event("chat","Jeffreyy2","!confirm "..token,uuid,false)
  assert(#actions==1,"confirmation replay delivered twice")
end)
check("server owns HUD while hub stays suppressed",function()
  untilOwner(0,5)
end)
check("hub takes over after server controller detaches",function()
  request(0,"detach")
  sleep(19)
  assert(hud(request(5,"inspect")),"hub did not take over")
end)
check("server reclaims HUD after controller reattaches",function()
  request(0,"attach")
  untilOwner(0,5)
end)
local restart=assert(fs.open("restart-ready.json","w")) restart.write("{}") restart.close()
while true do sleep(1) end
end
check("server and hub recover ownership after process restart",function()
  sleep(12)
  untilOwner(0,5)
end)
request(0,"done")
request(5,"done")
local h=assert(fs.open("sandbox-result.json","w"))
h.write(textutils.serializeJSON({ok=true,booted=true,errors={},lines={"owner detach and reattach passed",
  "HUD, x-ray, UUID checks passed"},free=fs.getFreeSpace("/")})) h.close()
