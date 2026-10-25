local P = dofile("so-plan.lua")
local U = dofile("so-ui.lua")
local M = dofile("so-mine-plan.lua")
local D = { workers={} }
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
j.returnHome=j.returnHome == true
if j.blueprint then
  S.targets=expand(j.blueprint)
  if j.completion and j.completion.phase=="returning" then j.complete=false
  elseif S.targets and #S.targets>0 and j.cursor>#S.targets then j.running,j.complete,j.blocked,j.alert,j.legacyHold=false,true,nil,nil,nil end
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
local causes = {
  fuel={2,"Build needs fuel"}, material={2,"Build needs material"},
  range={1,"Build out of range"}, path={1,"Build path blocked"}, lost={1,"Build worker lost"},
  pose_uncertain={1,"Build pose uncertain"}, save={1,"Build save failed"},
  reservation={1,"Build reservation blocked"}, cell_occupied={1,"Build cell occupied"},
  cell_unknown={1,"Build cell unknown"}, placement={1,"Build placement failed"},
  worker_safety={1,"Build worker update required"}, assignment_conflict={1,"Build worker assigned elsewhere"},
  dimension_mismatch={1,"Build dimension mismatch"}, storage_missing={2,"Build chest missing"},
  storage_access={2,"Build chest inaccessible"}, inventory_full={2,"Build inventory full"},
  device_forgotten={2,"Build worker forgotten"},
}
local aliases = { ["pose uncertain"]="pose_uncertain", ["device forgotten"]="device_forgotten",
  cells="reservation", lane="reservation", fuelStock="fuel" }
j.blocked = aliases[j.blocked] or j.blocked
if j.blocked=="hold" then j.legacyHold=j.legacyHold or j.alert or "legacy hold; review BUILD" end
local function feedback(text) S.feedback, S.feedbackUntil = tostring(text), SO.now()+5000 end
local function publish()
  local state=module("state")
  if S.published ~= j.alert and state.emit then
    local ok=state.emit("build.alert",j.alert and {text=j.alert,id=j.turtle and j.turtle.id} or false)
    if ok ~= false then S.published=j.alert end
  end
end
local function save()
  if S.reconciling then return true end
  if j.complete and j.blocked=="save" then j.blocked,j.alert=nil,nil end
  local announce = j.complete and not j.announced
  if announce then j.announced=true end
  local ok, err = box.save(j)
  if not ok then
    if announce then j.announced=nil end
    j.running, j.blocked, j.alert = false, "save", "save failed: " .. tostring(err)
  end
  publish()
  if ok and announce and module("state").emit then
    module("state").emit("build.alert",{text="build complete",done=j.cursor-1,total=#S.targets,id=j.turtle and j.turtle.id})
  end
  return ok
end
local function alert(text, blocked)
  S.feedback = nil
  assert(causes[blocked], "unknown build cause")
  if j.alert ~= text or j.blocked ~= blocked then
    j.blocked, j.alert = blocked, text
    save()
  end
end
local function owner() return "build:" .. j.turtle.id end
local function removeParked()
  local cells,p=module("cells"),j.turtle.pose
  if not cells.handoff or not cells.releaseOwner or not cells.list then alert("cells unavailable", "reservation") return end
  local ok,err=cells.handoff(owner(),"gps:"..j.turtle.id,p.x,p.y,p.z,p.dim)
  if ok then ok,err=cells.releaseOwner(owner()) end
  if not ok or #cells.list(owner(),1)>0 then alert(err or "reservation cleanup pending", "reservation") return end
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
      if ok == false then alert("reservation save failed: " .. tostring(err), "reservation") return false end
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
local sendCauses = {
  ["DISK events pending"]="save", ["pose uncertain"]="pose_uncertain", pose="pose_uncertain",
  lost="lost", send="lost", busy="assignment_conflict", ["no key"]="device_forgotten",
  ["update remote worker"]="worker_safety", ["invalid dimension"]="dimension_mismatch",
  ["remote dimensions disabled"]="dimension_mismatch",
  ["worker dimension mismatch; set so-worker.cfg"]="dimension_mismatch",
  ["Nether bedrock boundary"]="dimension_mismatch", ["End void or height boundary"]="dimension_mismatch",
  id="path", owner="path", steps="path", opts="path", ms="path", size="path",
}
local function returning()
  return j.completion and j.completion.phase=="returning"
end
local function storageTrip()
  return j.service and j.service.kind=="storage" and (config.alternateAxisOrders == true or j.service.deliveryVacate==true)
end
local function storageError(reason)
  return P.chestError("storage route",reason,j.service.point)
end
local function boundaryAlert(pending,text,cause)
  if pending.storageTrip and j.service then
    j.service.hold=j.service.hold or {cause=cause,text=storageError(text)}
    text,cause=j.service.hold.text,j.service.hold.cause
  end
  alert(text,cause)
end
local function journalPose(p)
  return type(p)=="table" and whole(p.x) and whole(p.y) and whole(p.z)
    and whole(p.f) and p.f>=0 and p.f<=3
end
local function returnReady(stat, recover)
  local row=j.turtle
  local trip=storageTrip() and "storage trip" or "return"
  if not row or not S.safe[row.id] or not stat.parkBatch or not stat.setupFence or not stat.journal then
    return false,"update worker for fenced builder "..trip,"worker_safety"
  end
  if stat.uncertain or not journalPose(stat.pose) or not (row.frame or recover and row.anchor)
    or not P.assess(row.pose,{}).ok
    or not recover and (S.recover or stat.lost or not P.samePose(row.pose,P.toWorld(row.frame,stat.pose))) then
    return false,trip.." needs a certain pose and facing","pose_uncertain"
  end
  return true
end
local function finish()
  j.running,j.complete,j.alert,j.blocked=false,true,nil,nil
  if j.completion then j.completion.phase="complete" end
end
local function send(steps, action, recover)
  local lease, cells = module("lease"), module("cells")
  if S.pending or not lease.send or lease.status(j.turtle.id).open then return false end
  if not recover and lease.restartReady and not lease.restartReady() then return false end
  if not recover and not S.safe[j.turtle.id] then alert("update worker for builder safety", "worker_safety") return false end
  local returning, storageTrip = returning(), storageTrip()
  local stat=lease.status(j.turtle.id)
  if returning or storageTrip then
    local ready,why,cause=returnReady(stat,recover)
    if not ready then alert(why,cause) return false end
  end
  local boundary = returning or storageTrip or lease.boundaries and lease.boundaries()
  if boundary then
    steps = P.boundary({from=j.turtle.pose,steps=steps}).steps
    local check = lease.assess(j.turtle.id,j.turtle.pose,steps,{owner="build",clear=storageTrip and not recover})
    if not check.ok then alert(storageTrip and storageError(check.reason) or check.reason,"path") return false end
  end
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
    for _, p in ipairs(reserved) do if lane(p) then alert("mining lane", "reservation") return false end end
  end
  if not cells.reserveMany then alert("cells unavailable", "reservation") return false end
  local ok, err = cells.reserveMany(owner(),reserved)
  if not ok then
    if action ~= "fuel" or err ~= "held" then alert(err == "held" and "cells held" or "reservation save failed", "reservation") end
    return false
  end
  j.intent = {action=action, steps=steps, pose=start}
  if action=="place" then j.placement={cursor=j.cursor,material=j.material} end
  if not save() then return false end
  local id
  local journal = (returning or storageTrip) and stat.journal or nil
  id, err = lease.send(j.turtle.id,steps,{owner="build",recover=recover==true,pose=at,frame=j.turtle.frame,journal=journal,clear=storageTrip and not recover,
    intent={action=action,steps=steps,pose=start,boundary=boundary and not recover,returning=returning,storageTrip=storageTrip,journal=journal}})
  if not id then
    j.intent = nil
    if action=="place" then j.placement=nil end
    local cause=sendCauses[err] or "path"
    if cause == "lost" then S.recover = true end
    alert("lease " .. tostring(err), cause)
    return false
  end
  S.pending = { id=id, action=action, steps=steps, pose=start, boundary=boundary and not recover, returning=returning, storageTrip=storageTrip, journal=journal }
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
  if storageTrip() then
    local lease=module("lease")
    local ready,why,cause=returnReady(lease.status(j.turtle.id))
    if not ready then alert(why,cause) return false end
    local need=math.abs(target.x-p.x)+math.abs(target.y-p.y)+math.abs(target.z-p.z)
    if j.fuel~="unlimited" and (type(j.fuel)~="number" or j.fuel<need) then
      alert(storageError("out of fuel"),"fuel") return false
    end
    local bounded={dim=p.dim,x=p.x,y=p.y,z=p.z}
    for _,axis in ipairs({"x","y","z"}) do
      bounded[axis]=p[axis]+math.max(-16,math.min(16,target[axis]-p[axis]))
    end
    local paths,refusal=P.rankPaths(p,bounded,{alternateAxisOrders=true},function(from,steps,opts)
      opts.owner="build"
      local check=lease.assess(j.turtle.id,from,steps,opts)
      if not check.ok then return check end
      local at=from
      if lane(at) then return {ok=false,reason="mining lane"} end
      for _,step in ipairs(steps) do
        at=P.apply(at,step.op)
        if lane(at) then return {ok=false,reason="mining lane"} end
      end
      return check
    end)
    if not paths[1] then alert(storageError(refusal and refusal.reason or "no safe path"),"path") return false end
    if #paths[1].steps>0 then send(paths[1].steps,"move") return false end
  end
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
  if not point then alert(picked and picked.alert or ("no "..kind.." chest set"), "storage_missing") return end
  if point.dim ~= dimensions[j.dim] then alert(kind.." dimension mismatch", "dimension_mismatch") return end
  local stand=access(point,j.turtle.pose)
  if not stand then alert("no "..kind.." access", "storage_access") return end
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
  if not point then return nil,picked and picked.alert or "no fuel chest set","storage_missing" end
  if point.dim~=dimensions[j.dim] then return nil,"fuel dimension mismatch","dimension_mismatch" end
  local fuelStand=access(point,stand)
  if not fuelStand then return nil,"no fuel access","storage_access" end
  return distance(j.turtle.pose,stand)+distance(stand,fuelStand)+2
end
local function readiness()
  local checks={}
  local pose=j.turtle and j.turtle.pose
  local lease=module("lease")
  local stat=pose and lease.status and lease.status(j.turtle.id) or {}
  if j.fuel~=nil and stat.fuel~=nil then j.fuel=normalizeFuel(stat.fuel) end
  local picked=pose and choose("storage",pose)
  checks[#checks+1]={ok=picked and picked.point~=nil,text=picked and picked.alert or "no storage chest set",cause="storage_missing"}
  checks[#checks+1]={ok=pose and SO.pair and SO.pair.key(j.turtle.id) and not j.turtle.forgotten and not stat.uncertain and not stat.lost,
    text="paired turtle pose missing or uncertain",cause=stat.lost and "lost" or "pose_uncertain"}
  checks[#checks+1]={ok=j.turtle and S.safe[j.turtle.id],text="update worker for builder safety",cause="worker_safety"}
  checks[#checks+1]={ok=j.fuel=="unlimited" or type(j.fuel)=="number" and j.fuel>0,text=j.fuel==nil and "fuel unknown; wait for report" or "out of fuel",cause="fuel"}
  if S.fuelTrips and pose then
    picked=choose("fuel",pose)
    checks[#checks+1]={ok=picked and picked.point~=nil,text=picked and picked.alert or "no fuel chest set",cause="storage_missing"}
  end
  return checks
end
local function budget()
  local targets=S.targets
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
  if j.cursor > #S.targets then
    if j.returnHome then
      j.completion={phase="returning",target=SO.store.copy(j.home)}
      j.complete,j.alert,j.blocked=false,nil,nil
    else finish() end
  end
end
local function reconcile(last)
  local pending=j.placement
  local target=S.targets and S.targets[pending.cursor]
  local pose=j.turtle.pose
  if pending.cursor~=j.cursor or not target or pose.dim~=target.dim
    or pose.x~=target.x or pose.y~=target.y+1 or pose.z~=target.z then
    alert("pending placement pose changed", "pose_uncertain") return false
  end
  if last.ok and last.data and last.data.name==pending.material then
    j.placement=nil
    advance()
  elseif not last.ok and last.err=="No block to inspect" then
    j.placement=nil
    j.phase="check"
  else alert(last.ok and "build cell occupied" or "build cell unknown", last.ok and "cell_occupied" or "cell_unknown") return false end
  return true
end
local function report(id, turtleId, results, lease)
  local pending = S.pending
  if not j.turtle or j.turtle.forgotten or turtleId ~= j.turtle.id or not pending or pending.id ~= id then return end
  S.pending = nil
  if (pending.returning or pending.storageTrip) and not results and lease.boundary and lease.status=="reported" then
    local facts=lease.report or {}
    local certain=not facts.uncertain and journalPose(facts.pose) and j.turtle.frame
    local blocked=certain and P.samePose(pending.pose,P.toWorld(j.turtle.frame,facts.pose))
    local cause=blocked and (facts.fuel==0 and "fuel" or "path") or "pose_uncertain"
    local text=cause=="fuel" and "out of fuel" or cause=="path" and "path blocked; clear route"
      or "boundary unconfirmed; reservations held"
    S.recover,j.turtle.parkConfirmed=true,nil
    if pending.returning then
      j.completion.hold=j.completion.hold or {cause=cause,text=text}
      alert(j.completion.hold.text,j.completion.hold.cause)
    else boundaryAlert(pending,text,cause) end
    return
  end
  if not results or not lease.report or not lease.report.pose then
    S.recover, j.turtle.parkConfirmed = true, nil
    if j.turtle.paused then j.turtle.state="lost" end
    alert("lost lease", "lost")
    return
  end
  local facts = lease.report
  if (pending.returning or pending.storageTrip) and (facts.uncertain or type(facts.journal)~="string" or facts.journal==pending.journal or not journalPose(facts.pose)
    or #results~=#pending.steps or results[1] and results[1].err=="journal changed") then
    S.recover=true
    boundaryAlert(pending,(pending.returning and "return" or "storage").." report unconfirmed; reservations held","pose_uncertain")
    return
  end
  if pending.boundary and (facts.uncertain or not j.turtle.frame
    or not P.confirm(pending.pose,pending.steps,results,P.toWorld(j.turtle.frame,facts.pose))) then
    S.recover = true
    local failed
    if pending.returning or pending.storageTrip then
      for _,result in ipairs(results) do if not result.ok then failed=result break end end
    end
    if failed then
      local fuel=facts.fuel==0 or tostring(failed.err):lower():find("fuel",1,true)
      boundaryAlert(pending,fuel and "out of fuel" or "path blocked; clear route",fuel and "fuel" or "path")
    else boundaryAlert(pending,"boundary unconfirmed; reservations held", "pose_uncertain") end
    return
  end
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
    S.recover, j.phase = false, "check"
    if returning() and j.completion.hold then
      j.blocked,j.alert=j.completion.hold.cause,j.completion.hold.text
    elseif j.service and j.service.hold then
      j.blocked,j.alert=j.service.hold.cause,j.service.hold.text
    elseif j.legacyHold then j.blocked,j.alert="hold",j.legacyHold
    elseif not (returning() and j.blocked and j.blocked~="lost" and j.blocked~="pose_uncertain" and j.blocked~="worker_safety" and j.blocked~="save")
      and not (j.retryAt and (j.blocked=="material" or j.blocked=="fuel")) then j.blocked,j.alert=nil,nil end
    if j.service then j.service.stage = "travel" end
    if j.placement and not reconcile(last) then S.recover=true end
  elseif action == "fuel" then
    local target=S.targets and S.targets[j.cursor]
    local required=S.fuelTrips and target and fuelNeed(target) or 1
    if j.fuel == "unlimited" or type(j.fuel) == "number" and j.fuel >= (required or 1) then
      j.blocked, j.alert, j.retryAt = nil, nil, nil
    else alert("out of fuel", "fuel") end
  elseif action == "check" then
    if j.placement then reconcile(last)
    elseif last.ok and last.data and last.data.name == j.material then advance()
    elseif last.ok then alert("build cell occupied", "cell_occupied")
    elseif last.err == "No block to inspect" then j.phase = "place"
    else alert("build cell unknown", "cell_unknown") end
  elseif action == "place" then
    if last.ok then j.placement=nil advance() else j.phase="check" alert("placement failed", "placement") end
  elseif action == "supplyCheck" then
    if last.ok and last.data and (last.data.name:find("chest",1,true)
      or last.data.name:find("barrel",1,true) or last.data.name:find("shulker",1,true)) then
      j.service.stage = "take"
    else alert((j.service.kind or "storage").." chest missing", "storage_missing") end
    local drops = module("drops")
    if drops.note then drops.note(j.service.point.id,last.ok and last.data and last.data.name or nil,id) end
  elseif action == "refuel" then
    local target=S.targets and S.targets[j.cursor]
    local required=S.fuelTrips and target and fuelNeed(target) or 1
    if last.ok and (j.fuel=="unlimited" or type(j.fuel)=="number" and j.fuel>=(required or 1)) then
      if j.service and j.service.kind=="fuel" then j.service=nil end
      j.blocked,j.alert,j.retryAt=nil,nil,nil
    elseif last.ok then
      if j.service then j.service.stage="take" end
    else alert("fuel item rejected", "fuel") end
  elseif action == "take" and j.service.kind=="fuel" then
    if fuelItem() then j.service.stage="refuel"
    elseif last.ok then alert("fuel chest has no usable fuel", "fuel")
    else j.service.stage="check" j.retryAt=SO.now()+10000 alert("fuel chest empty", "fuel") end
  elseif action == "take" then
    if item() then j.service=nil j.phase="check" j.blocked=nil j.alert=nil j.retryAt=nil
    elseif last.ok and empty() then j.service.stage="take"
    else
      j.service.stage="check" j.retryAt=SO.now()+10000
      if D.enabled(true) then
        if not j.service.deliveryAttempted then
          j.service.deliveryAttempted=true
          -- The empty cycle is durable before a delivery can acquire the output.
          if not save() then return end
          j.service.deliveryVacate,j.service.stage=true,"deliveryVacate"
          j.blocked,j.alert,j.retryAt=nil,nil,nil
          save()
          return
        end
        local status=j.service.deliveryId and D.status(j.service.deliveryId)
        alert(status and status.text or j.service.deliveryError or "out of material","material")
      else alert("out of material", "material") end
    end
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
  if D.data and D.data.active and D.data.active.worker==id then return "delivery" end
  for _, name in ipairs({"mine","lumber"}) do
    local other=module(name)
    local view=other.mapView and other.mapView()
    if view and (view.turtle and view.turtle.id == id or view.turtles and (view.turtles[tostring(id)] or view.turtles[id])) then
      return name
    end
  end
end
D.enabled = function(builder)
  local cfg=SO.store.read and SO.store.read("so-server.cfg") or {}
  return cfg.storageDeliveries==true and (not builder or cfg.builderMaterialOrders==true)
end
D.item = function(id)
  if type(id)~="string" or #id>128 or not id:match("^[a-z0-9_.-]+:[a-z0-9_./-]+$") then return false end
  for _,suffix in ipairs({"_pickaxe","_axe","_shovel","_hoe","_sword"}) do
    if id:sub(-#suffix)==suffix then return false end
  end
  return true
end
D.integer = function(n,lo,hi) return type(n)=="number" and n==n and n%1==0 and n>=lo and n<=hi end
D.point = function(p)
  return type(p)=="table" and type(p.id)=="string" and dimensions[p.dim]~=nil
    and whole(p.x) and whole(p.y) and whole(p.z) and (p.side=="front" or p.side=="down")
end
D.inventory = function(inv)
  if type(inv)~="table" then return nil end
  local out,seen={},{}
  for _,v in pairs(inv) do
    if type(v)~="table" or not D.integer(v.slot,1,16) or seen[v.slot] or type(v.name)~="string"
      or not D.integer(v.count,0,64) then return nil end
    seen[v.slot]=true
    if v.count>0 then out[#out+1]=SO.store.copy(v) end
  end
  return out
end
D.valid = function(v)
  if type(v)~="table" or v.v~=1 or not D.integer(v.serial,0,2^53-2) then return false end
  for _,a in ipairs({v.active or false,v.last or false}) do
    if a and (type(a)~="table" or type(a.id)~="string" or type(a.requester)~="string"
      or not D.integer(a.worker,0,2^53-2) or not D.item(a.item) or not D.integer(a.n,1,64)
      or not D.point(a.source) or not D.point(a.destination) or not P.assess(a.home,{}).ok
      or not P.assess(a.pose,{}).ok or not journalPose(a.journalPose) or type(a.journal)~="string"
      or type(a.frame)~="table" or a.frame.dim~=a.pose.dim or not D.integer(a.frame.rot,0,3)
      or not D.integer(a.frame.ox,-60000000,60000000) or not D.integer(a.frame.oy,-60000000,60000000)
      or not D.integer(a.frame.oz,-60000000,60000000) or not D.inventory(a.inv)
      or not P.assess(a.sourceAccess,{}).ok or not P.assess(a.destinationAccess,{}).ok
      or type(a.trip)~="table" or #a.trip>1028
      or not D.integer(a.createdAt,0,2^53-2) or a.deadline~=nil and not D.integer(a.deadline,0,2^53-2)
      or not ({claim=true,routeDestination=true,verifyDestination=true,routeSource=true,probe=true,order=true,pickup=true,
        returnUnexpected=true,routeDelivery=true,deposit=true,returnGate=true,routeHome=true,home=true,settle=true,recovery=true})[a.phase]
      or not ({reserved=true,ordering=true,pickup=true,deliver=true,returning=true,["return"]=true,held=true,complete=true,refused=true})[a.stage]
      or not D.integer(a.picked,0,64) or not D.integer(a.deposited,0,64)
      or a.orderRid~=nil and not D.integer(a.orderRid,1,2^53-2)) then return false end
  end
  return true
end
D.init = function()
  if D.data then return not D.fault end
  D.data={v=1,serial=0}
  local path="so-data/build/delivery"
  local ok,store=pcall(function()
    local newest,rejected=0,0
    for _,file in ipairs({path,path..".tmp",path..".bak"}) do
      if fs and fs.exists and fs.exists(file) then
        local v,bytes=SO.store.read(file)
        assert(type(v)=="table" and D.integer(v.generation,1,2^53-2),"invalid delivery generation")
        if v.schema==1 and D.valid(v.value) and type(bytes)=="string" and #bytes<=65536 then newest=math.max(newest,v.generation)
        else rejected=math.max(rejected,v.generation) end
      end
    end
    assert(rejected==0 or rejected<newest,"invalid delivery generation")
    return SO.store.store(path,D.valid,65536)
  end)
  if not ok then D.fault=true return false end
  if store.value and not D.valid(store.value) then D.fault=true return false end
  D.box,D.data=store,store.value or D.data
  if D.data.active then
    local a=D.data.active
    if a.phase=="claim" and not a.reservationStarted and not a.orderRid and not a.intent then
      if D.refuse("delivery claim interrupted") then return not D.fault end
    end
    a.resumePhase,a.phase=a.phase,"recovery"
    a.stage,a.error="held","delivery restart; reconcile before resume"
    a.intent=nil
    D.save()
  end
  return not D.fault
end
D.save = function()
  if D.fault or not D.box or not D.box.save(D.data) then D.fault=true return false end
  return true
end
D.hold = function(reason)
  local a=D.data.active
  if a.stage~="held" then a.resumePhase=a.phase end
  a.stage,a.error,a.intent="held",reason,nil
  D.pending=nil
  D.save()
end
D.refuse = function(reason)
  local a=D.data.active
  if not a or a.phase~="claim" or a.reservationStarted or a.orderRid or a.intent or D.pending then return false end
  local lease,cells=module("lease"),module("cells")
  if lease.status and lease.status(a.worker).open then return false end
  local trip=SO.store.copy(a.trip)
  trip[#trip+1],trip[#trip+2],trip[#trip+3]=a.source,a.destination,a.home
  for _,p in ipairs(trip) do
    if cells.owner and cells.owner(p.x,p.y,p.z,p.dim)=="build:"..a.worker then return false end
  end
  local shop=module("shop")
  if shop.outputAbandon then shop.outputAbandon(a.id) end
  if type(reason)=="string" and reason:find("room support missing",1,true) then reason="room support missing" end
  a.stage,a.error="refused",reason or "room support missing"
  D.data.last,D.data.active=a,nil
  D.save()
  return true
end
D.pointById = function(id)
  for _,p in ipairs(module("drops").list and module("drops").list() or {}) do
    if p.id==id and not p.broken and not p.disabled then
      p=SO.store.copy(p) p.dim=({[0]="minecraft:overworld",[-1]="minecraft:the_nether",[1]="minecraft:the_end"})[p.dim] or p.dim
      if D.point(p) then return p end
    end
  end
end
D.pinned = function(p)
  local actual=D.pointById(p.id)
  if not actual then return false end
  for _,key in ipairs({"dim","x","y","z","side","kind"}) do if actual[key]~=p[key] then return false end end
  return true
end
D.lane = function(p)
  local mine=module("mine").mapView and module("mine").mapView()
  if not mine or mine.dim~=p.dim or not mine.homeSet then return false end
  return M.inLane({dim=mine.dim,home=mine.home,bottom=mine.bottom,mode=mine.mode,
    turtles={{branch=math.max(0,(mine.branches or 0)-1)}}},p)
end
D.contact = function(op)
  if op=="inspect" or op=="suck" then return "drop" end
  if op=="inspectDown" or op=="suckDown" then return "dropDown" end
  return op
end
D.assess = function(id,from,steps,clear)
  local lease=module("lease")
  if not lease.assess then return {ok=false,reason="safe movement unavailable"} end
  local checked={}
  for _,step in ipairs(steps) do checked[#checked+1]={op=D.contact(step.op)} end
  local check=lease.assess(id,from,checked,{owner="build",who=(D.data and D.data.active and "build:" or "gps:")..id,clear=clear})
  if not check.ok then return check end
  local at=from
  if D.lane(at) then return {ok=false,reason="mining lane"} end
  for _,step in ipairs(steps) do
    local target=P.target(at,D.contact(step.op))
    if target and D.lane(target) then return {ok=false,reason="mining lane"} end
    at=P.apply(at,step.op)
    if D.lane(at) then return {ok=false,reason="mining lane"} end
  end
  return check
end
D.path = function(id,from,to)
  if from.dim~=to.dim then return nil,"dimension mismatch" end
  if math.abs(from.x-to.x)+math.abs(from.y-to.y)+math.abs(from.z-to.z)>256 then return nil,"delivery trip too long" end
  local paths,why=P.rankPaths(from,to,{alternateAxisOrders=true},function(p,steps) return D.assess(id,p,steps,true) end)
  return paths[1],why and why.reason or "no known-clear trip"
end
D.accesses = function(p,near)
  local out={}
  if p.side=="down" then
    out[1]={dim=p.dim,x=p.x,y=p.y+1,z=p.z,facing=near.facing}
  else
    for f=0,3 do
      out[#out+1]={dim=p.dim,x=p.x-({[0]=0,1,0,-1})[f],y=p.y,z=p.z-({[0]=-1,0,1,0})[f],facing=f}
    end
    table.sort(out,function(a,b)
      local da=math.abs(a.x-near.x)+math.abs(a.z-near.z)
      local db=math.abs(b.x-near.x)+math.abs(b.z-near.z)
      return da<db or da==db and a.facing<b.facing
    end)
  end
  return out
end
D.trip = function(worker,pose,source,destination)
  local src,dst,trip,why
  for _,a in ipairs(D.accesses(source,pose)) do
    for _,b in ipairs(D.accesses(destination,a)) do
      local paths,at,total={},pose,0
      local good=true
      -- Inspect the destination before probing the output.
      for _,target in ipairs({b,a,b,pose}) do
        local path,err=D.path(worker,at,target)
        if not path then good=false why=err break end
        for _,cell in ipairs(path.cells) do paths[#paths+1]=cell end
        paths[#paths+1]=at
        total=total+path.moves at=path.pose
      end
      local sourceCheck=D.assess(worker,a,{{op=source.side=="down" and "inspectDown" or "inspect"}},false)
      local destCheck=D.assess(worker,b,{{op=destination.side=="down" and "inspectDown" or "inspect"}},false)
      if good and sourceCheck.ok and destCheck.ok then src,dst,trip=a,b,paths why=total break end
    end
    if trip then break end
  end
  if not trip then return nil,why or "no known-clear trip" end
  return {source=src,destination=dst,cells=trip,moves=why}
end
D.request = function(spec)
  if not D.enabled() then return nil,"deliveries disabled" end
  if not D.init() then return nil,"delivery save unavailable" end
  if D.data.active then return nil,"delivery busy" end
  if type(spec)~="table" or not D.item(spec.item) then return nil,"tools or invalid item refused" end
  if spec.builderJob and not D.enabled(true) then return nil,"builder material orders disabled" end
  local shop,lease=module("shop"),module("lease")
  if not shop.outputClaim or not shop.deliveryOrder or not shop.deliveryReady then return nil,"room support missing" end
  local source=D.pointById(config.storageDeliveryOutput)
  local destination=D.pointById(type(spec.destination)=="table" and spec.destination.id or spec.destination)
  if not source or not destination or destination.kind~="storage" then return nil,"delivery points missing" end
  if type(spec.destination)=="table" then
    for _,k in ipairs({"dim","x","y","z","side"}) do
      local v=spec.destination[k]
      if k=="dim" then v=({[0]="minecraft:overworld",[-1]="minecraft:the_nether",[1]="minecraft:the_end"})[v] or v end
      if destination[k]~=v then return nil,"destination changed" end
    end
  end
  if source.dim~=destination.dim or same(source,destination) then return nil,"distinct chests in one dimension required" end
  local n=spec.n
  local stack=shop.stack and shop.stack(spec.item)
  if not D.integer(n,1,stack or 0) then return nil,"bad count" end
  local fresh,stockError=shop.deliveryReady(spec.item,n)
  if not fresh then return nil,stockError or "room support missing" end
  local ids={}
  for _,id in ipairs(type(config.storageDeliveryWorkers)=="table" and config.storageDeliveryWorkers or {}) do
    if D.integer(id,0,2^53-2) then ids[#ids+1]=id end
  end
  table.sort(ids)
  local worker,pose,stat,inv,src,dst,trip,why
  for _,id in ipairs(ids) do
    local other=assigned(id) or j.turtle and not j.turtle.forgotten and j.turtle.id==id
    local drops=module("drops")
    if drops.busy and drops.busy(id) then other=true end
    local facts=D.workers[id]
    local row=lease.status and lease.status(id)
    local world=lease.world and lease.world(id,source.dim)
    if not other and row and not row.open and not row.recovering and not row.uncertain and not row.lost
      and row.parkBatch and row.setupFence and journalPose(row.pose) and type(row.journal)=="string"
      and world and P.assess(world,{}).ok and facts and facts.journal==row.journal and SO.now()-facts.at<30000 then
      local cargo=D.inventory(facts.inv)
      if cargo and #cargo==0 then
        local planned,err=D.trip(id,world,source,destination)
        local fuel=normalizeFuel(row.fuel)
        if planned and (fuel=="unlimited" or type(fuel)=="number" and fuel>=planned.moves+16) then
          worker,pose,stat,inv=id,world,row,cargo
          src,dst,trip=planned.source,planned.destination,planned.cells
          break
        end
        why=err or "delivery needs fuel for return plus 16"
      end
    end
  end
  if not worker then return nil,why or "no certain idle empty worker" end
  if lease.restartReady and not lease.restartReady() then return nil,"restart reconciliation pending" end
  local fuel=normalizeFuel(stat.fuel)
  if D.data.serial>=2^53-2 then return nil,"delivery ids exhausted" end
  D.data.serial=D.data.serial+1
  local a={id="delivery-"..string.format("%.0f",D.data.serial),requester=tostring(spec.requester or "builder"),builderJob=spec.builderJob,
    worker=worker,item=spec.item,n=n,source=source,destination=destination,home=pose,pose=pose,
    frame=P.frame(pose,stat.pose),journalPose=stat.pose,journal=stat.journal,inv=inv,fuel=fuel,
    stage="reserved",phase="claim",createdAt=SO.now(),picked=0,deposited=0,sourceAccess=src,destinationAccess=dst,trip=trip}
  D.data.active=a
  if not D.save() then return nil,"delivery save unavailable" end
  local claim,err=shop.outputClaim(a.id,source,"delivery")
  if not claim then
    if D.refuse(err) then return nil,err end
    D.hold(err) return a.id
  end
  a.roomId,a.outputToken=claim.roomId,claim.token
  D.save()
  return a.id
end
D.reserve = function(a)
  local cells=module("cells")
  if not cells.reserveMany or not cells.owner or not cells.handoff then return false,"cells unavailable" end
  a.reservationStarted=true
  if not D.save() then return false,"delivery save unavailable" end
  if cells.owner(a.pose.x,a.pose.y,a.pose.z,a.pose.dim)=="gps:"..a.worker then
    if not cells.handoff("gps:"..a.worker,"build:"..a.worker,a.pose.x,a.pose.y,a.pose.z,a.pose.dim) then
      return false,"standing reservation held"
    end
  end
  local trip=SO.store.copy(a.trip)
  trip[#trip+1],trip[#trip+2],trip[#trip+3]=a.source,a.destination,a.pose
  if not cells.reserveMany("build:"..a.worker,trip) then return false,"delivery reservation refused" end
  return true
end
D.send = function(steps,action,target,recover)
  local a=D.data.active
  local lease=module("lease")
  local stat=lease.status(a.worker)
  if D.pending or stat.open then return false end
  if stat.uncertain or not stat.parkBatch or not stat.setupFence or not journalPose(stat.pose) or type(stat.journal)~="string" then
    D.hold("delivery pose uncertain") return false
  end
  if not recover and (stat.lost or stat.journal~=a.journal or not P.samePose(a.pose,P.toWorld(a.frame,stat.pose))) then
    D.hold("delivery journal changed") return false
  end
  steps=P.boundary({steps=steps}).steps steps[1].park=true
  local check=D.assess(a.worker,a.pose,steps,not recover)
  if not check.ok then D.hold(check.reason) return false end
  local expected=a.pose
  local cells=module("cells")
  if not recover and (not cells.owner or cells.owner(a.pose.x,a.pose.y,a.pose.z,a.pose.dim)~="build:"..a.worker) then
    D.hold("delivery reservation missing") return false
  end
  for _,step in ipairs(steps) do
    local target=P.target(expected,D.contact(step.op))
    if not recover and target and cells.owner(target.x,target.y,target.z,target.dim)~="build:"..a.worker then
      D.hold("delivery reservation missing") return false
    end
    expected=P.apply(expected,step.op)
  end
  local intent={delivery=a.id,action=action,steps=steps,from=a.pose,expected=expected,journal=stat.journal,target=target}
  a.intent=intent
  if not D.save() then return false end
  local id,err=lease.send(a.worker,steps,{owner="build",who="build:"..a.worker,pose=expected,frame=a.frame,journal=stat.journal,
    recover=recover==true,clear=not recover,intent=intent,ms=15000})
  if not id then D.hold("delivery lease "..tostring(err)) return false end
  D.pending=id
  return true
end
D.route = function(target,phase)
  local a=D.data.active
  if not D.pinned(a.source) or not D.pinned(a.destination) then D.hold("delivery point changed") return end
  local path,why=D.path(a.worker,a.pose,target)
  if not path then D.hold(why) return end
  if #path.steps>0 then D.send(path.steps,"move") return end
  if a.pose.facing~=target.facing then
    D.send({{op=(target.facing-a.pose.facing)%4==3 and "turnLeft" or "turnRight"}},"move") return
  end
  a.phase,a.checked=phase,nil D.save()
end
D.check = function(target,action,point)
  local a=D.data.active
  if not a.checked or a.checked.action~=action then
    D.send({{op="gps"}},"gps",{pose=target,action=action,point=point})
  elseif a.checked.journal~=a.journal or SO.now()-(a.checked.at or 0)>10000 then D.hold("stale delivery fix")
  elseif not a.checked.inspected then
    D.send({{op=point.side=="down" and "inspectDown" or "inspect"}},"inspect",a.checked)
  else
    local slot,cargo
    for _,v in ipairs(a.inv) do if not slot then slot,cargo=v.slot,v end end
    if action=="verifyDestination" then a.phase,a.checked="routeSource",nil D.save() return end
    if action=="home" then a.phase,a.checked="settle",nil D.save() return end
    if action=="probe" or action=="pickup" then
      local occupied={} for _,v in ipairs(a.inv) do occupied[v.slot]=true end
      slot=nil for i=1,16 do if not occupied[i] then slot=i break end end
      if not slot then D.hold("delivery inventory full") return end
      D.send({{op="select",slot=slot},{op=point.side=="down" and "suckDown" or "suck",n=action=="probe" and 64 or a.n-a.picked}},action,a.checked)
    else
      if not cargo then D.hold("delivery cargo missing") return end
      if not D.item(cargo.name) then D.hold("unexpected tool cargo; manual recovery") return end
      D.send({{op="select",slot=slot},{op=point.side=="down" and "dropDown" or "drop",n=cargo.count}},action,a.checked)
    end
  end
end
D.report = function(id,worker,results,record)
  if not D.init() then return false end
  local a=D.data.active
  local intent=record and record.intent or a and a.intent
  if not a or a.worker~=worker or not intent or intent.delivery~=a.id then return false end
  if a.receipt==id then return true end
  if id~=D.pending and not (module("lease").outcome and record.intent) then return false end
  D.pending=nil
  local facts=record.report or {}
  local actual=journalPose(facts.pose) and P.toWorld(a.frame,facts.pose)
  local cargo=D.inventory(facts.inv)
  if not results or facts.uncertain or type(facts.journal)~="string" or facts.journal==intent.journal
    or not cargo or not actual or not P.confirm(intent.from,intent.steps,results,actual) then
    D.hold("delivery boundary unconfirmed; reservations held") return true
  end
  local wasHeld=a.stage=="held"
  local holdReason=a.error
  local old=a.inv
  a.pose,a.journalPose,a.journal,a.inv=actual,facts.pose,facts.journal,cargo
  if facts.fuel~=nil then a.fuel=normalizeFuel(facts.fuel) end
  a.intent=nil
  local last=results[#results]
  if intent.action=="gps" or intent.action=="recover" then
    local expected=intent.target and intent.target.pose or a.pose
    local fix=last.data
    if not last.ok or type(fix)~="table" or fix.dim~=expected.dim or not same(fix,expected)
      or not P.samePose(actual,expected) then D.hold("delivery GPS or facing mismatch") return true end
    if intent.action=="recover" then
      a.phase,a.stage,a.error=a.resumePhase or "routeSource","held","reconciled; explicit resume required"
      a.recovered=true
    else
      a.checked=SO.store.copy(intent.target) a.checked.journal,a.checked.at=a.journal,SO.now()
      if a.checked.action=="home" then a.phase,a.checked="settle",nil
      elseif a.checked.action=="returnHome" then a.phase,a.checked="routeHome",nil end
    end
  elseif intent.action=="inspect" then
    if not last.ok or not P.chestPresent(last) then D.hold("delivery chest missing") return true end
    a.checked=SO.store.copy(intent.target) a.checked.journal,a.checked.inspected=a.journal,true
  elseif intent.action=="probe" then
    a.checked=nil
    if #cargo>0 then a.phase="returnUnexpected" a.error="output not empty"
    elseif a.recoveryOnly then a.phase,a.stage="routeHome","return"
    else a.phase,a.stage="order","ordering" end
  elseif intent.action=="pickup" then
    a.checked=nil
    local count=0
    for _,v in ipairs(cargo) do
      if v.name~=a.item then a.phase="returnUnexpected" a.error="unexpected delivery cargo" break end
      count=count+v.count
    end
    if a.phase~="returnUnexpected" then
      if count>a.n then D.hold("delivery count exceeds order") return true end
      a.picked=count
      if count==a.n then a.phase,a.stage,a.error="routeDelivery","deliver",nil
      else a.error=count>0 and ("partial "..count.."/"..a.n) or nil a.pollAt=SO.now()+1000 end
    end
  elseif intent.action=="deposit" or intent.action=="returnUnexpected" then
    a.checked=nil
    local before,after=0,0
    for _,v in ipairs(old) do before=before+v.count end
    for _,v in ipairs(cargo) do after=after+v.count end
    local decrease=before-after
    if intent.action=="deposit" then
      for _,v in ipairs(old) do if v.name~=a.item then D.hold("unexpected cargo before deposit") return true end end
      for _,v in ipairs(cargo) do if v.name~=a.item then D.hold("unexpected cargo after deposit") return true end end
    end
    if not last.ok or decrease<=0 then D.hold("delivery chest full or transfer failed") return true end
    if intent.action=="deposit" then
      a.deposited=a.deposited+decrease
      if #cargo==0 then a.phase,a.stage="returnGate","return" end
    elseif #cargo==0 then D.hold(a.error or "output not empty") end
  end
  if intent.action~="recover" and (wasHeld or not D.enabled(a.builderJob~=nil)) then
    D.hold(wasHeld and holdReason or "deliveries disabled; recovery required")
  end
  a.receipt=id
  if not D.save() then return true end
  return true
end
D.status = function(id)
  if not D.init() then return {stage="held",error="delivery save unavailable"} end
  for _,a in ipairs({D.data.active or false,D.data.last or false}) do
    if a and a.id==id then
      local row=SO.store.copy(a) row.trip,row.frame,row.inv=nil,nil,nil
      row.terminal=D.data.last==a
      row.text=a.error or a.orderRid and ("ordered "..a.n.." "..a.item:gsub("^minecraft:","")) or a.stage
      if a.deposited==a.n then row.text="delivered "..a.n.." "..a.item:gsub("^minecraft:","") end
      return row
    end
  end
end
D.retry = function(id)
  if not D.init() or D.fault then return false,"delivery save unavailable" end
  local a=D.data.active
  if not a or a.id~=id or a.stage~="held" then return false,"delivery not held" end
  if not D.enabled(a.builderJob~=nil) then return false,"deliveries disabled" end
  local stat=module("lease").status(a.worker)
  if stat.open or D.pending then return false,"delivery lease pending" end
  if not a.recovered then
    if not journalPose(stat.pose) then return false,"delivery pose uncertain" end
    return D.send({{op="gps"}},"recover",{pose=P.toWorld(a.frame,stat.pose)},true)
  end
  if not module("shop").outputStatus then return false,"room support missing" end
  local room=module("shop").outputStatus(a.id)
  if not room or room.state~="settled" then return false,"room settlement required" end
  if not room.claimed then return false,"room claim proof required" end
  if not D.pinned(a.source) or not D.pinned(a.destination) then return false,"delivery point changed" end
  local count=0
  for _,v in ipairs(a.inv) do
    if v.name~=a.item or not D.item(v.name) then return false,"cargo reconciliation required" end
    count=count+v.count
  end
  if count>a.n-a.deposited then return false,"cargo reconciliation required" end
  local goal=count>0 and a.destinationAccess or a.sourceAccess
  local need=math.abs(a.pose.x-goal.x)+math.abs(a.pose.y-goal.y)+math.abs(a.pose.z-goal.z)
    +math.abs(goal.x-a.home.x)+math.abs(goal.y-a.home.y)+math.abs(goal.z-a.home.z)+16
  local fuel=normalizeFuel(stat.fuel)
  if fuel~="unlimited" and (type(fuel)~="number" or fuel<need) then return false,"delivery needs fuel for return plus 16" end
  local reserved,why=D.reserve(a)
  if not reserved then return false,why end
  a.checked,a.error,a.recovered=nil,nil,nil
  a.recoveryOnly=true
  if count>0 then a.phase,a.stage="routeDelivery","deliver"
  else a.phase,a.stage,a.recoveryOnly="routeSource","reserved",true end
  return D.save()
end
D.tick = function()
  if not D.init() or D.fault then return end
  local a=D.data.active
  if not a then return end
  local lease,shop=module("lease"),module("shop")
  if not lease.status or not lease.send or not shop.outputStatus or not shop.outputReconciled then
    if not D.refuse("delivery support missing") then D.hold("delivery support missing") end
    return
  end
  local record=lease.outcome and lease.outcome(a.worker)
  if record and record.owner=="build" and record.intent and record.intent.delivery==a.id then
    D.report(record.id,a.worker,record.results,record)
    if D.save() then lease.ackOutcome(record.id) end
    return
  end
  local claim
  if a.phase=="claim" then
    claim=shop.outputStatus(a.id)
    if not claim or claim.state~="claimed" and claim.state~="claiming" then
      local why=claim and claim.error or "room support missing"
      if not D.refuse(why) then D.hold(why) end
      return
    end
  end
  if not D.enabled(a.builderJob~=nil) then
    if a.stage~="held" then D.hold("deliveries disabled; recovery required") end
    return
  end
  if not a.recoveryOnly and a.orderRid and a.deadline and SO.now()>=a.deadline and a.picked<a.n and a.stage~="held" then
    D.hold("order timed out") return
  end
  if a.stage=="held" or D.pending or lease.status(a.worker).open then return end
  if not D.pinned(a.source) or not D.pinned(a.destination) then D.hold("delivery point changed") return end
  if a.phase=="claim" then
    if claim.state=="claimed" then
      local reserved,why=D.reserve(a)
      if not reserved then D.hold(why) return end
      a.phase="routeDestination" D.save()
    end
  elseif a.phase=="routeDestination" then D.route(a.destinationAccess,"verifyDestination")
  elseif a.phase=="verifyDestination" then D.check(a.destinationAccess,"verifyDestination",a.destination)
  elseif a.phase=="routeSource" then D.route(a.sourceAccess,"probe")
  elseif a.phase=="probe" then D.check(a.sourceAccess,"probe",a.source)
  elseif a.phase=="order" then
    a.intent={action="order"} if not D.save() then return end
    local rid,why=shop.deliveryOrder(a.id,a.item,a.n,a.source)
    if not rid then D.hold(why) return end
    a.orderRid,a.deadline,a.intent,a.phase,a.stage=rid,SO.now()+120000,nil,"pickup","pickup"
    D.save()
  elseif a.phase=="pickup" then
    if not a.pollAt or SO.now()>=a.pollAt then D.check(a.sourceAccess,"pickup",a.source) end
  elseif a.phase=="returnUnexpected" then D.check(a.sourceAccess,"returnUnexpected",a.source)
  elseif a.phase=="routeDelivery" then D.route(a.destinationAccess,"deposit")
  elseif a.phase=="deposit" then D.check(a.destinationAccess,"deposit",a.destination)
  elseif a.phase=="returnGate" then D.send({{op="gps"}},"gps",{pose=a.destinationAccess,action="returnHome"})
  elseif a.phase=="routeHome" then D.route(a.home,"home")
  elseif a.phase=="home" then D.send({{op="gps"}},"gps",{pose=a.home,action="home"})
  elseif a.phase=="settle" then
    if #a.inv>0 then D.hold("cargo reconciliation required") return end
    if not shop.outputReconciled(a.id) then D.hold("output save failed") return end
    local row=shop.outputStatus(a.id)
    if row then return end
    local cells=module("cells")
    if not cells.handoff or not cells.releaseOwner then D.hold("reservation reconciliation unavailable") return end
    if not cells.handoff("build:"..a.worker,"gps:"..a.worker,a.pose.x,a.pose.y,a.pose.z,a.pose.dim) then D.hold("standing reservation held") return end
    if not cells.releaseOwner("build:"..a.worker) then D.hold("delivery reservations held") return end
    if a.deposited==a.n then a.stage,a.error="complete",nil
    else a.stage,a.error="held","delivery reconciled; request again explicitly" end
    D.data.last,D.data.active=a,nil D.save()
  end
end
local function capability(msg)
  local body=msg.body
  if type(body) == "table" then
    local journal=type(body.journal)=="table" and body.journal.id or body.journal
    D.workers[msg.from]={journal=journal,inv=SO.store.copy(body.inv),at=SO.now()}
    S.safe[msg.from]=type(body.capabilities) == "table" and body.capabilities.parkBatch == true
  end
end
local function input(ev)
  local text = ev.text or ev.id
  if type(text) ~= "string" then return end
  S.feedback = nil
  local session = ev.session or S.view
  if text == "setup" or text == "tab:setup" then session.buildSetup,session.buildPick=true,nil return end
  if text == "build-back" or text == "tab:job" then session.buildSetup,session.buildPick=false,nil return end
  if text == "material-pick" then session.buildPick={page=1} return end
  if text == "material-back" then session.buildPick=nil return end
  if session.buildPick and (text == "prev" or text == "next") then
    session.buildPick.page=math.max(1,session.buildPick.page+(text == "next" and 1 or -1))
    return
  end
  if text == "from-here" or text == "to-here" or text == "home-here" then
    if not S.poseSetup then return end
    local row = j.turtle
    local stat = row and module("lease").status and module("lease").status(row.id)
    local p = row and row.pose
    if not p or row.forgotten or not SO.pair or not SO.pair.key(row.id) or S.recover
      or not stat or stat.open or stat.lost or stat.uncertain or j.running or S.pending then feedback("paired pose unavailable") return end
    if p.dim ~= j.dim or not whole(p.x) or not whole(p.y) or not whole(p.z)
      or not whole(p.facing) or p.facing<0 or p.facing>3 then feedback("paired pose unavailable") return end
    if returning() then feedback("finish return before configuring") return end
    if text == "home-here" then j.home=SO.store.copy(p) save() return end
    if text == "from-here" then session.buildCorner=SO.store.copy(p) return end
    local first = session.buildCorner
    if not first or first.dim ~= p.dim or p.dim ~= j.dim then feedback("set first corner") return end
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
  if w[1]=="remove" and returning() then feedback("finish return before removing worker") return end
  if S.workerPark and (w[1]=="park" or w[1]=="resume" or w[1]=="remove") and #w==2 then
    local row=j.turtle
    if not row or tonumber(w[2])~=row.id then feedback("unknown turtle") return end
    if row.forgotten then feedback("device forgotten; re-pair and re-add turtle") return end
    if w[1]=="resume" then
      local cells,p=module("cells"),row.pose
      if cells.owner and cells.owner(p.x,p.y,p.z,p.dim)=="gps:"..row.id then
        local ok,err=cells.handoff("gps:"..row.id,owner(),p.x,p.y,p.z,p.dim)
        if not ok then feedback(err) return end
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
    if not ok then feedback(err) return end
    if not j.blueprint or not j.turtle or not j.material then feedback("configure area, material, turtle") return end
    S.targets, err = expand(j.blueprint)
    if not S.targets then feedback(err) return end
    if j.cursor > #S.targets and not returning() then j.running=false save() return end
    if j.returnHome or returning() then
      if not j.home or j.home.dim~=j.dim or not P.assess(j.home,{}).ok then feedback("set builder home before return-on") return end
      local stat=module("lease").status(j.turtle.id)
      if j.fuel~=nil and stat.fuel~=nil then j.fuel=normalizeFuel(stat.fuel) end
      local ready,why,cause=returnReady(stat)
      if not ready then alert(why,cause) return end
    end
    local checks=returning() and {} or readiness()
    local missing=P.missing(checks)
    if #missing>0 then
      if j.blocked then feedback(table.concat(missing,"; "))
      else
        for _, check in ipairs(checks) do
          if not check.ok then alert(table.concat(missing,"; "), check.cause) break end
        end
      end
      return
    end
    j.running,j.blocked,j.alert,j.phase,j.legacyHold=true,nil,nil,"check",nil
    if returning() then j.completion.hold=nil end
    if j.service then j.service.hold=nil end
    save()
    return
  end
  local status = j.turtle and module("lease").status and module("lease").status(j.turtle.id) or {}
  local reanchor = w[1] == "add" and j.turtle and tonumber(w[2]) == j.turtle.id and status.uncertain
  if (j.running or S.pending or status.open) and not reanchor then feedback("stop before configuring") return end
  if returning() and not reanchor then feedback("finish return before configuring") return end
  if j.placement and w[1]~="add" then feedback("reconcile placement before configuring") return end
  if w[1]=="return" and #w==2 and (w[2]=="on" or w[2]=="off") then
    if w[2]=="on" then
      if not j.home or j.home.dim~=j.dim or not P.assess(j.home,{}).ok then feedback("set builder home before return-on") return end
      local ready,why=returnReady(status)
      if not ready then feedback(why) return end
    end
    j.returnHome=w[2]=="on"
  elseif w[1]=="home" and #w==5 then
    local p={dim=j.dim,x=tonumber(w[2]),y=tonumber(w[3]),z=tonumber(w[4]),facing=({n=0,e=1,s=2,w=3})[w[5]]}
    if not whole(p.x) or not whole(p.y) or not whole(p.z) or p.facing==nil then feedback("home needs x y z n|e|s|w") return end
    j.home=p
  elseif w[1] == "area" and #w == 7 then
    local n={}
    for i=2,7 do n[i]=tonumber(w[i]) if not whole(n[i]) then feedback("invalid area") return end end
    local b={x1=math.min(n[2],n[5]),y1=math.min(n[3],n[6]),z1=math.min(n[4],n[7]),
      x2=math.max(n[2],n[5]),y2=math.max(n[3],n[6]),z2=math.max(n[4],n[7]),shape=j.shape or "floor",dim=j.dim}
    local cells,err=expand(b)
    if not cells then feedback(err) return end
    j.blueprint,j.cursor,j.phase,j.service=b,1,"check",nil
    S.targets=cells
  elseif w[1] == "shape" and #w == 2 and shapes[w[2]] then
    j.shape=w[2]
    if j.blueprint then j.blueprint.shape=w[2] S.targets=expand(j.blueprint) end
    j.cursor,j.phase,j.service=1,"check",nil
  elseif w[1] == "material" and #w == 2 and material(w[2]) then
    j.material,j.phase,j.service,session.buildPick=material(w[2]),"check",nil,nil
  elseif w[1] == "import" then
    local b,err=import(text:match("^%S+%s+(.+)$"))
    if not b then feedback(err) return end
    b.dim=j.dim
    j.blueprint,j.shape,j.material,j.cursor,j.phase,j.service=b,b.shape,b.material,1,"check",nil
    S.targets=expand(b)
  elseif w[1] == "add" and (#w == 2 or #w == 6) then
    local id=tonumber(w[2])
    if not whole(id) or id < 0 then feedback("invalid turtle") return end
    if j.turtle and j.turtle.forgotten and j.turtle.id == id and #w ~= 6 then feedback("add needs x y z n|e|s|w") return end
    if j.turtle and not j.turtle.forgotten and j.turtle.id ~= id then feedback("builder already has a turtle") return end
    local lease=module("lease")
    local stat=lease.status and lease.status(id) or {}
    if stat.open and not stat.uncertain then feedback("turtle has open lease") return end
    local other=assigned(id)
    if other then feedback("turtle assigned to " .. other) return end
    local pose
    if #w == 6 then
      local x,y,z=tonumber(w[3]),tonumber(w[4]),tonumber(w[5])
      local f=({n=0,e=1,s=2,w=3})[w[6]]
      if whole(x) and whole(y) and whole(z) and f then pose={dim=j.dim,x=x,y=y,z=z,facing=f} end
    else
      if not lease.locate then feedback("GPS unavailable; use explicit add") return end
      S.locating=(S.locating or 0)+1
      local attempt=S.locating
      lease.locate(id,j.dim,function(found,err)
        if attempt~=S.locating then return end
        if not found then feedback(err or "GPS locate failed") return end
        if found.dim~=j.dim or not whole(found.x) or not whole(found.y) or not whole(found.z)
          or not whole(found.facing) or found.facing<0 or found.facing>3 then feedback("invalid GPS pose") return end
        input({text=string.format("add %d %d %d %d %s",id,found.x,found.y,found.z,({[0]="n","e","s","w"})[found.facing])})
      end)
      return
    end
    if not pose then feedback("add needs x y z n|e|s|w") return end
    if SO.pair and SO.pair.key and not SO.pair.key(id) then feedback("turtle is not paired") return end
    if stat.uncertain then
      local ok,err=lease.reanchor(id,pose)
      if not ok then feedback(err) return end
      S.pending=nil
      j.running=false
    end
    S.locating=(S.locating or 0)+1
    if lease.claimProbe then
      local ok,err=lease.claimProbe(id,"build:"..id,pose)
      if not ok then feedback(err) return end
    end
    j.turtle={id=id,pose=pose,anchor=SO.store.copy(pose)}
    if not j.home then j.home=SO.store.copy(pose) end
    j.inv,j.fuel=nil,nil
    S.recover=true
    j.blocked,j.alert=nil,nil
    if save() and lease.clearProbe then
      local ok,err=lease.clearProbe(id)
      if not ok then feedback(err) end
    end
    return
  else feedback("invalid command") return end
  if w[1]=="area" or w[1]=="shape" or w[1]=="import" then j.complete,j.announced,j.completion=nil,nil,nil end
  j.blocked,j.alert=nil,nil
  save()
end
S.view = {}
-- The text cut to width, a cut marked with "..." as route A marks it (other.py cut).
local function cut(text, width)
  if #text <= width then return text end
  if width < 4 then return text:sub(1,math.max(0,width)) end
  return (U.fit(text,width-3):gsub("[%s%.]+$","")).."..."
end
-- The picker's rows from the last inventory report: one per item name with its summed count,
-- sorted by the drawn name. nil before the first report, an empty list for an empty inventory.
local function stock()
  if j.inv == nil then return nil end
  local counts,out={},{}
  for _,v in ipairs(j.inv) do
    if type(v.name) == "string" and type(v.count) == "number" and v.count > 0 then
      if not counts[v.name] then out[#out+1]=v.name counts[v.name]=0 end
      counts[v.name]=counts[v.name]+v.count
    end
  end
  for i,name in ipairs(out) do out[i]={name=name,label=(name:gsub("^minecraft:","")),count=counts[name]} end
  table.sort(out,function(a,b) return a.label < b.label or a.label == b.label and a.name < b.name end)
  return out
end
-- Route A (docs/ui/schematic/other.py build): the job tab has the shape with its state, the cells
-- placed, the material budget and the job's leaders; setup has the shape chips and the configured
-- values, and its material chip opens a paged picker of the turtle's reported items. START and STOP
-- sit on the last row of both. Under 24 columns the bar has no tabs and only the job tab draws.
local function render(w,h,session)
  session=session or S.view
  local C=U.canvas(w,h)
  local gap,lw=h>=16 and 1 or 0,math.min(w-2,40)
  local state=j.legacyHold and "hold" or j.blocked or (j.complete and "COMPLETE" or returning() and "RETURNING" or j.running and "running" or "stopped")
  local tone=U.tone(state)
  if j.blocked and tone~="e" then tone="1" end
  local shape=({platform="floor",wall="walls"})[j.shape] or j.shape or "floor"
  local b,t=j.blueprint,j.turtle
  local from=b and (b.x1 .. "," .. b.y1 .. "," .. b.z1)
  local to=b and (b.x2 .. "," .. b.y2 .. "," .. b.z2)
  local stuff=j.material and (j.material:gsub("^minecraft:",""))
  local narrow=w<24
  local setup=session.buildSetup and not narrow
  if narrow then C.bar("BUILD",{},nil)
  else U.roleBar(C,"BUILD",{"job","setup"},{"job","setup"},setup and 2 or 1) end
  local y=2+gap
  local message=S.feedback and SO.now()<S.feedbackUntil and S.feedback or j.alert or j.legacyHold
  if message then y=y+U.flagLines(C,2,y,w-2,message,nil,2)+gap end
  if setup and session.buildPick then
    -- The picker: one whole-row target per reported item, the current material marked.
    local items=stock()
    C.section(2,y,lw,"MATERIAL")
    local top=y+1+gap
    local capacity=math.max(1,h-top)
    local count=items and #items or 0
    local pages=math.max(1,math.ceil(count/capacity))
    local pick=session.buildPick
    pick.page=math.max(1,math.min(pick.page,pages))
    if not items then C.put(2,top,"no report","1")
    elseif count == 0 then C.put(2,top,"empty","8") end
    for i=1,capacity do
      local item=items and items[(pick.page-1)*capacity+i]
      if not item then break end
      local ry,value=top+i-1,tostring(item.count)
      local on=item.name == j.material
      local label=cut(item.label,math.max(1,w-5-#value))
      if on then C.put(2,ry,U.g.bullet,"0") end
      C.leader(4,ry,w-4,label,value,on and "0" or "8",on and "0" or "8")
      C.hit("material "..item.name,1,ry,w,1,label)
    end
    C.chip(2,h,"BACK","material-back")
    if pages > 1 then U.pager(C,h,pick.page.."/"..pages,pick.page>1,pick.page<pages) end
    return C.frame()
  end
  if setup then
    local cx=w>=36 and 13 or 11
    C.put(2,y,"shape","8")
    if cx+(S.solid and 28 or 20)<=w-1 then
      local x=cx
      for _,name in ipairs(S.solid and {"floor","walls","box","solid"} or {"floor","walls","box"}) do x=C.chip(x,y,name,"shape " .. name,name==shape and "plain" or "off")+1 end
    else C.chip(cx,y,shape,"shape-next") end
    local draft=session.buildCorner
    local rows={{"from",draft and (draft.x..","..(draft.y-1)..","..draft.z) or from,S.poseSetup and "from-here"},
      {"to",to,S.poseSetup and "to-here"},{"material",stuff,"material-pick"},{"turtle",t and ("#" .. t.id)},
      {"home",j.home and U.turtle.pose(j.home),S.poseSetup and "home-here"}}
    for i,r in ipairs(rows) do
      local ry=y+i*(h>=16 and 2 or 1)
      if ry<h-gap then
        C.put(2,ry,r[1],"8")
        if r[3] then C.chip(cx,ry,cut(r[2] or "-",math.max(1,w-cx-3)),r[3],r[2] and "plain" or "off")
        else C.put(cx,ry,cut(r[2] or "-",math.max(0,w-cx)),r[2] and "0" or "8") end
      end
    end
  else
    local total=S.targets and #S.targets or 0
    local done=math.min(j.cursor-1,total)
    local frac=done .. "/" .. total
    local title=shape:upper()
    if #title+#state+3<=lw then C.section(2,y,lw,title,state,tone) else C.put(2,y,cut(state,lw),tone) end
    C.progress(2,y+1,math.max(1,lw-1-#frac),done,total)
    if j.complete then C.put(2+lw-#frac,y+1,frac,"0") end
    local need=budget()
    local carried=need.carried and tostring(need.carried) or "unknown"
    local facts={{"material",stuff},{"need",b and tostring(need.remaining)},
      {"carried",j.material and carried,need.carried==nil and "1"},
      {"turtle",t and ("#" .. t.id)},{"position",t and U.turtle.pose(t.pose)},
      {"fuel",j.fuel and tostring(j.fuel)},{"from",from},{"to",to}}
    for i,f in ipairs(facts) do
      local ry=y+1+gap+i
      local value,fg,room=f[2] or "-",f[3] or f[2] and "0" or "8",lw-#f[1]-2
      -- Too narrow for the label beside the value: the value alone.
      if ry<h-gap and (#value<=room or room>=4) then C.leader(2,ry,lw,f[1],cut(value,room),fg)
      elseif ry<h-gap then C.put(2,ry,cut(value,lw),fg) end
    end
  end
  U.actions(C,h,{{"START","start",j.running and "muted" or "primary"},{"STOP","stop",j.running and "stop" or "muted"}})
  return C.frame()
end
S.reconcile = function(record)
  local lease = module("lease")
  record = record or lease.outcome and lease.outcome(j.turtle.id)
  if not record or record.owner ~= "build" then return false end
  local receipt = record.id .. ":" .. record.status
  if j.leaseReceipt ~= receipt then
    S.pending = SO.store.copy(record.intent) or {action="recover",steps=record.steps,pose=j.turtle.pose}
    S.pending.id = record.id
    S.recover = false
    S.reconciling = true
    report(record.id,j.turtle.id,record.results,record)
    S.reconciling = nil
    j.leaseReceipt = receipt
  end
  if save() then lease.ackOutcome(record.id) end
  return true
end
S.report = function(id,turtleId,results,record)
  if D.report(id,turtleId,results,record) then
    local lease=module("lease")
    if lease.ackOutcome and D.save() then lease.ackOutcome(id) end
    return
  end
  if not j.turtle or j.turtle.forgotten or j.turtle.id ~= turtleId then return end
  if module("lease").outcome then S.reconcile(record)
  else report(id,turtleId,results,record) end
end
local function tick()
  D.tick()
  if j.complete and not j.announced and not save() then return end
  if S.pauseCleared then
    if not save() then return end
    S.pauseCleared=nil
  end
  publish()
  local lease,display=module("lease"),module("display")
  if not S.wired and display.screen then display.screen("build",render,input) S.wired=true end
  if not S.callback and lease.onReport then lease.onReport("build",S.report) S.callback=true end
  local mine=module("mine")
  S.mine=mine.mapView and mine.mapView() or nil
  if not j.turtle or j.turtle.forgotten or not lease.status or not S.callback then return end
  S.targets=S.targets or (j.blueprint and expand(j.blueprint))
  local other=assigned(j.turtle.id)
  if other then j.running=false alert("turtle assigned to " .. other, "assignment_conflict") return end
  if S.reconcile() then return end
  local stat=lease.status(j.turtle.id)
  if stat.uncertain then j.turtle.parkConfirmed=nil alert("pose uncertain; re-add turtle","pose_uncertain") return end
  if S.pending or stat.open then return end
  if S.recover or stat.lost then
    local cells,p=module("cells"),j.turtle.pose
    local gps="gps:"..j.turtle.id
    if cells.owner and cells.owner(p.x,p.y,p.z,p.dim)==gps then
      if not cells.handoff then alert("standing cell handoff unavailable", "reservation") return end
      local ok,err=cells.handoff(gps,owner(),p.x,p.y,p.z,p.dim)
      if not ok then alert(err, "reservation") return end
    end
    j.turtle.parkConfirmed=nil
    if j.turtle.paused then j.turtle.state="parking" end
    send({{op="inspectDown"}},"recover",true)
    return
  end
  if j.legacyHold then return end
  if S.workerPark and j.turtle.paused then
    if j.turtle.removeRequested and j.turtle.parkConfirmed then removeParked()
    elseif not j.turtle.parkConfirmed or not S.parkAt or SO.now()-S.parkAt>=540000 then
      if send({{op="inspectDown"}},"workerPark",true) then S.parkAt=SO.now() end
    end
    return
  end
  if lease.restartReady and not lease.restartReady() then return end
  if j.service and j.service.stage=="deliveryVacate" then
    if not j.running then return end
    if not D.enabled(true) then alert("deliveries disabled; recovery required","material") return end
    if not j.home or same(j.home,j.service.access) then alert("move builder home away from delivery chest","material") return end
    if not route(j.home) then return end
    j.service.deliveryVacate,j.service.stage=nil,"deliveryWait"
    if not save() then return end
    local shop=module("shop")
    local n=shop.stack and shop.stack(j.material) or 64
    local delivery,why=D.request({item=j.material,n=n,destination=j.service.point,requester="builder",builderJob=owner()})
    j.service.deliveryId,j.service.deliveryError=delivery,why
    if not delivery then
      j.service.stage,j.service.deliveryDone="check",true
      j.retryAt=SO.now()+10000
    end
    local status=delivery and D.status(delivery)
    alert(status and status.text or why or "out of material","material")
    save()
    return
  end
  if j.service and j.service.stage=="deliveryWait" and not j.service.deliveryId then
    j.service.stage,j.service.deliveryDone="check",true
    j.retryAt=SO.now()+10000
    alert(j.service.deliveryError or "delivery refused","material") save()
  end
  if j.service and j.service.deliveryId and not j.service.deliveryDone then
    local status=D.status(j.service.deliveryId)
    if status and status.stage=="complete" then
      j.service.deliveryDone,j.service.stage=true,"travel"
      j.blocked,j.alert,j.retryAt="material",nil,SO.now()
      save()
    elseif status and status.terminal then
      j.service.deliveryDone,j.service.stage=true,"check"
      j.retryAt=SO.now()+10000
      alert(status.text,"material") save()
    else
      alert(status and status.text or "delivery status unavailable","material")
      return
    end
  end
  if j.service and j.service.hold then return end
  if returning() then
    if not j.running or j.blocked then return end
    local ready,why,cause=returnReady(stat)
    if not ready then alert(why,cause) return end
    local target=j.completion.target
    if not target or target.dim~=j.dim or not P.assess(target,{}).ok then alert("return home missing","pose_uncertain") return end
    if P.samePose(j.turtle.pose,target) then finish() save() return end
    local need=distance(j.turtle.pose,target)
    if j.fuel~="unlimited" and (type(j.fuel)~="number" or j.fuel<need) then alert("out of fuel for return","fuel") return end
    route(target)
    return
  end
  if j.service and j.service.kind=="fuel" and not S.fuelTrips then
    j.running=false alert("builder fuel trips disabled", "fuel") return
  end
  if j.service and j.service.kind=="fuel" and j.fuel=="unlimited" then
    j.service,j.blocked,j.alert,j.retryAt=nil,nil,nil,nil save()
  end
  local retrying = j.retryAt and SO.now()>=j.retryAt and j.service
    and (j.blocked=="material" and j.service.kind=="storage" or j.blocked=="fuel" and j.service.kind=="fuel")
  if S.fuelTrips and j.running and (not j.blocked or j.blocked=="fuel") and type(j.fuel)=="number" then
    local target=S.targets and S.targets[j.cursor]
    local need,err,cause
    if target then need,err,cause=fuelNeed(target) end
    if need and j.fuel<need or j.service and j.service.stage=="refuel" then
      local carried=fuelItem()
      if carried then
        send({{op="select",slot=carried.slot},{op="refuel",n=math.min(carried.count,math.max(1,math.ceil((math.max(2000,need or 0)-j.fuel)/P.fuelValue(carried.name))))}},"refuel")
        return
      elseif not j.service or j.service.kind~="fuel" then supply("fuel") return end
    elseif target and not need then alert(err, cause) return end
  end
  local atFuel = S.fuelTrips and j.service and j.service.kind=="fuel" and same(j.turtle.pose,j.service.access)
  if j.running and not atFuel and (j.blocked == "fuel" or not j.blocked and type(j.fuel)=="number" and j.fuel>=0 and j.fuel<1) then
    alert("out of fuel", "fuel")
    send({{op="inspectDown"}},"fuel")
    return
  end
  if not j.running or j.blocked and not retrying then return end
  S.targets=S.targets or expand(j.blueprint)
  local target=S.targets and S.targets[j.cursor]
  if not target then j.running,j.complete,j.blocked,j.alert=false,true,nil,nil save() return end
  if j.service then
    local service=j.service
    if service.stage == "travel" then
      if not route(service.access) then return end
      service.stage="check" save()
    end
    if service.stage == "check" then
      if not route(service.access) then return end
      send({{op=service.point.side=="down" and "inspectDown" or "inspect"}},"supplyCheck")
    elseif service.stage == "take" then
      local slot=empty()
      if not slot then alert("inventory full", "inventory_full") return end
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
  j.turtle.forgotten, j.running, j.blocked, j.alert = true, false, "device_forgotten", "device forgotten; re-pair and re-add turtle"
  S.pending, S.recover = nil, true
  return save()
end
local function facts()
  local total = j.blueprint and S.targets and #S.targets or 0
  local done = math.max(0, math.min(j.cursor-1, total))
  local complete = j.blueprint and not returning() and j.blocked~="save" and (j.complete or total>0 and done==total)
  local row = j.turtle
  local stat = row and module("lease").peek and module("lease").peek(row.id) or {}
  local out = {dim=j.dim, running=j.running==true, done=done, total=total,
    state=not j.blueprint and "idle" or complete and "complete" or (j.blocked or j.legacyHold) and "held"
      or (S.recover or stat.lost or stat.uncertain) and row and not row.forgotten and "recovering"
      or returning() and "returning" or j.running and "running" or "stopped"}
  if j.blueprint then
    out.bounds={dim=j.dim}
    for _, field in ipairs({"x1","y1","z1","x2","y2","z2"}) do out.bounds[field]=j.blueprint[field] end
  end
  if row and not row.forgotten then
    out.turtleId=row.id
    local p=row.pose
    local f=p and (p.facing or p.f)
    if not S.recover and not stat.lost and not stat.uncertain and j.blocked~="pose_uncertain"
      and j.blocked~="lost" and j.blocked~="dimension_mismatch" and p and p.dim==j.dim
      and whole(p.x) and whole(p.y) and whole(p.z) and whole(f) and f>=0 and f<=3 then
      out.pose={x=p.x,y=p.y,z=p.z,f=f,dim=p.dim}
    end
  end
  local cause=not complete and causes[j.blocked]
  if cause then
    out.alert={key="build:"..j.blocked,severity=cause[1],text=cause[2],target="build",
      actions=j.blocked=="device_forgotten" and {"setup"} or nil}
  end
  return out
end
local function turtleView()
  if not j.turtle or j.turtle.forgotten then return {} end
  local f=facts()
  local pose=SO.store.copy(f.pose)
  if pose then pose.facing=pose.f end
  return {[tostring(j.turtle.id)]={role="build",pose=pose,anchor=SO.store.copy(j.turtle.anchor),
    state=j.turtle.state or f.state,alert=f.alert,
    paused=j.turtle.paused,parkConfirmed=j.turtle.parkConfirmed,inv=SO.store.copy(j.inv or {}),fuel=j.fuel,
    done=f.done,total=f.total,error=j.alert,step=S.pending and S.pending.action}}
end
local function mapView()
  local f=facts()
  local turtles={}
  if f.turtleId and f.pose then
    turtles[tostring(f.turtleId)]={id=f.turtleId,dim=f.dim,pose=f.pose,state=f.state,alert=f.alert}
  end
  return {dim=f.dim,bounds=f.bounds,turtles=turtles}
end
return {name="build",forget=forget,assigned=function(id) return j.turtle and not j.turtle.forgotten and j.turtle.id == id or D.init() and D.data.active and D.data.active.worker==id or false end,deliveryRequest=D.request,deliveryStatus=D.status,deliveryRetry=D.retry,deliveryItem=D.item,handlers={hello=capability,["step.report"]=capability},tick=tick,facts=facts,mapView=mapView,budget=budget,expand=expand,import=import,dugProtection=protect,turtleView=turtleView}
