local H = dofile("ar-hud.lua")
local mocks = dofile("tests/mocks.lua")
local m = mocks.new(true)
local cfg = H.defaults()
local UUID="00000000-0000-4000-8000-000000000001"
assert(cfg.enabled==true,"AR defaults on")
assert(cfg.chatEnabled==nil,"chat stays off")
local auth={chatNames={"Jeffreyy2"},chatUUIDs={Jeffreyy2=UUID}}
cfg.ownerName,cfg.ownerUUID="Jeffreyy2",UUID
cfg.enabled=false
local mem = {}
local snap = { turtles = {
  { id=1,name="Miner",phase="mining",fuel=100,maxFuel=1000,x=1,y=64,z=2,dim="minecraft:overworld" },
  { id=2,name="Other dimension",fuel=900,x=1,y=64,z=2,dim="minecraft:the_nether" },
}, world_map = {
  { x=3,y=64,z=2,dim="minecraft:overworld",name="minecraft:diamond_ore" },
  { x=4,y=64,z=2,dim="minecraft:overworld",state="AIR" },
}, anchors = { hub={x=0,y=64,z=0,dim="minecraft:overworld"} } }
H.render(m.ar,snap,mem,cfg,auth)
assert(#m.arCalls==0,"explicit false must not touch controller")
cfg.enabled=true
cfg.origin={x=0,y=64,z=0,dim="minecraft:overworld"}
H.render(m.ar,snap,mem,cfg,auth)
assert(m.elements["ssot-ar:card:1:fuel"],"fuel bar missing")
assert(m.elements["ssot-ar:footer:depth"].args[5]=="Outlines stop at blocks","HUD hid the depth-test limit")
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

local bare={turtles={
  {id=9,name="Rack",status="Waiting for orders",y=19},
  {id=10,name="Fix",status="Waiting for orders",x=-170,y=19,z=-690},
  {id=11,name="Reckoned",status="Waiting for orders",pose={x=-172,y=19,z=-692,conf="suspect",src="reckoned"}},
  {id=12,name="Lost",status="Waiting for orders",pose={x=-171,y=19,z=-691,conf="lost",src="reckoned"}},
},world_map={},anchors={}}
local placedCfg={enabled=true,dimension="minecraft:overworld",ownerName="Jeffreyy2",ownerUUID=UUID,
  origin={x=-174,y=19,z=-695,dim="minecraft:overworld"},proHud=true,xrayTurtles=true,xrayOres=true}
local placedAuth={chatNames={"Jeffreyy2"},chatUUIDs={Jeffreyy2=UUID}}
local placedMem={}
H.render(m.ar,bare,placedMem,placedCfg,placedAuth)
assert(m.elements["ssot-ar:turtle:10:edge:1"],"missing dimension was dropped")
assert(m.elements["ssot-ar:turtle:11:edge:1"],"dead-reckoned pose was dropped")
assert(m.elements["ssot-ar:radar:turtle:10"],"radar dropped a turtle with no dimension")
assert(m.elements["ssot-ar:radar:turtle:11"],"radar dropped a reckoned turtle")
assert(not m.elements["ssot-ar:turtle:9:edge:1"],"unknown position invented a box")
assert(not m.elements["ssot-ar:turtle:12:edge:1"],"lost pose was drawn")
local function nearHub(el, ox, oy, oz)
  assert(el,"missing hub marker")
  local x,y,z=el.args[3],el.args[4],el.args[5]
  assert((x-ox)^2+(y-oy)^2+(z-oz)^2<4,"marker left the hub")
  assert(x~=-171 and z~=-691,"lost pose was drawn")
end
nearHub(m.elements["ssot-ar:turtle:9:unknown"],-174,19,-695)
nearHub(m.elements["ssot-ar:turtle:12:unknown"],-174,19,-695)
assert(m.elements["ssot-ar:turtle:9:unknown:label"].args[9]:find("#9 unknown",1,true),"unknown label missing")
assert(m.elements["ssot-ar:turtle:12:unknown:label"].args[9]:find("unknown",1,true),"lost turtle got no unknown marker")
assert(m.elements["ssot-ar:card:9:state"].args[5]:find("unknown",1,true),"unknown turtle vanished from the HUD")
assert(m.elements["ssot-ar:card:12:state"].args[5]:find("unknown",1,true),"lost turtle vanished from the HUD")
assert(not m.elements["ssot-ar:radar:missing"],"hub markers were still counted as missing")
assert(m.elements["ssot-ar:radar:turtle:9"],"radar hid the hub marker")
assert(m.elements["ssot-ar:card:11:state"].args[5]:find("suspect",1,true),"suspect fix was silent")
assert(not m.elements["ssot-ar:footer"],"hint listed controls that are not wired")
placedCfg.input={keys=true,touch=true,server=false}
H.render(m.ar,bare,placedMem,placedCfg,placedAuth)
assert(m.elements["ssot-ar:footer"].args[5]=="Shift+P HUD | Shift+T turtles | Shift+O ore | Shift+A air",
  "working keys were hidden")
placedAuth.chatUUIDs={}
H.render(m.ar,bare,placedMem,placedCfg,placedAuth)
assert(m.elements["ssot-ar:footer"].args[5]=="Shift+P HUD","unauthorized xray keys were offered")
assert(not m.elements["ssot-ar:turtle:10:edge:1"],"unauthorized owner kept turtle boxes")
placedCfg.input={keys=false,touch=true,server=false}
H.render(m.ar,bare,placedMem,placedCfg,placedAuth)
assert(m.elements["ssot-ar:footer"].args[5]=="Tap HUD","monitor hint offered shift keys")
placedCfg.input={keys=true,touch=false,server=true}
H.render(m.ar,bare,placedMem,placedCfg,placedAuth)
assert(not m.elements["ssot-ar:footer"],"server-owned hint offered controls the queue would reject")
local originCfg={enabled=true,dimension="minecraft:overworld"}
assert(H.ensureOrigin(originCfg,{x=-174,y=19,z=-695}))
assert(originCfg.origin.dim=="minecraft:overworld" and originCfg.origin.x==-174,"hub position did not become the origin")
assert(not H.ensureOrigin(originCfg,{x=1,y=2,z=3}),"a saved origin was replaced")
local paired={enabled=true,dimension="minecraft:overworld"}
assert(H.ensureOrigin(paired,{pos={x=4,y=5,z=6,dim="minecraft:the_nether"}}))
assert(paired.origin.dim=="minecraft:the_nether" and paired.origin.z==6,"paired position was ignored")
assert(not H.ensureOrigin({enabled=false,dimension="minecraft:overworld"},{x=1,y=2,z=3}))
assert(H.layerKey("char","P")=="P" and H.layerKey("char","p")==nil)
assert(H.layerKey("key","p",true)=="P" and H.layerKey("key","p",false)==nil)
assert(H.layerKey("key","t",true)=="T" and H.layerKey("monitor_touch","P")==nil)
local openAuth={chatNames={"Jeffreyy2"},chatUUIDs={Jeffreyy2=UUID}}
local remembered={}
local moved={turtles={{id=4,name="Was",x=5,y=64,z=6,dim="minecraft:overworld"}},world_map={},anchors={}}
local stay={enabled=true,dimension="minecraft:overworld",ownerName="Jeffreyy2",ownerUUID=UUID,
  origin={x=0,y=64,z=0,dim="minecraft:overworld"},proHud=true,xrayTurtles=true}
H.render(m.ar,moved,remembered,stay,openAuth)
assert(m.elements["ssot-ar:turtle:4:edge:1"].args[3]==5,"first fix missing")
moved.turtles[1]={id=4,name="Was",y=64}
H.render(m.ar,moved,remembered,stay,openAuth)
assert(m.elements["ssot-ar:turtle:4:edge:1"].args[3]==5 and m.elements["ssot-ar:turtle:4:edge:1"].args[5]==6,
  "last known position was dropped")
assert(m.elements["ssot-ar:turtle:4:label"].args[9]:find("~",1,true),"approx marker was unmarked")
local homed={turtles={{id=5,name="Den",home={x=10,y=70,z=20},rel={x=1,y=-2,z=3}}},world_map={},anchors={}}
H.render(m.ar,homed,{},stay,openAuth)
local homeEdge=m.elements["ssot-ar:turtle:5:edge:1"]
assert(homeEdge and homeEdge.args[3]==11 and homeEdge.args[4]==68 and homeEdge.args[5]==23,
  "home-relative position was dropped")
local nowhere={enabled=true,dimension="minecraft:overworld",ownerName="Jeffreyy2",ownerUUID=UUID,
  proHud=true,xrayTurtles=true}
H.render(m.ar,{turtles={{id=8,name="Blank",y=3}},world_map={},anchors={}},{},nowhere,openAuth)
assert(not m.elements["ssot-ar:turtle:8:unknown"],"missing hub invented a marker")
assert(m.elements["ssot-ar:card:8:state"].args[5]:find("no position",1,true),"blank turtle vanished")
local cycleCfg=H.defaults()
cycleCfg.ownerName,cycleCfg.ownerUUID="Jeffreyy2",UUID
assert(H.nextLayer(cycleCfg,openAuth,nil)=="P","cycle skipped the HUD")
assert(H.toggle(cycleCfg,"P",openAuth) and cycleCfg.proHud==false)
assert(H.nextLayer(cycleCfg,openAuth,"P")=="T","cycle did not advance")
assert(H.gesture("playerClick","Jeffreyy2","Jeffreyy2")=="cycle","owner click was ignored")
assert(H.gesture("playerClick","njov10","Jeffreyy2")==nil,"another player cycled the layers")
assert(H.gesture("chat","$ar xray","Jeffreyy2")==nil,"chat became a layer control")
assert(cycleCfg.chatEnabled==nil,"layer cycle enabled chat")
local rose,levels=H.redstoneRise({},function(side) return side=="top" end)
assert(rose and levels.top,"button rise was ignored")
rose,levels=H.redstoneRise(levels,function(side) return side=="top" end)
assert(not rose,"held button cycled again")
rose,levels=H.redstoneRise(levels,function() return false end)
assert(not rose,"button release cycled")
rose=H.redstoneRise(levels,function(side) return side=="front" or side=="back" end)
assert(not rose,"two sides rising counted as one button")
local gcfg=H.defaults()
gcfg.ownerName,gcfg.ownerUUID="Jeffreyy2",UUID
local savedRedstone=redstone
redstone={getInput=function() return false end}
local gesture=H.gestureState()
local seen={}
local function apply(letter)
  seen[#seen+1]=letter
  return H.toggle(gcfg,letter,openAuth)
end
assert(H.feed(gesture,"playerClick","Jeffreyy2",gcfg,openAuth,apply) and seen[1]=="P" and gcfg.proHud==false,
  "owner click did not cycle the HUD")
assert(not H.feed(gesture,"playerClick","njov10",gcfg,openAuth,apply),"another player cycled the layers")
redstone.getInput=function(side) return side=="top" end
assert(H.feed(gesture,"redstone",nil,gcfg,openAuth,apply) and seen[2]=="T","button did not cycle the next layer")
assert(not H.feed(gesture,"redstone",nil,gcfg,openAuth,apply),"held button cycled again")
redstone=savedRedstone
assert(gcfg.chatEnabled==nil,"gesture enabled chat")
local lights=H.lights(gcfg)
assert(lights.P==false and lights.T==false and lights.O==true,"layer lights hid the toggled rows")
local pro=H.inputMode(false,"pro",false)
local mapped=H.inputMode(false,"map",false)
local wizard=H.inputMode(true,"pro",true)
assert(pro.touch==true and pro.keys==true and mapped.touch==false and wizard.touch==false and wizard.server==true,
  "pro touch was hidden")
print("PASS AR positions, honest hints, origin and layer keys")
