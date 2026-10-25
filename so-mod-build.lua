local P = dofile("so-plan.lua")
local U = dofile("so-ui.lua")
local M = dofile("so-mine-plan.lua")
local S = { recover = true, published = false, safe = {} }
local config = SO.store.read and SO.store.read("so-server.cfg") or {}
S.workerPark = config.workerPark == true
S.fuelTrips = config.builderFuelTrips == true
S.solid = config.builderSolid == true
S.poseSetup = config.jobPoseSetup == true
local shapes = { floor = true, platform = true, wall = true, walls = true, box = true, solid = S.solid }
local dimensions = { ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1, ["minecraft:the_end"] = 1 }
local function whole(n)
  return type(n) == "number" and n == n and math.abs(n) < 30000000 and n % 1 == 0
end
local function normalizeFuel(value) return value == -1 and "unlimited" or value end
local function module(name) return SO.mods and SO.mods[name] or {} end
local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
local function material(name)
  if type(name) ~= "string" then return nil end
  if not name:find(":", 1, true) then name = "minecraft:" .. name end
  if name:match("^[%w_]+:[%w_/]+$") then return name end
end
local function expand(b)
  if type(b) ~= "table" or not shapes[b.shape] then return nil, "invalid shape" end
  for _, field in ipairs({"x1", "y1", "z1", "x2", "y2", "z2"}) do
    if not whole(b[field]) then return nil, "invalid area" end
  end
  if b.x1 > b.x2 or b.y1 > b.y2 or b.z1 > b.z2 then return nil, "invalid area" end
  local volume = (b.x2-b.x1+1)*(b.y2-b.y1+1)*(b.z2-b.z1+1)
  if volume > 16384 then return nil, "area exceeds 16384 blocks" end
  local out = {}
  for y = b.y1, b.y2 do
    if b.shape ~= "floor" and b.shape ~= "platform" or y == b.y1 then
      for z = b.z1, b.z2 do
        for column = 0, b.x2-b.x1 do
          local x = (z-b.z1)%2 == 0 and b.x1+column or b.x2-column
          local edge = x == b.x1 or x == b.x2 or z == b.z1 or z == b.z2
          if b.shape == "solid" or b.shape == "floor" or b.shape == "platform" or edge
            or b.shape == "box" and (y == b.y1 or y == b.y2) then
            out[#out+1] = { dim = b.dim or "minecraft:overworld", x = x, y = y, z = z }
          end
        end
        if SO.breathe then SO.breathe() end
      end
    end
  end
  return out
end
local function import(text)
  local w = {}
  for word in tostring(text):gmatch("%S+") do w[#w+1] = word end
  if w[1] == "builder" then table.remove(w, 1) end
  local shape = ({floor="floor",platform="floor",walls="walls",wall="walls"})[w[1]]
  if not shape then return nil, "import supports floor and walls" end
  local n = {}
  for i = 2, 7 do n[i] = tonumber(w[i]) if not whole(n[i]) then return nil, "invalid import corners" end end
  local height = shape == "walls" and tonumber(w[8]) or nil
  if height and (not whole(height) or height < 1 or height > 64) then return nil, "invalid height" end
  local name = material(w[height and 9 or 8] or "cobblestone")
  if not name or #w > (height and 9 or 8) then return nil, "invalid import material" end
  local b = { shape=shape, x1=math.min(n[2],n[5]), x2=math.max(n[2],n[5]),
    z1=math.min(n[4],n[7]), z2=math.max(n[4],n[7]),
    y1=shape == "floor" and n[3]-1 or n[3], material=name }
  b.y2 = b.y1 + (shape == "walls" and (height or 3)-1 or 0)
  local cells, err = expand(b)
  if not cells then return nil, err end
  return b
end
local box = SO.store.store("so-data/build/job", function(j)
  return type(j) == "table" and type(j.dim) == "string" and whole(j.cursor) and j.cursor >= 1
end)
local j = box.value or { dim="minecraft:overworld", cursor=1, running=false, phase="check" }
j.fuel=normalizeFuel(j.fuel)
if j.blueprint then
  S.targets=expand(j.blueprint)
  if S.targets and #S.targets>0 and j.cursor>#S.targets then j.running,j.complete=false,true end
end
if not j.placement and j.intent and j.intent.action=="place" then
  j.placement={cursor=j.cursor,material=j.material}
end
if j.fuel==nil and j.inv and next(j.inv)==nil then j.inv=nil end
if not S.workerPark and j.turtle and (j.turtle.paused or j.turtle.removeRequested or j.turtle.parkConfirmed) then
  j.turtle.paused,j.turtle.removeRequested,j.turtle.parkConfirmed,j.turtle.state=nil,nil,nil,nil
  print("so-build: workerPark off; cleared park state for "..j.turtle.id)
  S.pauseCleared=true
end
local function publish()
  local state=module("state")
  if S.published ~= j.alert and state.emit then
    local ok=state.emit("build.alert",j.alert and {text=j.alert,id=j.turtle and j.turtle.id} or false)
    if ok ~= false then S.published=j.alert end
  end
end
local function save()
  local announce = j.complete and not j.announced
  if announce then j.announced=true end
  local ok, err = box.save(j)
  if not ok then
    if announce then j.announced=nil end
    j.running, j.alert = false, "save failed: " .. tostring(err)
  end
  publish()
  if ok and announce and module("state").emit then
    module("state").emit("build.alert",{text="build complete",done=j.cursor-1,total=#S.targets,id=j.turtle and j.turtle.id})
  end
  return ok
end
local function alert(text, blocked)
  j.blocked = blocked or "hold"
  if j.alert ~= text then
    j.alert = text
    save()
  end
end
local function owner() return "build:" .. j.turtle.id end
local function removeParked()
  local cells,p=module("cells"),j.turtle.pose
  if not cells.handoff or not cells.releaseOwner or not cells.list then alert("cells unavailable") return end
  local ok,err=cells.handoff(owner(),"gps:"..j.turtle.id,p.x,p.y,p.z,p.dim)
  if ok then ok,err=cells.releaseOwner(owner()) end
  if not ok or #cells.list(owner(),1)>0 then alert(err or "reservation cleanup pending") return end
  local row,service,intent,inv,fuel=j.turtle,j.service,j.intent,j.inv,j.fuel
  j.turtle,j.service,j.intent,j.inv,j.fuel,j.running=nil,nil,nil,{},nil,false
  if not save() then
    j.turtle,j.service,j.intent,j.inv,j.fuel=row,service,intent,inv,fuel
    return
  end
  S.pending,S.recover=nil,true
end
local function trim()
  local cells = module("cells")
  if not cells.list or not cells.release then return end
  for _, p in ipairs(cells.list(owner(), 256)) do
    if p.dim ~= j.dim or not same(p, j.turtle.pose) then
      local ok, err = cells.release(owner(), p.x, p.y, p.z, p.dim)
      if ok == false then alert("reservation save failed: " .. tostring(err)) return false end
    end
  end
  return true
end
local function lane(p)
  local mine = S.mine
  if not mine or mine.dim ~= j.dim or not mine.homeSet then return false end
  local job = {dim=mine.dim, home=mine.home, bottom=mine.bottom, mode=mine.mode,
    turtles={{branch=math.max(0,(mine.branches or 0)-1)}}}
  return M.inLane(job,p)
end
local function send(steps, action, recover)
  local lease, cells = module("lease"), module("cells")
  if S.pending or not lease.send or lease.status(j.turtle.id).open then return false end
  if not recover and not S.safe[j.turtle.id] then alert("update worker for builder safety") return false end
  steps[1].park = true
  local start, at = j.turtle.pose, j.turtle.pose
  local reserved = { start }
  if action ~= "fuel" then
    for _, step in ipairs(steps) do
      at = P.apply(at, step.op)
      reserved[#reserved+1] = at
      if step.op == "placeDown" or step.op == "inspectDown" or step.op == "suckDown" then
        reserved[#reserved+1] = {dim=j.dim,x=at.x,y=at.y-1,z=at.z}
      elseif step.op == "inspect" or step.op == "suck" then
        local x,y,z = P.ahead(at,"forward")
        reserved[#reserved+1] = {dim=j.dim,x=x,y=y,z=z}
      end
    end
  end
  if not recover then
    if not P.rangeBatch(lease,j.turtle.id,{steps=steps,cells=reserved}) then alert("out of range", "range") return false end
    for _, p in ipairs(reserved) do if lane(p) then alert("mining lane", "lane") return false end end
  end
  if not cells.reserveMany then alert("cells unavailable") return false end
  local ok, err = cells.reserveMany(owner(),reserved)
  if not ok then
    if action ~= "fuel" or err ~= "held" then alert(err == "held" and "cells held" or "reservation save failed", "cells") end
    return false
  end
  j.intent = {action=action, steps=steps, pose=start}
  if action=="place" then j.placement={cursor=j.cursor,material=j.material} end
  if not save() then return false end
  local id
  id, err = lease.send(j.turtle.id,steps,{owner="build",recover=recover==true,pose=at})
  if not id then
    j.intent = nil
    if action=="place" then j.placement=nil end
    if err == "lost" then S.recover = true end
    alert("lease " .. tostring(err))
    return false
  end
  S.pending = { id=id, action=action, steps=steps, pose=start }
  return true
end
local function item()
  for _, v in ipairs(j.inv or {}) do if v.name == j.material and v.count > 0 then return v end end
end
local function empty()
  local occupied = {}
  for _, v in ipairs(j.inv or {}) do if v.count > 0 then occupied[v.slot] = true end end
  for slot=1,16 do if not occupied[slot] then return slot end end
end
local function route(target)
  local p = j.turtle.pose
  if same(p,target) then
    if target.facing ~= nil and p.facing ~= target.facing then
      send({{op=(target.facing-p.facing)%4 == 3 and "turnLeft" or "turnRight"}},"move")
      return false
    end
    return true
  end
  local flight = math.max(j.blueprint.y2+2, target.y, j.home.y)
  local goal
  if p.x == target.x and p.z == target.z then goal = target
  elseif p.y ~= flight then goal = {x=p.x,y=flight,z=p.z}
  else goal = {x=target.x,y=flight,z=target.z} end
  local bounded = {x=p.x,y=p.y,z=p.z}
  for axis in ("yxz"):gmatch(".") do
    local delta=goal[axis]-p[axis]
    if delta ~= 0 then bounded[axis]=p[axis]+math.max(-16,math.min(16,delta)) break end
  end
  local plan = P.path(p,bounded)
  local actions, at = {}, p
  for i=1,math.min(16,#plan.steps) do
    local step = plan.steps[i]
    at = P.apply(at,step.op)
    actions[#actions+1] = {steps={step},cells={p,at},pose=at}
    p = at
  end
  local action = {steps={},cells={},actions=actions}
  for _, part in ipairs(actions) do
    action.steps[#action.steps+1] = part.steps[1]
    for _, cell in ipairs(part.cells) do action.cells[#action.cells+1] = cell end
  end
  action = P.rangeBatch(module("lease"),j.turtle.id,action)
  if not action then alert("out of range","range") return false end
  send(action.steps,"move")
  return false
end
local function choose(kind, pose)
  local drops = module("drops")
  if not drops.choose then return nil end
  return drops.choose(kind,{dim=dimensions[j.dim],x=pose.x,y=pose.y,z=pose.z})
end
local function access(point, p)
  if point.side == "down" then return {dim=j.dim,x=point.x,y=point.y+1,z=point.z} end
  local dx,dz = {[0]=0,1,0,-1},{[0]=-1,0,1,0}
  local best, result
  for f=0,3 do
    local a = {dim=j.dim,x=point.x-dx[f],y=point.y,z=point.z-dz[f],facing=f}
    local held = module("cells").owner and module("cells").owner(a.x,a.y,a.z,a.dim)
    local inside = a.x>=j.blueprint.x1 and a.x<=j.blueprint.x2 and a.z>=j.blueprint.z1
      and a.z<=j.blueprint.z2 and a.y>=j.blueprint.y1 and a.y<=j.blueprint.y2
    local distance = math.abs(p.x-a.x)+math.abs(p.y-a.y)+math.abs(p.z-a.z)
    if not inside and not lane(a) and (not held or held == owner()) and (not best or distance<best) then result,best=a,distance end
  end
  return result
end
local function distance(from, to)
  if from.x == to.x and from.z == to.z then return math.abs(from.y-to.y) end
  local flight=math.max(j.blueprint.y2+2,to.y,j.home.y)
  return math.abs(from.y-flight)+math.abs(to.y-flight)+math.abs(from.x-to.x)+math.abs(from.z-to.z)
end
local function supply(kind)
  local picked=choose(kind,j.turtle.pose)
  local point=picked and picked.point
  if not point then alert(picked and picked.alert or ("no "..kind.." chest set")) return end
  if point.dim ~= dimensions[j.dim] then alert(kind.." dimension mismatch") return end
  local stand=access(point,j.turtle.pose)
  if not stand then alert("no "..kind.." access") return end
  if kind == "fuel" and type(j.fuel)=="number" and distance(j.turtle.pose,stand)>j.fuel then
    alert("out of fuel", "fuel")
    send({{op="inspectDown"}},"fuel")
    return
  end
  j.service = {kind=kind,point=point,access=stand,stage="travel"}
  j.phase = "check"
  save()
end
local function fuelItem()
  for _,v in ipairs(j.inv or {}) do if v.name~=j.material and v.count>0 and P.fuelValue(v.name)>0 then return v end end
end
local function fuelNeed(target)
  local stand=j.service and j.service.kind~="fuel" and j.service.access or {x=target.x,y=target.y+1,z=target.z}
  local picked=choose("fuel",stand)
  local point=picked and picked.point
  local fuelStand=point and access(point,stand)
  if not fuelStand then return nil,picked and picked.alert or "no fuel chest set" end
  return distance(j.turtle.pose,stand)+distance(stand,fuelStand)+2
end
local function readiness()
  local checks={}
  local pose=j.turtle and j.turtle.pose
  local lease=module("lease")
  local stat=pose and lease.status and lease.status(j.turtle.id) or {}
  if j.fuel~=nil and stat.fuel~=nil then j.fuel=normalizeFuel(stat.fuel) end
  local picked=pose and choose("storage",pose)
  checks[#checks+1]={ok=picked and picked.point~=nil,text=picked and picked.alert or "no storage chest set"}
  checks[#checks+1]={ok=pose and SO.pair and SO.pair.key(j.turtle.id) and not j.turtle.forgotten and not stat.uncertain and not stat.lost,
    text="paired turtle pose missing or uncertain"}
  checks[#checks+1]={ok=j.turtle and S.safe[j.turtle.id],text="update worker for builder safety"}
  checks[#checks+1]={ok=j.fuel=="unlimited" or type(j.fuel)=="number" and j.fuel>0,text=j.fuel==nil and "fuel unknown; wait for report" or "out of fuel"}
  if S.fuelTrips and pose then
    picked=choose("fuel",pose)
    checks[#checks+1]={ok=picked and picked.point~=nil,text=picked and picked.alert or "no fuel chest set"}
  end
  return checks
end
local function budget()
  local targets=S.targets or (j.blueprint and expand(j.blueprint))
  local total=targets and #targets or 0
  local carried
  if j.inv~=nil then
    carried=0
    for _,v in ipairs(j.inv or {}) do if v.name==j.material then carried=carried+v.count end end
  end
  return {total=total,remaining=math.max(0,total-j.cursor+1),carried=carried}
end
local function advance()
  j.cursor, j.phase = j.cursor+1, "check"
  if j.cursor > #S.targets then j.running, j.alert, j.blocked, j.complete = false, nil, nil, true end
end
local function reconcile(last)
  local pending=j.placement
  local target=S.targets and S.targets[pending.cursor]
  local pose=j.turtle.pose
  if pending.cursor~=j.cursor or not target or pose.dim~=target.dim
    or pose.x~=target.x or pose.y~=target.y+1 or pose.z~=target.z then
    alert("pending placement pose changed") return false
  end
  if last.ok and last.data and last.data.name==pending.material then
    j.placement=nil
    advance()
  elseif not last.ok and last.err=="No block to inspect" then
    j.placement=nil
    j.phase="check"
  else alert(last.ok and "build cell occupied" or "build cell unknown") return false end
  return true
end
local function report(id, turtleId, results, lease)
  local pending = S.pending
  if not j.turtle or j.turtle.forgotten or turtleId ~= j.turtle.id or not pending or pending.id ~= id then return end
  S.pending = nil
  if not results or not lease.report or not lease.report.pose then
    S.recover, j.turtle.parkConfirmed = true, nil
    if j.turtle.paused then j.turtle.state="lost" end
    alert("lost lease", "lost")
    return
  end
  local facts = lease.report
  if j.turtle.anchor then
    j.turtle.frame = P.frame(j.turtle.anchor,facts.pose)
    j.turtle.anchor = nil
  end
  j.turtle.pose = P.toWorld(j.turtle.frame,facts.pose)
  if facts.inv then j.inv = facts.inv end
  if facts.fuel ~= nil then j.fuel = normalizeFuel(facts.fuel) end
  local action, last = pending.action, results[#results]
  j.intent = nil
  if action == "workerPark" then
    j.turtle.parkConfirmed=true
    if j.turtle.paused then j.turtle.state="parked" end
  elseif action == "recover" then
    S.recover, j.blocked, j.alert, j.phase = false, nil, nil, "check"
    if j.service then j.service.stage = "travel" end
    if j.placement and not reconcile(last) then S.recover=true end
  elseif action == "fuel" then
    local target=S.targets and S.targets[j.cursor]
    local required=S.fuelTrips and target and fuelNeed(target) or 1
    if j.fuel == "unlimited" or type(j.fuel) == "number" and j.fuel >= (required or 1) then
      j.blocked, j.alert = nil, nil
    else alert("out of fuel", "fuel") end
  elseif action == "check" then
    if j.placement then reconcile(last)
    elseif last.ok and last.data and last.data.name == j.material then advance()
    elseif last.ok then alert("build cell occupied")
    elseif last.err == "No block to inspect" then j.phase = "place"
    else alert("build cell unknown") end
  elseif action == "place" then
    if last.ok then j.placement=nil advance() else j.phase="check" alert("placement failed") end
  elseif action == "supplyCheck" then
    if last.ok and last.data and (last.data.name:find("chest",1,true)
      or last.data.name:find("barrel",1,true) or last.data.name:find("shulker",1,true)) then
      j.service.stage = "take"
    else alert((j.service.kind or "storage").." chest missing") end
    local drops = module("drops")
    if drops.note then drops.note(j.service.point.id,last.ok and last.data and last.data.name or nil) end
  elseif action == "refuel" then
    if last.ok and (j.fuel=="unlimited" or type(j.fuel)=="number" and j.fuel>=1) then
      if j.service and j.service.kind=="fuel" then j.service=nil end
      j.blocked,j.alert,j.retryAt=nil,nil,nil
    elseif last.ok then
      if j.service then j.service.stage="take" end
    else alert("fuel item rejected") end
  elseif action == "take" and j.service.kind=="fuel" then
    if fuelItem() then j.service.stage="refuel"
    elseif last.ok then alert("fuel chest has no usable fuel")
    else j.service.stage="check" j.retryAt=SO.now()+10000 alert("fuel chest empty", "fuelStock") end
  elseif action == "take" then
    if item() then j.service=nil j.phase="check" j.alert=nil j.retryAt=nil
    elseif last.ok and empty() then j.service.stage="take"
    else j.service.stage="check" j.retryAt=SO.now()+10000 alert("out of material", "material") end
  elseif action == "move" then
    for _, result in ipairs(results) do
      if not result.ok then
        if j.fuel == 0 or tostring(result.err):lower():find("fuel", 1, true) then alert("out of fuel", "fuel")
        else alert("path blocked; clear route", "path") end
        break
      end
    end
  end
  if save() then trim() end
end
local function assigned(id)
  for _, name in ipairs({"mine","lumber"}) do
    local other=module(name)
    local view=other.mapView and other.mapView()
    if view and (view.turtle and view.turtle.id == id or view.turtles and (view.turtles[tostring(id)] or view.turtles[id])) then
      return name
    end
  end
end
local function capability(msg)
  local body=msg.body
  if type(body) == "table" then
    S.safe[msg.from]=type(body.capabilities) == "table" and body.capabilities.parkBatch == true
  end
end
local function input(ev)
  local text = ev.text or ev.id
  if type(text) ~= "string" then return end
  local session = ev.session or S.view
  if text == "setup" or text == "tab:setup" then session.buildSetup=true return end
  if text == "build-back" or text == "tab:job" then session.buildSetup=false return end
  if text == "from-here" or text == "to-here" or text == "home-here" then
    if not S.poseSetup then return end
    local row = j.turtle
    local stat = row and module("lease").status and module("lease").status(row.id)
    local p = row and row.pose
    if not p or row.forgotten or not SO.pair or not SO.pair.key(row.id) or S.recover
      or not stat or stat.open or stat.lost or stat.uncertain or j.running or S.pending then alert("paired pose unavailable") return end
    if p.dim ~= j.dim or not whole(p.x) or not whole(p.y) or not whole(p.z)
      or not whole(p.facing) or p.facing<0 or p.facing>3 then alert("paired pose unavailable") return end
    if text == "home-here" then j.home=SO.store.copy(p) save() return end
    if text == "from-here" then session.buildCorner=SO.store.copy(p) return end
    local first = session.buildCorner
    if not first or first.dim ~= p.dim or p.dim ~= j.dim then alert("set first corner") return end
    text=table.concat({"area",first.x,first.y-1,first.z,p.x,p.y-1,p.z}," ")
  end
  if text == "shape-next" then
    local order=S.solid and {"floor","walls","box","solid"} or {"floor","walls","box"}
    local nextShape={floor=2,platform=2,wall=3,walls=3,box=S.solid and 4 or 1,solid=1}
    text="shape " .. order[nextShape[j.shape or "floor"] or 1]
  end
  if text == "status" then return end
  local w = {}
  for word in text:gmatch("%S+") do w[#w+1]=word end
  if S.workerPark and (w[1]=="park" or w[1]=="resume" or w[1]=="remove") and #w==2 then
    local row=j.turtle
    if not row or tonumber(w[2])~=row.id then alert("unknown turtle") return end
    if row.forgotten then alert("device forgotten; re-pair and re-add turtle") return end
    if w[1]=="resume" then
      local cells,p=module("cells"),row.pose
      if cells.owner and cells.owner(p.x,p.y,p.z,p.dim)=="gps:"..row.id then
        local ok,err=cells.handoff("gps:"..row.id,owner(),p.x,p.y,p.z,p.dim)
        if not ok then alert(err) return end
      end
      row.paused,row.removeRequested,row.parkConfirmed,row.state=nil,nil,nil,nil
    else
      if not row.paused then row.parkConfirmed=nil end
      row.paused=true
      row.state=row.parkConfirmed and "parked" or "parking"
      if w[1]=="remove" then row.removeRequested=true end
    end
    save() return
  end
  if w[1] == "stop" then S.locating=(S.locating or 0)+1 j.running=false save() return end
  if w[1] == "start" then
    local state = module("state")
    local ok, err = false,"disk guard unavailable"
    if state.canStart then ok,err=state.canStart() end
    if not ok then alert(err) return end
    if not j.blueprint or not j.turtle or not j.material then alert("configure area, material, turtle") return end
    S.targets, err = expand(j.blueprint)
    if not S.targets then alert(err) return end
    if j.cursor > #S.targets then j.running=false save() return end
    local missing=P.missing(readiness())
    if #missing>0 then alert(table.concat(missing,"; ")) return end
    j.running,j.blocked,j.alert,j.phase=true,nil,nil,"check"
    save()
    return
  end
  local status = j.turtle and module("lease").status and module("lease").status(j.turtle.id) or {}
  local reanchor = w[1] == "add" and j.turtle and tonumber(w[2]) == j.turtle.id and status.uncertain
  if (j.running or S.pending or status.open) and not reanchor then alert("stop before configuring") return end
  if j.placement and w[1]~="add" then alert("reconcile placement before configuring") return end
  if w[1] == "area" and #w == 7 then
    local n={}
    for i=2,7 do n[i]=tonumber(w[i]) if not whole(n[i]) then alert("invalid area") return end end
    local b={x1=math.min(n[2],n[5]),y1=math.min(n[3],n[6]),z1=math.min(n[4],n[7]),
      x2=math.max(n[2],n[5]),y2=math.max(n[3],n[6]),z2=math.max(n[4],n[7]),shape=j.shape or "floor",dim=j.dim}
    local cells,err=expand(b)
    if not cells then alert(err) return end
    j.blueprint,j.cursor,j.phase,j.service=b,1,"check",nil
    S.targets=cells
  elseif w[1] == "shape" and #w == 2 and shapes[w[2]] then
    j.shape=w[2]
    if j.blueprint then j.blueprint.shape=w[2] S.targets=expand(j.blueprint) end
    j.cursor,j.phase,j.service=1,"check",nil
  elseif w[1] == "material" and #w == 2 and material(w[2]) then j.material=material(w[2]) j.phase="check" j.service=nil
  elseif w[1] == "import" then
    local b,err=import(text:match("^%S+%s+(.+)$"))
    if not b then alert(err) return end
    b.dim=j.dim
    j.blueprint,j.shape,j.material,j.cursor,j.phase,j.service=b,b.shape,b.material,1,"check",nil
    S.targets=expand(b)
  elseif w[1] == "add" and (#w == 2 or #w == 6) then
    local id=tonumber(w[2])
    if not whole(id) or id < 0 then alert("invalid turtle") return end
    if j.turtle and j.turtle.forgotten and j.turtle.id == id and #w ~= 6 then alert("add needs x y z n|e|s|w") return end
    if j.turtle and not j.turtle.forgotten and j.turtle.id ~= id then alert("builder already has a turtle") return end
    local lease=module("lease")
    local stat=lease.status and lease.status(id) or {}
    if stat.open and not stat.uncertain then alert("turtle has open lease") return end
    local other=assigned(id)
    if other then alert("turtle assigned to " .. other) return end
    local pose
    if #w == 6 then
      local x,y,z=tonumber(w[3]),tonumber(w[4]),tonumber(w[5])
      local f=({n=0,e=1,s=2,w=3})[w[6]]
      if whole(x) and whole(y) and whole(z) and f then pose={dim=j.dim,x=x,y=y,z=z,facing=f} end
    else
      if not lease.locate then alert("GPS unavailable; use explicit add") return end
      S.locating=(S.locating or 0)+1
      local attempt=S.locating
      lease.locate(id,j.dim,function(found,err)
        if attempt~=S.locating then return end
        if not found then alert(err or "GPS locate failed") return end
        if found.dim~=j.dim or not whole(found.x) or not whole(found.y) or not whole(found.z)
          or not whole(found.facing) or found.facing<0 or found.facing>3 then alert("invalid GPS pose") return end
        input({text=string.format("add %d %d %d %d %s",id,found.x,found.y,found.z,({[0]="n","e","s","w"})[found.facing])})
      end)
      return
    end
    if not pose then alert("add needs x y z n|e|s|w") return end
    if SO.pair and SO.pair.key and not SO.pair.key(id) then alert("turtle is not paired") return end
    if stat.uncertain then
      local ok,err=lease.reanchor(id,pose)
      if not ok then alert(err) return end
      S.pending=nil
      j.running=false
    end
    S.locating=(S.locating or 0)+1
    if lease.claimProbe then
      local ok,err=lease.claimProbe(id,"build:"..id,pose)
      if not ok then alert(err) return end
    end
    j.turtle={id=id,pose=pose,anchor=SO.store.copy(pose)}
    j.home=SO.store.copy(pose)
    j.inv,j.fuel=nil,nil
    S.recover=true
    j.blocked,j.alert=nil,nil
    if save() and lease.clearProbe then
      local ok,err=lease.clearProbe(id)
      if not ok then alert(err) end
    end
    return
  else alert("invalid command") return end
  if w[1]=="area" or w[1]=="shape" or w[1]=="import" then j.complete,j.announced=nil,nil end
  j.blocked,j.alert=nil,nil
  save()
end
S.view = {}
-- Route A (docs/ui/schematic/other.py build): the job tab has the shape with its state, the cells
-- placed and the job's leaders; setup has the shape chips and the configured values. START and STOP
-- sit on the last row of both.
local function render(w,h,session)
  session=session or S.view
  local C=U.canvas(w,h)
  local gap,lw=h>=16 and 1 or 0,math.min(w-2,40)
  local state=j.blocked or (j.complete and "COMPLETE" or j.running and "running" or "stopped")
  local tone=U.tone(state)
  if j.blocked and tone~="e" then tone="1" end
  local shape=({platform="floor",wall="walls"})[j.shape] or j.shape or "floor"
  local b,t=j.blueprint,j.turtle
  local from=b and (b.x1 .. "," .. b.y1 .. "," .. b.z1)
  local to=b and (b.x2 .. "," .. b.y2 .. "," .. b.z2)
  local stuff=j.material and (j.material:gsub("^minecraft:",""))
  U.roleBar(C,"BUILD",{"job","setup"},{"job","setup"},session.buildSetup and 2 or 1)
  local y=2+gap
  if j.alert then y=y+U.flagLines(C,2,y,w-2,j.alert,nil,2)+gap end
  if session.buildSetup then
    local cx=w>=36 and 13 or 11
    C.put(2,y,"shape","8")
    if cx+(S.solid and 28 or 20)<=w-1 then
      local x=cx
      for _,name in ipairs(S.solid and {"floor","walls","box","solid"} or {"floor","walls","box"}) do x=C.chip(x,y,name,"shape " .. name,name==shape and "plain" or "off")+1 end
    else C.chip(cx,y,shape,"shape-next") end
    local draft=session.buildCorner
    local rows={{"from",draft and (draft.x..","..(draft.y-1)..","..draft.z) or from,"from-here"},
      {"to",to,"to-here"},{"material",stuff},{"turtle",t and ("#" .. t.id)},{"home",j.home and U.turtle.pose(j.home),"home-here"}}
    for i,r in ipairs(rows) do
      local ry=y+i*(h>=16 and 2 or 1)
      if ry<h-gap then
        C.put(2,ry,r[1],"8")
        if S.poseSetup and r[3] then C.chip(cx,ry,(r[2] or "-"):sub(1,math.max(1,w-cx-3)),r[3],r[2] and "plain" or "off")
        else C.put(cx,ry,(r[2] or "-"):sub(1,math.max(0,w-cx)),r[2] and "0" or "8") end
      end
    end
  else
    local total=S.targets and #S.targets or 0
    local done=math.min(j.cursor-1,total)
    local frac=done .. "/" .. total
    C.section(2,y,lw,shape:upper(),state,tone)
    C.progress(2,y+1,math.max(1,lw-1-#frac),done,total)
    if j.complete then C.put(2+lw-#frac,y+1,frac,"0") end
    local facts={{"material",stuff},{"turtle",t and ("#" .. t.id)},{"position",t and U.turtle.pose(t.pose)},
      {"fuel",j.fuel and tostring(j.fuel)},{"from",from},{"to",to}}
    for i,f in ipairs(facts) do
      local ry=y+1+gap+i
      if ry<h-gap then C.leader(2,ry,lw,f[1],f[2] or "-",f[2] and "0" or "8") end
    end
  end
  U.actions(C,h,{{"START","start",j.running and "muted" or "primary"},{"STOP","stop",j.running and "stop" or "muted"}})
  return C.frame()
end
local function tick()
  if j.complete and not j.announced and not save() then return end
  if S.pauseCleared then
    if not save() then return end
    S.pauseCleared=nil
  end
  publish()
  local lease,display=module("lease"),module("display")
  if not S.wired and display.screen then display.screen("build",render,input) S.wired=true end
  if not S.callback and lease.onReport then lease.onReport("build",report) S.callback=true end
  local mine=module("mine")
  S.mine=mine.mapView and mine.mapView() or nil
  if not j.turtle or j.turtle.forgotten or not lease.status or not S.callback then return end
  S.targets=S.targets or (j.blueprint and expand(j.blueprint))
  local other=assigned(j.turtle.id)
  if other then j.running=false alert("turtle assigned to " .. other) return end
  local stat=lease.status(j.turtle.id)
  if stat.uncertain then j.turtle.parkConfirmed=nil alert("pose uncertain; re-add turtle","pose uncertain") return end
  if S.pending or stat.open then return end
  if S.recover or stat.lost then
    local cells,p=module("cells"),j.turtle.pose
    local gps="gps:"..j.turtle.id
    if cells.owner and cells.owner(p.x,p.y,p.z,p.dim)==gps then
      if not cells.handoff then alert("standing cell handoff unavailable") return end
      local ok,err=cells.handoff(gps,owner(),p.x,p.y,p.z,p.dim)
      if not ok then alert(err) return end
    end
    j.turtle.parkConfirmed=nil
    if j.turtle.paused then j.turtle.state="parking" end
    send({{op="inspectDown"}},"recover",true)
    return
  end
  if S.workerPark and j.turtle.paused then
    if j.turtle.removeRequested and j.turtle.parkConfirmed then removeParked()
    elseif not j.turtle.parkConfirmed or not S.parkAt or SO.now()-S.parkAt>=540000 then
      if send({{op="inspectDown"}},"workerPark",true) then S.parkAt=SO.now() end
    end
    return
  end
  if j.service and j.service.kind=="fuel" and not S.fuelTrips then
    j.running=false alert("builder fuel trips disabled") return
  end
  if j.service and j.service.kind=="fuel" and j.fuel=="unlimited" then
    j.service=nil save()
  end
  if (j.blocked == "material" or j.blocked == "fuelStock") and j.retryAt and SO.now() >= j.retryAt then
    j.blocked=nil
  end
  if S.fuelTrips and j.running and (not j.blocked or j.blocked=="fuel") and type(j.fuel)=="number" then
    local target=S.targets and S.targets[j.cursor]
    local need,err
    if target then need,err=fuelNeed(target) end
    if need and j.fuel<need or j.service and j.service.stage=="refuel" then
      local carried=fuelItem()
      if carried then
        send({{op="select",slot=carried.slot},{op="refuel",n=math.min(carried.count,math.max(1,math.ceil((math.max(2000,need or 0)-j.fuel)/P.fuelValue(carried.name))))}},"refuel")
        return
      elseif not j.service or j.service.kind~="fuel" then supply("fuel") return end
    elseif target and not need then alert(err) return end
  end
  local atFuel = S.fuelTrips and j.service and j.service.kind=="fuel" and same(j.turtle.pose,j.service.access)
  if j.running and not atFuel and (j.blocked == "fuel" or not j.blocked and type(j.fuel)=="number" and j.fuel>=0 and j.fuel<1) then
    alert("out of fuel", "fuel")
    send({{op="inspectDown"}},"fuel")
    return
  end
  if not j.running or j.blocked then return end
  S.targets=S.targets or expand(j.blueprint)
  local target=S.targets and S.targets[j.cursor]
  if not target then j.running,j.complete=false,true save() return end
  if j.service then
    local service=j.service
    if service.stage == "travel" then
      if not route(service.access) then return end
      service.stage="check" save()
    end
    if service.stage == "check" then send({{op=service.point.side=="down" and "inspectDown" or "inspect"}},"supplyCheck")
    elseif service.stage == "take" then
      local slot=empty()
      if not slot then alert("inventory full") return end
      send({{op="select",slot=slot},{op=service.point.side=="down" and "suckDown" or "suck",n=64}},"take")
    end
    return
  end
  local stand={dim=j.dim,x=target.x,y=target.y+1,z=target.z}
  if not route(stand) then return end
  if j.phase == "place" then
    local carried=item()
    if not carried then supply("storage") return end
    send({{op="select",slot=carried.slot},{op="placeDown"}},"place")
  else send({{op="inspectDown"}},"check") end
end
local function protect(fn)
  if not j.turtle then return true end
  if j.turtle.forgotten or S.recover or not j.turtle.frame then return false end
  fn(j.dim,j,48)
  if j.running and j.blueprint then
    local b=j.blueprint
    fn(j.dim,{{x=b.x1,y=b.y1,z=b.z1},{x=b.x2,y=b.y2,z=b.z2}},1)
  end
  return true
end
local function forget(id)
  if not j.turtle or j.turtle.id ~= id then return true end
  S.locating=(S.locating or 0)+1
  j.turtle.forgotten, j.running, j.blocked = true, false, "device forgotten"
  S.pending, S.recover = nil, true
  return save()
end
local function turtleView()
  if not j.turtle or j.turtle.forgotten then return {} end
  local totals=budget()
  return {[tostring(j.turtle.id)]={role="build",pose=SO.store.copy(j.turtle.pose),anchor=SO.store.copy(j.turtle.anchor),
    state=j.turtle.state or j.blocked or (j.complete and "complete" or j.running and "running" or "stopped"),
    paused=j.turtle.paused,parkConfirmed=j.turtle.parkConfirmed,inv=SO.store.copy(j.inv or {}),fuel=j.fuel,
    done=totals.total-totals.remaining,total=totals.total,error=j.alert,step=S.pending and S.pending.action}}
end
return {name="build",forget=forget,assigned=function(id) return j.turtle and not j.turtle.forgotten and j.turtle.id == id or false end,handlers={hello=capability,["step.report"]=capability},tick=tick,budget=budget,expand=expand,import=import,dugProtection=protect,turtleView=turtleView}
