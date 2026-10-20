local args={...}
local A,S=dofile("atomic.lua"),dofile("ssot.lua")
local function unwrap(raw)
  if type(raw)=="table" and (raw.v==1 or raw.schema==1) and type(raw.value)=="table" then return raw.value end
  return raw
end
local cfg=unwrap(A.read("warehouse.cfg")) or {enabled=false}
local cfgRec
local function save()
  cfgRec=cfgRec or A.mount("/"):open("warehouse.cfg",function(v) return type(v)=="table" end,{class="control",limit=8192})
  assert(cfgRec:save(cfg))
end
local function pose(offset)
  local p={dim=assert(cfg.dimension,"configure the server and dimension first"),x=tonumber(args[offset]),y=tonumber(args[offset+1]),z=tonumber(args[offset+2])}
  assert(S.pose(p),"integer world coordinates required") return p
end
if args[1]=="install" then
  assert(A.replaceBytes("startup.lua",'shell.run("store")\n',function(s) return load(s)==nil and false or true end))
  print("Warehouse starts on boot") return
elseif args[1]=="update" then shell.run("update") return
elseif args[1]=="server" then
  cfg.server,cfg.secret,cfg.dimension=tonumber(args[2]),args[3],args[4]
  assert(cfg.server and cfg.server%1==0 and cfg.server>=0 and type(cfg.secret)=="string" and #cfg.secret>=16
    and S.pose({dim=cfg.dimension,x=0,y=64,z=0}),"server ID, paired secret and dimension required")
  save() print("Warehouse server saved") return
elseif args[1]=="pose" then
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
assert(cfg.server and cfg.secret,"configure warehouse server first")
peripheral.find("modem",rednet.open)
local client=dofile("ssot-client.lua").new({server=cfg.server,secret=cfg.secret,timeout=cfg.timeout or 5})
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
  local nav=dofile("nav.lua").open({path="store-nav.state",pose=cfg.pose,bounds=cfg.bounds,client=client,traffic=cfg.traffic==true,
    observe=function()
      local x,y,z=gps.locate(2)
      if x then return {dim=cfg.dimension,x=math.floor(x+.5),y=math.floor(y+.5),z=math.floor(z+.5)} end
    end})
  if args[1]=="calibrate" then
    assert(nav.calibrate(assert(tonumber(args[2]),"heading required"))) print("Warehouse pose calibrated") return
  end
  assert(nav.recover())
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
  assert(cfg.enabled==true,"warehouse disabled; configure it and run store enable")
  local worker=dofile("warehouse.lua").open({nav=nav,client=client,home=cfg.pose,charger=cfg.charger,targetFuel=cfg.targetFuel,chargeTimeout=cfg.chargeTimeout})
  if args[1]=="charge" then assert(worker.charge(args[2],assert(tonumber(args[3])),tonumber(args[4]) or 60000)) end
  while true do
    local ok,why=worker.tick()
    if worker.state().phase=="done" then
      print("Warehouse "..tostring(worker.state().reason))
      if args[1]=="charge" then return end
      assert(worker.next())
    elseif not ok then print(tostring(why)) end
    sleep(ok and .1 or 2)
  end
end
parallel.waitForAny(work,function()
  while true do local id,m,proto=rednet.receive() client.dispatch(id,m,proto) end
end)
