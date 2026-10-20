local H = dofile("ar-hud.lua")
local mocks = dofile("tests/mocks.lua")
local m = mocks.new(true)
local cfg = H.defaults()
local UUID="00000000-0000-4000-8000-000000000001"
local auth={chatNames={"Jeffreyy2"},chatUUIDs={Jeffreyy2=UUID}}
cfg.ownerName,cfg.ownerUUID="Jeffreyy2",UUID
local mem = {}
local snap = { turtles = {
  { id=1,name="Miner",phase="mining",fuel=100,maxFuel=1000,x=1,y=64,z=2,dim="minecraft:overworld" },
  { id=2,name="Other dimension",fuel=900,x=1,y=64,z=2,dim="minecraft:the_nether" },
}, world_map = {
  { x=3,y=64,z=2,dim="minecraft:overworld",name="minecraft:diamond_ore" },
  { x=4,y=64,z=2,dim="minecraft:overworld",state="AIR" },
}, anchors = { hub={x=0,y=64,z=0,dim="minecraft:overworld"} } }
H.render(m.ar,snap,mem,cfg,auth)
assert(#m.arCalls==0,"default disabled must not touch controller")
cfg.enabled=true
cfg.origin={x=0,y=64,z=0,dim="minecraft:overworld"}
H.render(m.ar,snap,mem,cfg,auth)
assert(m.elements["ssot-ar:card:1:fuel"],"fuel bar missing")
assert(m.elements["ssot-ar:alert:text"],"low fuel alert missing")
assert(m.elements["ssot-ar:turtle:1:edge:1"],"turtle box missing")
assert(not m.elements["ssot-ar:turtle:2:edge:1"],"wrong dimension drawn")
assert(m.elements["ssot-ar:ore:minecraft:overworld:3:64:2:edge:1"],"ore box missing")
assert(m.elements["ssot-ar:anchor:hub:beam"],"anchor beam missing")
local calls=#m.arCalls
H.render(m.ar,snap,mem,cfg,auth)
assert(#m.arCalls==calls,"unchanged frame generated peripheral traffic")
H.toggle(cfg,"T",auth)
H.render(m.ar,snap,mem,cfg,auth)
assert(not m.elements["ssot-ar:turtle:1:edge:1"],"disabled turtle layer retained box")
H.toggle(cfg,"A",auth)
H.render(m.ar,snap,mem,cfg,auth)
assert(m.elements["ssot-ar:air:minecraft:overworld:4:64:2:edge:1"],"air layer missing")
m.elements["foreign"]=true
H.clear(m.ar,mem)
assert(m.elements.foreign,"cleanup cleared another producer")
for _,call in ipairs(m.arCalls) do assert(call.method~="clear","global clear called") end
cfg.origin=nil
H.render(m.ar,snap,mem,cfg,auth)
assert(not m.elements["ssot-ar:ore:minecraft:overworld:3:64:2:edge:1"],"unknown origin emitted world geometry")
local state={poses={[1]={x=-1,y=64,z=2,dim="minecraft:overworld"}},names={"minecraft:diamond_ore"},
  chunks={["minecraft:overworld|-1|4|0"]={cells={[48]=1}}}}
cfg.origin={x=0,y=64,z=0,dim="minecraft:overworld"}
local decoded=H.snapshot(snap.turtles,state,cfg,auth)
assert(decoded.turtles[1].x==-1,"authoritative pose not used")
assert(decoded.world_map[1].x==-1 and decoded.world_map[1].z==2,"negative chunk decode failed")
cfg.followTarget=2
cfg.xrayTurtles=true
H.render(m.ar,snap,mem,cfg,auth)
assert(m.elements["ssot-ar:turtle:2:edge:1"],"follow target dimension not selected")
assert(not m.elements["ssot-ar:ore:minecraft:overworld:3:64:2:edge:1"],"follow target leaked previous dimension")
snap.turtles[2].stale=true
H.render(m.ar,snap,mem,cfg,auth)
assert(not m.elements["ssot-ar:turtle:2:edge:1"],"stale follow target emitted geometry")
cfg.followTarget=nil
snap.turtles[2].stale=nil
print("PASS AR HUD defaults, layers, dimension, diff, cleanup, SSOT decode")
local HM=assert(loadfile("ar-hud.lua","t",m.env))()
local settings,save=HM.settings()
assert(HM.command(settings,{"enable","on"},save))
assert(HM.command(settings,{"origin","minecraft:overworld","0","64","0"},save))
assert(HM.command(settings,{"owner","Jeffreyy2",UUID},save,auth))
assert(HM.settings().enabled,"enabled setting did not survive restart")
local actions={}
local controls=HM.controls(settings,save,function(action) actions[#actions+1]=action return true,"queued" end,function() end,auth)
for _,key in ipairs({"h","r","a","p","t","o","s","u","c","v","w","q"}) do
  assert(not controls.key(key),"AR consumed existing hub key "..key)
end
assert(#actions==0,"AR layer keys dispatched travel")
assert(controls.key("P") and settings.proHud==false,"shifted HUD key did not toggle")
local persisted=HM.memory("ar-test.ids")
HM.render(m.ar,snap,persisted,settings,auth)
assert(m.files["ar-test.ids"],"IDs not persisted")
local restarted=HM.memory("ar-test.ids")
HM.render(m.ar,{turtles={},world_map={},anchors={}},restarted,settings,auth)
assert(not m.elements["ssot-ar:turtle:1:edge:1"],"restart retained obsolete world geometry")
assert(m.elements.foreign,"restart removed foreign element")
HM.render(m.ar,snap,restarted,settings,auth)
assert(m.elements["ssot-ar:ore:minecraft:overworld:3:64:2:edge:1"],"authorized ore missing")
auth.chatUUIDs={}
HM.render(m.ar,snap,restarted,settings,auth)
assert(not m.elements["ssot-ar:ore:minecraft:overworld:3:64:2:edge:1"],"revoked owner retained ore")
assert(not m.elements["ssot-ar:turtle:1:edge:1"],"revoked owner retained turtle geometry")
assert(not m.elements["ssot-ar:anchor:hub:beam"],"revoked owner retained world anchor")
assert(not HM.toggle(settings,"O",auth),"revoked owner changed ore layer")
assert(not HM.command(settings,{"owner","Jeffreyy2",UUID},save,auth),"unlisted owner was enrolled")
settings.enabled=false
HM.render(m.ar,snap,restarted,settings,auth)
assert(not next(restarted.elements),"disabled HUD retained its elements")
assert(m.elements.foreign,"disabled HUD removed another producer")
print("PASS AR owner authorization, preserved hub keys, config persistence and restart cleanup")
