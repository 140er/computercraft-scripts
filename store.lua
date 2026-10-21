local args={...}
local A,S=dofile("atomic.lua"),dofile("ssot.lua")
local function unwrap(raw)
  if type(raw)~="table" then return raw end
  if (raw.v==1 or raw.schema==1) and type(raw.value)=="table" then return raw.value end
  return raw
end
local cfg=unwrap(A.read("warehouse.cfg")) or {enabled=false}
local fleetBootstrap=unwrap(A.read("wh2.cfg")) or {enabled=false}
local fleetEnabled=fleetBootstrap.enabled==true
if fleetEnabled then
  cfg.server,cfg.dimension=fleetBootstrap.server,fleetBootstrap.dimension
end
local cfgRec
local function save()
  cfgRec=cfgRec or A.mount("/"):open("warehouse.cfg",function(v) return type(v)=="table" end,{class="control",limit=8192})
  assert(cfgRec:save(cfg))
end
local function plugmod()
  if not (fs and fs.exists and fs.exists("plug.lua")) then return nil end
  local ok, mod = pcall(dofile, "plug.lua")
  if ok and type(mod) == "table" then return mod end
end
local function pairSecret(plug, explicit, serverId)
  local env = { peripheral = peripheral, rednet = rednet, gps = gps }
  return plug.takeSecret(explicit, plug.savedPairing(), function()
    local code = plug.ask(plug.termio(), {
      title = "Warehouse", kind = "text",
      question = "Type the id and the code from the server",
      hint = "One line, the id and the code.",
    })
    if not code or not fs.exists("enrol.lua") then return nil end
    local loaded, Enrol = pcall(dofile, "enrol.lua")
    if not loaded then return nil end
    return plug.claim(Enrol, plug.rpc(env, serverId), code, os.getComputerID())
  end)
end
local function pose(offset)
  local p={dim=assert(cfg.dimension,"configure the server and dimension first"),x=tonumber(args[offset]),y=tonumber(args[offset+1]),z=tonumber(args[offset+2])}
  assert(S.pose(p),"integer world coordinates required") return p
end
if args[1]=="install" then
  local f=assert(fs.open("startup.lua","w")) f.write('shell.run("store")\n') f.close() print("Warehouse starts on boot") return
elseif args[1]=="update" then shell.run("update") return
elseif args[1]=="server" then
  local plug = plugmod()
  local id = tonumber(args[2])
  if not id and plug then
    local env = { peripheral = peripheral, rednet = rednet, gps = gps }
    id = plug.fill(nil, nil, function() return plug.lookup(env, "fleetserver", "server") end, function(spec)
      spec.title, spec.question = "Warehouse", "Fleet server id"
      spec.kind = spec.kind or "number"
      return plug.ask(plug.termio(), spec)
    end)
  end
  local secret = args[3]
  if type(secret) ~= "string" and plug then secret = pairSecret(plug, nil, id) end
  local dimension = args[4] or cfg.dimension
  if type(dimension) ~= "string" and plug then
    dimension = plug.ask(plug.termio(), {
      title = "Warehouse", kind = "text", question = "Dimension", default = "minecraft:overworld",
    })
  end
  cfg.server,cfg.secret,cfg.dimension=id,secret,dimension
  assert(cfg.server and cfg.server%1==0 and cfg.server>=0 and type(cfg.secret)=="string" and #cfg.secret>=16
    and S.pose({dim=cfg.dimension,x=0,y=64,z=0}),"server ID, paired secret and dimension required")
  save() print("Warehouse server saved") return
elseif args[1]=="pose" then
  if not args[2] then
    local plug = plugmod()
    local fix = plug and plug.place({ gps = gps, peripheral = peripheral, rednet = rednet }, function(spec)
      spec.title = "Warehouse"
      return plug.ask(plug.termio(), spec)
    end, "Warehouse")
    if fix then args[2], args[3], args[4] = fix.x, fix.y, fix.z end
    if not args[5] then args[5] = 0 end
  end
  cfg.pose=pose(2) cfg.pose.h=tonumber(args[5]) assert(cfg.pose.h and cfg.pose.h%1==0 and cfg.pose.h>=0 and cfg.pose.h<4,"heading must be 0 through 3")
  save() print("Warehouse pose saved") return
elseif args[1]=="bounds" then
  cfg.bounds={min=pose(2),max=pose(5)}
  assert(cfg.bounds.min.x<=cfg.bounds.max.x and cfg.bounds.min.y<=cfg.bounds.max.y and cfg.bounds.min.z<=cfg.bounds.max.z,"bounds are reversed")
  save() print("Warehouse bounds saved") return
elseif args[1]=="enable" or args[1]=="disable" then
  assert(args[1]=="disable" or cfg.pose and cfg.bounds and cfg.server and cfg.secret,"configure server, pose and bounds first")
  cfg.enabled=args[1]=="enable" save() print("Warehouse "..args[1].."d") return
elseif args[1]=="traffic" then
  assert(args[2]=="on" or args[2]=="off","traffic on or off required") cfg.traffic=args[2]=="on" save() return
elseif args[1]=="charger" then
  assert(type(args[2])=="string" and #args[2]>0 and #args[2]<=64,"charger site required")
  local target=tonumber(args[3]) or 2000 assert(target%1==0 and target>=1 and target<=100000,"invalid fuel target")
  cfg.charger=args[2] cfg.targetFuel=target save() return
end
if not fleetEnabled then
  local plug = plugmod()
  local dirty = false
  if plug then
    local env = { peripheral = peripheral, rednet = rednet, gps = gps }
    if not plug.present(cfg.server) then
      local server, source = plug.fill(nil, nil, function() return plug.lookup(env, "fleetserver", "server") end)
      if type(server) == "number" and source == "discover" then cfg.server = server dirty = true end
    end
    if type(cfg.secret) ~= "string" or #cfg.secret < 16 then
      local secret, source = plug.takeSecret(cfg.secret, plug.savedPairing())
      if source == "saved" and type(secret) == "string" then cfg.secret = secret dirty = true end
    end
    if not cfg.pose then
      local fix = plug.gps(env)
      if fix and plug.present(cfg.dimension) then
        cfg.pose = { dim = cfg.dimension, x = fix.x, y = fix.y, z = fix.z, h = 0 }
        dirty = true
      end
    end
  end
  if not (cfg.server and type(cfg.secret) == "string" and #cfg.secret >= 16) then
    print("Not set up yet. First: store server <id> <secret> [dimension]")
    return
  end
  if dirty then save() end
end
assert(cfg.server and (fleetEnabled or cfg.secret),"configure warehouse server first")
peripheral.find("modem",rednet.open)
local client=dofile("ssot-client.lua").new(fleetEnabled and fleetBootstrap or {server=cfg.server,secret=cfg.secret,timeout=cfg.timeout or 5})
local fleet,nav,worker
local fleetError
local function settings() return fleet and fleet.settings() end
local function boundary(kind)
  if not fleet then return true end
  local ok,why=fleet.tick()
  if not ok or not fleet.ready() then
    fleetError=why or "Server unavailable. Warehouse waits for shared settings."
    return false,fleetError
  end
  local values=settings()
  if not values.enabled or not values.warehouse then return false,"Warehouse behavior is disabled" end
  if kind=="drop" and not values.autoDropoff then return false,"Auto drop-off is disabled" end
  if kind=="charge" and not values.autoCharge then return false,"Auto-charge is disabled" end
  if kind=="walk" or kind=="turn" then
    if not values.navigation then return false,"Navigation is disabled" end
  end
  fleetError=nil
  return true
end
if fleetEnabled then
  fleet=dofile("wh2-client.lua").new({rpc=client,enabled=true,role="store",dimension=cfg.dimension,
    snapshot=function()
      local state=worker and worker.state() or {}
      local used=0 for slot=1,16 do if turtle and turtle.getItemCount(slot)>0 then used=used+1 end end
      return {state=fleetError and "blocked" or state.phase=="charge" and "charging" or state.phase=="unload" and "dropping" or "returning",
        detail=fleetError or state.phase or "starting",pose=nav and nav.fleetPose() or false,
        fuel=turtle and {level=turtle.getFuelLevel(),limit=turtle.getFuelLimit()} or false,
        inventory=turtle and {slots=16,usedSlots=used,fullness=used/16} or false,
        capabilities={navigation=turtle~=nil,inventory=turtle~=nil,crafting=false},error=fleetError or false}
    end,
    apply=function(values) if nav then nav.configure(values) end end})
end
local function request(op,v)
  local r,err=client.call(op,v) assert(r and r.ok,err or r and r.error or "warehouse server unavailable") return r
end
local function work()
  if args[1]=="site" then
    local p=pose(4) p.h=tonumber(args[7])
    request("wh-site",{name=args[2],site={kind=args[3],pose=p,side=args[8] or "front"}}) print("Interaction site saved") return
  elseif args[1]=="order" then
    local lines={}
    for i=4,#args,3 do lines[#lines+1]={item=args[i],count=tonumber(args[i+1]),source=args[i+2]} end
    local r=request("wh-order",{key=args[2],drop=args[3],lines=lines}) print(textutils.serialize(r.job)) return
  end
  assert(turtle and cfg.pose and cfg.bounds,"a calibrated turtle and navigation bounds are required")
  nav=dofile("nav.lua").open({path="store-nav.state",pose=cfg.pose,bounds=cfg.bounds,client=client,traffic=cfg.traffic==true,
    gpsFree=cfg.gpsFree==nil or cfg.gpsFree==true,
    beforeAction=fleet and boundary or nil,actionReady=fleet and function() return fleet.ready(),"Fresh fleet settings required" end or nil,
    observe=function()
      local x,y,z=gps.locate(2)
      if x then return {dim=cfg.dimension,x=math.floor(x+.5),y=math.floor(y+.5),z=math.floor(z+.5)} end
    end})
  if args[1]=="calibrate" then
    assert(nav.calibrate(assert(tonumber(args[2]),"heading required"))) print("Warehouse pose calibrated") return
  end
  local recovered, why = nav.recover()
  if not recovered then print("Navigation: " .. tostring(why) .. ". The warehouse keeps running.") end
  if args[1]=="survey" then assert(nav.go(pose(2),"explore")) print("Route surveyed") return end
  if args[1]=="stock" then
    local r=request("wh-lock",{name=args[2]})
    local ok,err=pcall(function()
      assert(r.site.kind=="source","source site required") assert(nav.go(r.site.pose,"walk")) assert(nav.face(r.site.pose.h))
      local inv=assert(peripheral.wrap(r.site.side),"inventory unavailable")
      local stock={}
      for _,v in pairs(inv.list()) do stock[v.name]=(stock[v.name] or 0)+v.count end
      request("wh-stock",{name=args[2],stock=stock})
    end)
    request("wh-unlock",{name=args[2]}) assert(ok,err) print("Stock reported") return
  end
  assert(fleet or cfg.enabled==true,"warehouse disabled; configure it and run store enable")
  local workerOptions={nav=nav,client=client,home=cfg.pose,charger=not fleet and cfg.charger or nil,
    targetFuel=cfg.targetFuel,chargeTimeout=cfg.chargeTimeout,settings=fleet and settings or nil,beforeAction=fleet and boundary or nil}
  worker=dofile("warehouse.lua").open(workerOptions)
  if args[1]=="charge" then assert(worker.charge(args[2],assert(tonumber(args[3])),tonumber(args[4]) or 60000)) end
  while true do
    local ok,why=boundary("warehouse")
    if ok and fleet then
      local values=settings()
      workerOptions.targetFuel,workerOptions.chargeTimeout=values.fuelTarget,values.chargeTimeoutMs
      workerOptions.charger=nil
      if values.autoCharge and turtle.getFuelLevel()~="unlimited" then
        local location,err=fleet.location("charge",nav.fleetPose(),values.chargerId)
        if not location then ok,why=false,err else workerOptions.charger=location.siteNames.charge end
      end
    end
    if ok then ok,why=worker.tick() end
    if worker.state().phase=="done" then
      print("Warehouse "..tostring(worker.state().reason))
      if args[1]=="charge" then return end
      assert(worker.next())
    elseif not ok then print(tostring(why)) end
    sleep(ok and .1 or 2)
  end
end
parallel.waitForAny(work,function()
  while true do
    local id,m,proto=rednet.receive()
    if fleet then fleet.dispatch(id,m,proto) else client.dispatch(id,m,proto) end
  end
end)
