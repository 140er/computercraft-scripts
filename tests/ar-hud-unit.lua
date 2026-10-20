local H = dofile("ar-hud.lua")
local mocks = dofile("tests/mocks.lua")
local m = mocks.new(true)
local cfg = H.defaults()
local mem = {}
local snap = { turtles = {
  { id=1,name="Miner",phase="mining",fuel=100,maxFuel=1000,x=1,y=64,z=2,dim="minecraft:overworld" },
  { id=2,name="Other dimension",fuel=900,x=1,y=64,z=2,dim="minecraft:the_nether" },
}, world_map = {
  { x=3,y=64,z=2,dim="minecraft:overworld",name="minecraft:diamond_ore" },
  { x=4,y=64,z=2,dim="minecraft:overworld",state="AIR" },
}, anchors = { hub={x=0,y=64,z=0,dim="minecraft:overworld"} } }
H.render(m.ar,snap,mem,cfg)
assert(#m.arCalls==0,"default disabled must not touch controller")
cfg.enabled=true
cfg.origin={x=0,y=64,z=0,dim="minecraft:overworld"}
H.render(m.ar,snap,mem,cfg)
assert(m.elements["ssot-ar:card:1:fuel"],"fuel bar missing")
assert(m.elements["ssot-ar:alert:text"],"low fuel alert missing")
assert(m.elements["ssot-ar:turtle:1:edge:1"],"turtle box missing")
assert(not m.elements["ssot-ar:turtle:2:edge:1"],"wrong dimension drawn")
assert(m.elements["ssot-ar:ore:minecraft:overworld:3:64:2:edge:1"],"ore box missing")
assert(m.elements["ssot-ar:anchor:hub:beam"],"anchor beam missing")
local calls=#m.arCalls
H.render(m.ar,snap,mem,cfg)
assert(#m.arCalls==calls,"unchanged frame generated peripheral traffic")
H.toggle(cfg,"t")
H.render(m.ar,snap,mem,cfg)
assert(not m.elements["ssot-ar:turtle:1:edge:1"],"disabled turtle layer retained box")
H.toggle(cfg,"a")
H.render(m.ar,snap,mem,cfg)
assert(m.elements["ssot-ar:air:minecraft:overworld:4:64:2:edge:1"],"air layer missing")
m.elements["foreign"]=true
H.clear(m.ar,mem)
assert(m.elements.foreign,"cleanup cleared another producer")
for _,call in ipairs(m.arCalls) do assert(call.method~="clear","global clear called") end
cfg.origin=nil
H.render(m.ar,snap,mem,cfg)
assert(not m.elements["ssot-ar:ore:minecraft:overworld:3:64:2:edge:1"],"unknown origin emitted world geometry")
local state={poses={[1]={x=-1,y=64,z=2,dim="minecraft:overworld"}},names={"minecraft:diamond_ore"},
  chunks={["minecraft:overworld|-1|4|0"]={cells={[48]=1}}}}
cfg.origin={x=0,y=64,z=0,dim="minecraft:overworld"}
local decoded=H.snapshot(snap.turtles,state,cfg)
assert(decoded.turtles[1].x==-1,"authoritative pose not used")
assert(decoded.world_map[1].x==-1 and decoded.world_map[1].z==2,"negative chunk decode failed")
cfg.followTarget=2
cfg.xrayTurtles=true
H.render(m.ar,snap,mem,cfg)
assert(m.elements["ssot-ar:turtle:2:edge:1"],"follow target dimension not selected")
assert(not m.elements["ssot-ar:ore:minecraft:overworld:3:64:2:edge:1"],"follow target leaked previous dimension")
snap.turtles[2].stale=true
H.render(m.ar,snap,mem,cfg)
assert(not m.elements["ssot-ar:turtle:2:edge:1"],"stale follow target emitted geometry")
cfg.followTarget=nil
snap.turtles[2].stale=nil
print("PASS AR HUD defaults, layers, dimension, diff, cleanup, SSOT decode")
local HM=assert(loadfile("ar-hud.lua","t",m.env))()
local settings,save=HM.settings()
assert(HM.command(settings,{"enable","on"},save))
assert(HM.command(settings,{"origin","minecraft:overworld","0","64","0"},save))
assert(HM.settings().enabled,"enabled setting did not survive restart")
local actions={}
local controls=HM.controls(settings,save,function(action) actions[#actions+1]=action return true,"queued" end,function() end)
assert(controls.key("h") and #actions==0,"first H executed without confirmation")
assert(controls.key("h") and actions[1]=="hub","second H did not dispatch")
assert(controls.key("r") and #actions==1,"first R executed without confirmation")
assert(controls.key("r") and actions[2]=="recharge","second R did not dispatch")
local persisted=HM.memory("ar-test.ids")
HM.render(m.ar,snap,persisted,settings)
assert(m.files["ar-test.ids"],"IDs not persisted")
local restarted=HM.memory("ar-test.ids")
HM.render(m.ar,{turtles={},world_map={},anchors={}},restarted,settings)
assert(not m.elements["ssot-ar:turtle:1:edge:1"],"restart retained obsolete world geometry")
assert(m.elements.foreign,"restart removed foreign element")
print("PASS AR config persistence, confirmed keys, restart cleanup")
