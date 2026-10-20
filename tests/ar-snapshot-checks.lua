local H=dofile("ar-hud.lua")
local UUID="00000000-0000-4000-8000-000000000001"
local auth={chatNames={"Jeffreyy2"},chatUUIDs={Jeffreyy2=UUID}}
local cfg=H.defaults()
cfg.enabled=true
cfg.ownerName,cfg.ownerUUID="Jeffreyy2",UUID
cfg.origin={dim="minecraft:overworld",x=0,y=64,z=0}
local state={rev=1,names={"minecraft:stone","minecraft:diamond_ore"},chunks={}}
for cx=0,3 do
  local cells={}
  for i=1,4096 do cells[i]=1 end
  state.chunks["minecraft:overworld|"..cx.."|4|0"]={cells=cells}
end
state.chunks["minecraft:overworld|3|4|0"].cells[1]=2
local snap=H.snapshot({},state,cfg,auth)
assert(#snap.world_map==1 and snap.world_map[1].x==48,
  "radius64 lost ore beyond the first two chunks")
state.chunks["minecraft:overworld|0|4|0"].cells[4]=2
state.chunks["minecraft:overworld|2|4|0"].cells[2]=2
state.chunks["minecraft:overworld|3|4|0"].cells[16]=2
for i=1,3 do state.chunks["minecraft:overworld|0|4|0"].cells[i]=0 end
cfg.maxCells,cfg.xrayTunnels=3,true
snap=H.snapshot({},state,cfg,auth)
assert(#snap.world_map==3 and snap.world_map[1].x==3 and snap.world_map[2].x==33
  and snap.world_map[3].x==48,"nearest ores must keep their budget ahead of nearer air")
assert(snap.truncated,"omitted eligible cells must be reported")
cfg.maxCells=8
state.chunks["minecraft:overworld|4|4|0"]={cells={[1]=2,[2]=2}}
snap=H.snapshot({},state,cfg,auth)
local at64,at65=false,false
for _,cell in ipairs(snap.world_map) do at64=at64 or cell.x==64 at65=at65 or cell.x==65 end
assert(at64 and not at65,"radius64 boundary must be inclusive")
local cache={}
local first=H.snapshot({},state,cfg,auth,cache)
local chunks=state.chunks
state.chunks=setmetatable({},{__pairs=function() error("unchanged map was rescanned") end})
local second=H.snapshot({{id=1,fuel=55}},state,cfg,auth,cache)
assert(second.world_map==first.world_map and second.turtles[1].fuel==55,
  "telemetry must refresh without rescanning unchanged chunks")
state.chunks=chunks
state.rev=2
chunks["minecraft:overworld|3|4|0"].cells[1]=1
snap=H.snapshot({},state,cfg,auth,cache)
for _,cell in ipairs(snap.world_map) do assert(cell.x~=48,"revision change reused stale ore") end
auth.chatUUIDs={}
assert(#H.snapshot({},state,cfg,auth,cache).world_map==0,
  "revoked shared authorization retained map cells")
print("PASS AR radius64, nearest ore priority, bounded map cache and revocation")
auth.chatUUIDs.Jeffreyy2=UUID
local dense={rev=3,names={"minecraft:diamond_ore"},chunks={}}
for cx=-4,3 do
  for cz=-4,3 do
    local cells={}
    for i=1,4096 do cells[i]=1 end
    dense.chunks["minecraft:overworld|"..cx.."|4|"..cz]={cells=cells}
  end
end
local yielded,queued=0,0
local env=setmetatable({os={
  queueEvent=function() queued=queued+1 end,
  pullEvent=function(filter) return coroutine.yield(filter) end,
}},{__index=_G})
local cooperative=assert(loadfile("ar-hud.lua","t",env))()
cfg.maxCells=256
local result
local scan=coroutine.create(function() result=cooperative.snapshot({},dense,cfg,auth) end)
local event
while coroutine.status(scan)~="dead" do
  local ok,filter=coroutine.resume(scan,event)
  assert(ok,filter)
  if coroutine.status(scan)~="dead" then
    yielded=yielded+1
    assert(type(filter)=="string" and queued>=yielded,"scan did not schedule its next work slice")
    event=filter
  end
end
assert(yielded>4 and yielded==queued,"full store traversal did not yield cooperatively")
assert(#result.world_map==256 and result.truncated,"full store exceeded its display budget")
local previous=-1
for _,cell in ipairs(result.world_map) do
  local distance=cell.x^2+(cell.y-64)^2+cell.z^2
  assert(distance>=previous,"nearest ore order changed with chunk iteration order")
  previous=distance
end
assert(result.world_map[1].x==0 and result.world_map[1].y==64 and result.world_map[1].z==0,
  "full store did not retain the nearest ore")
print("PASS AR 64-chunk traversal yields and keeps at most 256 nearest cells")
