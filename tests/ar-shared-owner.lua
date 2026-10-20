local H=dofile("ar-hud.lua")
local mocks=dofile("tests/mocks.lua")
local cfg=H.defaults()
local UUID="00000000-0000-4000-8000-000000000001"
local auth={chatNames={"Jeffreyy2"},chatUUIDs={Jeffreyy2=UUID}}
cfg.ownerName,cfg.ownerUUID="Jeffreyy2",UUID
cfg.enabled=true
cfg.origin={x=0,y=64,z=0,dim="minecraft:overworld"}
local snap={turtles={},world_map={{x=3,y=64,z=2,dim="minecraft:overworld",name="minecraft:diamond_ore"}}}
local empty={turtles={},world_map={}}
local ore="ssot-ar:ore:minecraft:overworld:3:64:2:edge:1"
local function controller()
  local m=mocks.new(true)
  m.reads=0
  m.ar.getAllElements=function()
    m.reads=m.reads+1
    return m.elements
  end
  m.elements.foreign=true
  return m
end
local m=controller()
local server,hub={},{}
H.render(m.ar,snap,server,cfg,auth)
assert(m.elements[ore],"server did not draw ore")
H.render(m.ar,empty,hub,cfg,auth)
assert(not m.elements[ore],"hub takeover retained dead server ore")
assert(m.elements.foreign,"hub deleted foreign element")
local calls,reads=#m.arCalls,m.reads
H.render(m.ar,empty,hub,cfg,auth)
assert(#m.arCalls==calls and m.reads==reads,"unchanged frame touched controller")
H.clear(m.ar,hub)
server={}
H.render(m.ar,snap,server,cfg,auth)
H.render(m.ar,empty,hub,cfg,auth)
assert(not m.elements[ore],"reacquisition retained server ore")
H.render(m.ar,snap,{},cfg,auth)
H.render(m.ar,empty,{},cfg,auth)
assert(not m.elements[ore],"restart retained prior owner ore")
local replacement=controller()
H.render(replacement.ar,snap,{},cfg,auth)
hub.reconciled=nil
for id in pairs(hub.elements) do hub.elements[id]={} end
H.render(replacement.ar,empty,hub,cfg,auth)
assert(not replacement.elements[ore],"replacement retained prior owner ore")
assert(replacement.elements.foreign and m.elements.foreign,"cleanup deleted foreign element")
print("PASS AR shared controller takeover, reacquisition, restart, replacement and stable frame")
