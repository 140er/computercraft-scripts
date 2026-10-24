local P = dofile("so-plan.lua")
local U = dofile("so-ui.lua")
local M = dofile("so-mine-plan.lua")
local S = { recover = true, published = false, safe = {} }
local shapes = { floor = true, platform = true, wall = true, walls = true, box = true }
local dimensions = { ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1, ["minecraft:the_end"] = 1 }
local function whole(n)
  return type(n) == "number" and n == n and math.abs(n) < 30000000 and n % 1 == 0
end
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
          if b.shape == "floor" or b.shape == "platform" or edge
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
local j = box.value or { dim="minecraft:overworld", cursor=1, running=false, phase="check", inv={} }
local function publish()
  local state=module("state")
  if S.published ~= j.alert and state.emit then
    local ok=state.emit("build.alert",j.alert and {text=j.alert,id=j.turtle and j.turtle.id} or false)
    if ok ~= false then S.published=j.alert end
  end
end
local function save()
  local ok, err = box.save(j)
  if not ok then j.running, j.alert = false, "save failed: " .. tostring(err) end
  publish()
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
  if not save() then return false end
  local id
  id, err = lease.send(j.turtle.id,steps,{owner="build",recover=recover==true,pose=at})
  if not id then
    j.intent = nil
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
local function supply()
  local drops = module("drops")
  if not drops.pick then alert("storage drop unavailable") return end
  local p = j.turtle.pose
  local picked = drops.pick("storage",{dim=dimensions[j.dim],x=p.x,y=p.y,z=p.z})
  local point = picked and picked.point
  if not point then alert("storage drop unavailable") return end
  if point.dim ~= dimensions[j.dim] then alert("storage dimension mismatch") return end
  local access
  if point.side == "down" then access = {dim=j.dim,x=point.x,y=point.y+1,z=point.z}
  else
    local dx,dz = {[0]=0,1,0,-1},{[0]=-1,0,1,0}
    local best
    for f=0,3 do
      local a = {dim=j.dim,x=point.x-dx[f],y=point.y,z=point.z-dz[f],facing=f}
      local held = module("cells").owner and module("cells").owner(a.x,a.y,a.z,a.dim)
      local inside = a.x>=j.blueprint.x1 and a.x<=j.blueprint.x2 and a.z>=j.blueprint.z1
        and a.z<=j.blueprint.z2 and a.y>=j.blueprint.y1 and a.y<=j.blueprint.y2
      local distance = math.abs(p.x-a.x)+math.abs(p.y-a.y)+math.abs(p.z-a.z)
      if not inside and not lane(a) and (not held or held == owner()) and (not best or distance<best) then access,best=a,distance end
    end
  end
  if not access then alert("no storage access") return end
  j.service = {point=point,access=access,stage="travel"}
  j.phase = "check"
  save()
end
local function advance()
  j.cursor, j.phase = j.cursor+1, "check"
  if j.cursor > #S.targets then j.running, j.alert = false, nil end
end
local function report(id, turtleId, results, lease)
  local pending = S.pending
  if not j.turtle or j.turtle.forgotten or turtleId ~= j.turtle.id or not pending or pending.id ~= id then return end
  S.pending = nil
  if not results or not lease.report or not lease.report.pose then
    S.recover = true
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
  if facts.fuel ~= nil then j.fuel = facts.fuel end
  local action, last = pending.action, results[#results]
  j.intent = nil
  if action == "recover" then
    S.recover, j.blocked, j.alert, j.phase = false, nil, nil, "check"
    if j.service then j.service.stage = "travel" end
  elseif action == "fuel" then
    if j.fuel == "unlimited" or type(j.fuel) == "number" and j.fuel >= 1 then
      j.blocked, j.alert = nil, nil
    else alert("out of fuel", "fuel") end
  elseif action == "check" then
    if last.ok and last.data and last.data.name == j.material then advance()
    elseif last.ok then alert("build cell occupied")
    elseif last.err == "No block to inspect" then j.phase = "place"
    else alert("build cell unknown") end
  elseif action == "place" then
    if last.ok then advance() else j.phase="check" alert("placement failed") end
  elseif action == "supplyCheck" then
    if last.ok and last.data and (last.data.name:find("chest",1,true)
      or last.data.name:find("barrel",1,true) or last.data.name:find("shulker",1,true)) then
      j.service.stage = "take"
    else alert("storage chest missing") end
    local drops = module("drops")
    if drops.note then drops.note(j.service.point.id,last.ok and last.data and last.data.name or nil) end
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
  if text == "shape-next" then
    local order={"floor","walls","box"}
    local nextShape={floor=2,platform=2,wall=3,walls=3,box=1}
    text="shape " .. order[nextShape[j.shape or "floor"] or 1]
  end
  if text == "status" then return end
  local w = {}
  for word in text:gmatch("%S+") do w[#w+1]=word end
  if w[1] == "stop" then j.running=false save() return end
  if w[1] == "start" then
    local state = module("state")
    local ok, err = false,"disk guard unavailable"
    if state.canStart then ok,err=state.canStart() end
    if not ok then alert(err) return end
    if not j.blueprint or not j.turtle or not j.material then alert("configure area, material, turtle") return end
    S.targets, err = expand(j.blueprint)
    if not S.targets then alert(err) return end
    if j.cursor > #S.targets then alert("build complete") return end
    j.running,j.blocked,j.alert,j.phase=true,nil,nil,"check"
    save()
    return
  end
  local status = j.turtle and module("lease").status and module("lease").status(j.turtle.id) or {}
  local reanchor = w[1] == "add" and j.turtle and tonumber(w[2]) == j.turtle.id and status.uncertain
  if (j.running or S.pending or status.open) and not reanchor then alert("stop before configuring") return end
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
  elseif w[1] == "material" and #w == 2 and material(w[2]) then j.material=material(w[2]) j.cursor=1 j.phase="check"
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
      local state=module("state")
      local machine=state.get and state.get("machines/" .. id)
      pose=machine and machine.pose and SO.store.copy(machine.pose)
      if pose and (pose.dim ~= j.dim or not whole(pose.x) or not whole(pose.y) or not whole(pose.z) or not whole(pose.facing) or pose.facing<0 or pose.facing>3) then pose=nil end
    end
    if not pose then alert("add needs x y z n|e|s|w") return end
    if SO.pair and SO.pair.key and not SO.pair.key(id) then alert("turtle is not paired") return end
    if stat.uncertain then
      local ok,err=lease.reanchor(id,pose)
      if not ok then alert(err) return end
      S.pending=nil
      j.running=false
    end
    j.turtle={id=id,pose=pose,anchor=SO.store.copy(pose)}
    j.home=SO.store.copy(pose)
    j.inv,j.fuel={},nil
    S.recover=true
  else alert("invalid command") return end
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
  local state=j.blocked or (j.running and "running" or "stopped")
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
    if cx+20<=w-1 then
      local x=cx
      for _,name in ipairs({"floor","walls","box"}) do x=C.chip(x,y,name,"shape " .. name,name==shape and "plain" or "off")+1 end
    else C.chip(cx,y,shape,"shape-next") end
    local rows={{"from",from},{"to",to},{"material",stuff},{"turtle",t and ("#" .. t.id)},{"home",j.home and U.turtle.pose(j.home)}}
    for i,r in ipairs(rows) do
      local ry=y+i*(h>=16 and 2 or 1)
      if ry<h-gap then
        C.put(2,ry,r[1],"8")
        C.put(cx,ry,(r[2] or "-"):sub(1,math.max(0,w-cx)),r[2] and "0" or "8")
      end
    end
  else
    local total=S.targets and #S.targets or 0
    local done=math.min(j.cursor-1,total)
    local frac=done .. "/" .. total
    C.section(2,y,lw,shape:upper(),state,tone)
    C.progress(2,y+1,math.max(1,lw-1-#frac),done,total)
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
  if stat.uncertain then alert("pose uncertain; re-add turtle","pose uncertain") return end
  if S.pending or stat.open then return end
  if S.recover or stat.lost then send({{op="inspectDown"}},"recover",true) return end
  if j.blocked == "material" and j.retryAt and SO.now() >= j.retryAt then
    j.blocked=nil
  end
  if j.running and (j.blocked == "fuel" or not j.blocked and type(j.fuel)=="number" and j.fuel>=0 and j.fuel<1) then
    alert("out of fuel", "fuel")
    send({{op="inspectDown"}},"fuel")
    return
  end
  if not j.running or j.blocked then return end
  S.targets=S.targets or expand(j.blueprint)
  local target=S.targets and S.targets[j.cursor]
  if not target then j.running=false save() return end
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
    if not carried then supply() return end
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
  j.turtle.forgotten, j.running, j.blocked = true, false, "device forgotten"
  S.pending, S.recover = nil, true
  return save()
end
return {name="build",forget=forget,assigned=function(id) return j.turtle and not j.turtle.forgotten and j.turtle.id == id or false end,handlers={hello=capability,["step.report"]=capability},tick=tick,expand=expand,import=import,dugProtection=protect}
