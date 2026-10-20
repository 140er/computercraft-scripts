local Mocks=dofile("tests/mocks.lua")
local function run(autoCharge,enabled)
  local m=Mocks.new(false)
  local env=m.env
  local observed={ticks=0,locations=0}
  local pose={dim="minecraft:overworld",x=0,y=65,z=0,h=0}
  local values={enabled=enabled,warehouse=true,navigation=true,autoCharge=autoCharge,autoDropoff=true,
    chargerId=false,fuelTarget=4000,chargeTimeoutMs=12000}
  local bootstrap={enabled=true,server=7,dimension=pose.dim,key="paired-v2-key"}
  local worker={tick=function() observed.ticks=observed.ticks+1 return true end,
    state=function() return {phase="idle"} end}
  local nav={recover=function() return true end,configure=function() end,
    fleetPose=function() return {v=1,frame="abs",yAbs=true,dim=pose.dim,x=0,y=65,z=0,h=0,conf="certain",src="gps",anchoredAt=1} end}
  local fleet={ready=function() return true end,tick=function() return true end,
    settings=function() return values end,location=function(kind,from,selector)
      assert(kind=="charge" and from.frame=="abs" and selector==false)
      observed.locations=observed.locations+1
      return {siteNames={charge="server-charger"}}
    end}
  env.turtle={getItemCount=function() return 0 end,getFuelLevel=function() return 200 end,getFuelLimit=function() return 20000 end}
  env.sleep=function() coroutine.yield() end
  env.parallel.waitForAny=function(work)
    local co=coroutine.create(work)
    local ok,why=coroutine.resume(co)
    assert(ok,why)
  end
  env.dofile=function(path)
    if path=="atomic.lua" then return {read=function(file)
      if file=="wh2.cfg" then return bootstrap end
      return {server=99,secret="legacy-secret-value",dimension=pose.dim,pose=pose,bounds={min=pose,max=pose},charger="local-charger"}
    end} end
    if path=="ssot.lua" then return {pose=function() return true end} end
    if path=="ssot-client.lua" then return {new=function(config) observed.bootstrap=config return {} end} end
    if path=="wh2-client.lua" then return {new=function(options) observed.snapshot=options.snapshot return fleet end} end
    if path=="nav.lua" then return {open=function(options) observed.nav=options return nav end} end
    if path=="warehouse.lua" then return {open=function(options) observed.worker=options return worker end} end
    error(path)
  end
  assert(loadfile("store.lua","t",env))()
  assert(observed.bootstrap==bootstrap and observed.nav.beforeAction and observed.worker.settings)
  return observed
end
local observed=run(true,true)
assert(observed.ticks==1 and observed.locations==1 and observed.worker.charger=="server-charger")
assert(observed.worker.targetFuel==4000 and observed.worker.chargeTimeout==12000)
assert(observed.snapshot().pose.frame=="abs")
observed=run(false,true)
assert(observed.ticks==1 and observed.locations==0 and observed.worker.charger==nil)
observed=run(true,false)
assert(observed.ticks==0 and observed.locations==0)
print("PASS warehouse uses shared charging settings and refuses disabled work")
