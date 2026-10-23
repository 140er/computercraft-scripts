local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local S = {
  points = {},
  roomSink = false,
  candidates = {},
  box = nil,
  rev = 0,
  views = {},
  message = nil,
  wired = false,
  cap = 64,
  strikes = 3,
  kinds = { fuel = true, ore = true, junk = true, wood = true, storage = true, any = true },
  kindOrder = { "fuel", "ore", "junk", "wood", "storage", "any" },
  face = {
    front = { "inspect", "drop" },
    down = { "inspectDown", "dropDown" },
  },
  draft = { dim = 0, x = 0, y = 64, z = 0, side = "front", kind = "ore" },
  nudge = {
    ["dim+"] = { "dim", 1 }, ["dim-"] = { "dim", -1 },
    ["x+"] = { "x", 1 }, ["x-"] = { "x", -1 },
    ["y+"] = { "y", 1 }, ["y-"] = { "y", -1 },
    ["z+"] = { "z", 1 }, ["z-"] = { "z", -1 },
  },
  errText = {
    full = "64 points",
    bad = "bad field",
    kind = "bad kind",
    side = "bad side",
    exists = "id exists",
    missing = "missing point",
  },
}

S.whole = function(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n == math.floor(n)
end

S.recordOk = function(p)
  if type(p) ~= "table" then return false end
  local keys = 0
  for key in pairs(p) do
    keys = keys + 1
    if key ~= "id" and key ~= "dim" and key ~= "x" and key ~= "y" and key ~= "z"
      and key ~= "side" and key ~= "kind" and key ~= "fails" and key ~= "verified" and key ~= "room" then
      return false
    end
  end
  if keys ~= 8+(p.verified and 1 or 0)+(p.room ~= nil and 1 or 0) then return false end
  if p.verified then
    if type(p.verified) ~= "table" or not S.whole(p.verified.at) or p.verified.at<0
      or type(p.verified.block) ~= "string" or #p.verified.block > 256 then return false end
    for key in pairs(p.verified) do if key ~= "at" and key ~= "block" then return false end end
  end
  if p.room ~= nil and (type(p.room) ~= "boolean" or p.room and p.kind ~= "ore" and p.kind ~= "wood") then return false end
  if type(p.id) ~= "string" or not p.id:match("^[%w_%-]+$") then return false end
  if not S.whole(p.dim) or not S.whole(p.x) or not S.whole(p.y) or not S.whole(p.z) then return false end
  if not S.face[p.side] or not S.kinds[p.kind] then return false end
  if not S.whole(p.fails) or p.fails < 0 or p.fails > S.strikes then return false end
  return true
end

S.valid = function(value)
  if type(value) ~= "table" or type(value.points) ~= "table" then return false end
  for key in pairs(value) do
    if key ~= "points" and key ~= "roomSink" then return false end
  end
  if value.roomSink ~= nil and type(value.roomSink) ~= "boolean" then return false end
  local points = value.points
  local n = #points
  if n > S.cap then return false end
  local seen = {}
  local count = 0
  for key in pairs(points) do
    count = count + 1
    if not S.whole(key) or key < 1 or key > n then return false end
  end
  if count ~= n then return false end
  for i = 1, n do
    local row = points[i]
    if not S.recordOk(row) or seen[row.id] then return false end
    seen[row.id] = true
  end
  return true
end

S.clone = function(list)
  local out = {}
  for i = 1, #list do
    local p = list[i]
    out[i] = {
      id = p.id, dim = p.dim, x = p.x, y = p.y, z = p.z,
      side = p.side, kind = p.kind, fails = p.fails, room = p.room or nil, verified = SO.store.copy(p.verified),
    }
  end
  return out
end

S.pub = function(p)
  return { id = p.id, dim = p.dim, x = p.x, y = p.y, z = p.z, side = p.side, kind = p.kind, room = p.room or nil, verified = SO.store.copy(p.verified), disabled = p.room and not S.roomSink or nil }
end

S.find = function(id)
  for i = 1, #S.points do
    if S.points[i].id == id then return i end
  end
end

S.same = function(p, point)
  return p.dim == point.dim and p.x == point.x and p.y == point.y and p.z == point.z
    and p.side == point.side and p.kind == point.kind and (p.room or false) == (point.room or false)
end

S.emit = function(key, value)
  local state = SO.mods.state
  if type(state) ~= "table" or type(state.emit) ~= "function" then return end
  state.emit(key, value)
end

S.commit = function(previous, op, id)
  local ok, err = S.box.save({ points = S.clone(S.points), roomSink = S.roomSink or nil })
  if not ok then
    S.points = previous
    return false, err
  end
  S.rev = S.rev + 1
  S.emit("drops", { op = op, id = id })
  return true
end

S.add = function(point)
  if type(point) ~= "table" or type(point.id) ~= "string" or not point.id:match("^[%w_%-]+$") then
    return false, "bad"
  end
  if not S.whole(point.dim) or not S.whole(point.x) or not S.whole(point.y) or not S.whole(point.z) then
    return false, "bad"
  end
  if not S.kinds[point.kind] then return false, "kind" end
  if not S.face[point.side] then return false, "side" end
  if point.room ~= nil and (type(point.room) ~= "boolean" or point.room and point.kind ~= "ore" and point.kind ~= "wood") then return false,"kind" end
  local idx = S.find(point.id)
  if idx then
    if S.same(S.points[idx], point) then return true end
    return false, "exists"
  end
  if #S.points >= S.cap then return false, "full" end
  local previous = S.clone(S.points)
  S.points[#S.points + 1] = {
    id = point.id, dim = point.dim, x = point.x, y = point.y, z = point.z,
    side = point.side, kind = point.kind, fails = 0, room = point.room or nil,
  }
  return S.commit(previous, "add", point.id)
end

S.setRoomSink = function(on)
  if type(on) ~= "boolean" then return false,"bad" end
  local previous = S.roomSink
  S.roomSink = on
  local ok, err = S.commit(S.clone(S.points),"roomSink")
  if not ok then S.roomSink = previous end
  return ok, err
end

S.roomMark = function(id, on)
  local idx = S.find(id)
  if not idx then return false,"missing" end
  if type(on) ~= "boolean" then return false,"bad" end
  if on and S.points[idx].kind ~= "ore" and S.points[idx].kind ~= "wood" then return false,"kind" end
  local previous = S.clone(S.points)
  S.points[idx].room = on or nil
  return S.commit(previous,"room",id)
end

S.remove = function(id)
  local idx = S.find(id)
  if not idx then return true end
  local previous = S.clone(S.points)
  table.remove(S.points, idx)
  return S.commit(previous, "remove", id)
end

S.fix = function(id)
  local idx = S.find(id)
  if not idx then return false, "missing" end
  if S.points[idx].fails == 0 then return true end
  local previous = S.clone(S.points)
  S.points[idx].fails = 0
  return S.commit(previous, "fix", id)
end

S.note = function(id, blockName)
  local idx = S.find(id)
  if not idx then return false, "missing" end
  local fails = S.points[idx].fails
  if fails >= S.strikes then return true end
  local nextFails
  if blockName == nil then
    nextFails = fails + 1
  elseif type(blockName) == "string" and blockName ~= "" then
    if fails == 0 then return true end
    nextFails = 0
  else
    return false, "bad"
  end
  local previous = S.clone(S.points)
  if blockName == nil then S.points[idx].verified = nil end
  S.points[idx].fails = nextFails
  return S.commit(previous, "note", id)
end

S.scan = function(kind, nearPos)
  local want, wantDist, wantId
  local anyPoint, anyDist, anyId
  local broken, brokenDist
  for i = 1, #S.points do
    local p = S.points[i]
    if (not p.room or S.roomSink) and p.dim == nearPos.dim and (p.kind == kind or p.kind == "any") then
      local dx = p.x - nearPos.x
      local dy = p.y - nearPos.y
      local dz = p.z - nearPos.z
      local dist = dx * dx + dy * dy + dz * dz
      if p.fails >= S.strikes then
        if not broken or dist < brokenDist or dist == brokenDist and p.id < broken.id then broken, brokenDist = p, dist end
      else
        if p.kind == kind and (not want or dist < wantDist or (dist == wantDist and p.id < wantId)) then
          want, wantDist, wantId = p, dist, p.id
        end
        if p.kind == "any" and (not anyPoint or dist < anyDist or (dist == anyDist and p.id < anyId)) then
          anyPoint, anyDist, anyId = p, dist, p.id
        end
      end
    end
  end
  return want, anyPoint, broken
end

S.pick = function(kind, nearPos)
  if type(kind) ~= "string" or not S.kinds[kind] then return nil end
  if type(nearPos) ~= "table" or not S.whole(nearPos.dim) or not S.whole(nearPos.x)
    or not S.whole(nearPos.y) or not S.whole(nearPos.z) then
    return nil
  end
  local want, anyPoint, broken = S.scan(kind, nearPos)
  local chain = { { kind = kind, point = want and S.pub(want) or nil, usable = want ~= nil } }
  if kind ~= "any" then
    chain[2] = { kind = "any", point = anyPoint and S.pub(anyPoint) or nil, usable = anyPoint ~= nil }
  end
  chain[#chain + 1] = "hold"
  local point
  for i = 1, #chain - 1 do
    if chain[i].usable then
      point = chain[i].point
      break
    end
  end
  local alert, reason, failedPoint
  if not point then
    reason, failedPoint = broken and "broken" or "none", broken and S.pub(broken) or nil
    alert = broken and (kind .. " #" .. broken.id .. " broken at " .. broken.x .. "," .. broken.y .. "," .. broken.z)
      or ("no " .. kind .. " chest set")
    S.emit("drops.alert", { kind = kind, text = alert, reason = reason, point = failedPoint })
  end
  return { point = point, chain = chain, alert = alert, reason = reason, failedPoint = failedPoint }
end

S.steps = function(point)
  if type(point) ~= "table" or type(point.id) ~= "string" then return {} end
  local ops = S.face[point.side]
  if not ops then return {} end
  return { { op = ops[1] }, { op = ops[2] } }
end

S.replyErr = function(reply, code)
  local text = S.errText[code]
  if text then
    reply("err", { code = code, text = text })
    return
  end
  reply("err", { code = "store", text = tostring(code) })
end

S.onEdit = function(msg, reply)
  local body = type(msg) == "table" and msg.body or nil
  if type(body) ~= "table" or type(body.op) ~= "string" then
    S.replyErr(reply, "bad")
    return
  end
  local ok, err
  if body.op == "add" then
    ok, err = S.add(body)
  elseif body.op == "remove" or body.op == "fix" then
    if type(body.id) ~= "string" then
      S.replyErr(reply, "bad")
      return
    end
    if body.op == "remove" then ok, err = S.remove(body.id) else ok, err = S.fix(body.id) end
  else
    S.replyErr(reply, "bad")
    return
  end
  if ok then
    reply("ack", { ok = true, id = body.id })
    return
  end
  S.replyErr(reply, err)
end

S.inventory = function(result)
  return result and result.ok and type(result.data) == "table" and type(result.data.name) == "string"
    and (result.data.name:find("chest",1,true) or result.data.name:find("barrel",1,true)
      or result.data.name:find("shulker_box",1,true)) ~= nil
end

S.verify = function(id, result)
  local idx = S.find(id)
  if not idx then return false, "missing" end
  if S.points[idx].fails >= S.strikes then return false, "fix broken point first" end
  local previous = S.clone(S.points)
  if not result or not result.ok and result.err ~= "No block to inspect" then
    return false,"inspection failed; test again"
  end
  local block = result.ok and result.data and result.data.name or "minecraft:air"
  S.points[idx].verified = S.inventory(result) and {at=SO.now(),block=block} or nil
  if not S.inventory(result) then S.points[idx].fails = math.min(S.strikes,S.points[idx].fails+1) end
  S.message = S.inventory(result) and "chest found" or ("no chest: "..tostring(block))
  return S.commit(previous,"verify",id)
end

S.inLane = function(p)
  local mine = SO.mods.mine
  local map = mine and mine.mapView and mine.mapView()
  if not map or not map.homeSet or map.dim ~= p.dim then return false end
  local M = dofile("so-mine-plan.lua")
  return M.inLane({dim=map.dim,home=map.home,bottom=map.bottom,mode=map.mode,
    turtles={{branch=math.max(0,(map.branches or 0)-1)}}},p)
end

S.freeTurtle = function(id, facing)
  local lease = SO.mods.lease
  if not lease or not lease.candidates or not lease.world then return nil,"lease unavailable" end
  local found = false
  for _, candidate in ipairs(lease.candidates()) do if candidate == id then found=true end end
  if not found then return nil,"use an unassigned idle turtle" end
  local status=lease.status(id)
  if not status.parkBatch or not status.setupFence then return nil,"update worker for setup safety" end
  local config=SO.store.read("so-server.cfg") or {}
  local pose,err=lease.world(id,config.pos and config.pos.dim)
  if not pose then return nil,err end
  if pose.facing == nil then pose.facing=facing end
  if pose.facing == nil then return nil,"choose facing" end
  if not status.pose then return nil,"journal pose unavailable" end
  return pose
end

S.setupSend = function()
  local task=S.task
  local step=task.steps[task.next]
  if not step then
    local ok,err=SO.mods.cells.releaseOwner(task.owner)
    S.message=ok == false and tostring(err) or task.message or "scan complete"
    if ok ~= false then S.task=nil end
    return
  end
  step.park=true
  local lid,err=SO.mods.lease.send(task.id,{step},{owner="setup",ms=15000,journal=SO.mods.lease.status(task.id).journal,pose=dofile("so-plan.lua").apply(task.pose,step.op)})
  if lid then task.lease=lid else S.message=tostring(err) task.failed=true end
end

S.setupReport = function(lid,id,results,lease)
  if S.releasing and S.releasing.lease==lid and S.releasing.id==id then
    local pending=S.releasing
    S.releasing=nil
    local result=results and results[1]
    local fix=result and result.ok and result.data
    local facts=lease.report
    if not fix or not facts or facts.uncertain or not facts.pose or facts.journal==pending.journal
      or fix.dim ~= pending.dim or not S.whole(fix.x) or not S.whole(fix.y) or not S.whole(fix.z) then
      S.message="release unconfirmed; reservations held" return
    end
    S.finishRelease(id,{dim=fix.dim,x=fix.x,y=fix.y,z=fix.z})
    return
  end
  local task=S.task
  if not task or task.lease ~= lid or task.id ~= id then return end
  task.lease=nil
  local P=dofile("so-plan.lua")
  local facts=lease.report
  if not results or not facts or not facts.pose or facts.uncertain then
    task.failed=true S.message="setup pose unknown; reservations held" return
  end
  local step=task.steps[task.next]
  local result=results[1]
  local actual=P.toWorld(task.frame,facts.pose)
  local expected=P.apply(task.pose,step.op)
  if actual.x ~= expected.x or actual.y ~= expected.y or actual.z ~= expected.z or actual.facing ~= expected.facing
    or not result.ok and step.op ~= "inspect" and step.op ~= "inspectUp" and step.op ~= "inspectDown" then
    task.failed=true S.message="setup blocked; reservations held" return
  end
  task.pose=actual
  if step.scan and S.inventory(result) then
    local p=SO.store.copy(step.scan)
    p.block=result.data.name
    S.candidates[#S.candidates+1]=p
  end
  if step.verify then
    local idx=S.find(step.verify)
    if idx and S.same(S.points[idx],task.point) then
      local ok,err=S.verify(step.verify,result)
      task.message=ok and S.message or tostring(err)
    else task.message="point changed; test again" end
  end
  task.next=task.next+1
  S.setupSend()
end

S.beginSetup = function(id, point, facing)
  if S.task or S.releasing then S.message="setup busy" return end
  local config=SO.store.read("so-server.cfg") or {}
  if config.setupMovement ~= true then S.message="setup movement disabled" return end
  local pose,err=S.freeTurtle(id, facing)
  if not pose then
    if err=="choose facing" then S.compass={id=id,point=point} S.testing=true end
    S.message=err return
  end
  S.compass=nil
  local P=dofile("so-plan.lua")
  local dim=({["minecraft:overworld"]=0,["minecraft:the_nether"]=-1,["minecraft:the_end"]=1})[pose.dim]
  if not dim then S.message="unknown dimension" return end
  local steps={}
  if point then
    if point.dim ~= dim or point.fails >= S.strikes then S.message="fix point or dimension first" return end
    local distance=math.abs(point.x-pose.x)+math.abs(point.y-pose.y)+math.abs(point.z-pose.z)
    if distance>64 then S.message="test route exceeds 64 blocks" return end
    local goals={}
    if point.side == "down" then goals[1]={dim=pose.dim,x=point.x,y=point.y+1,z=point.z}
    else
      for f=0,3 do goals[#goals+1]={dim=pose.dim,x=point.x-({[0]=0,1,0,-1})[f],y=point.y,
        z=point.z-({[0]=-1,0,1,0})[f],facing=f} end
    end
    table.sort(goals,function(a,b)
      local function dist(p) return math.abs(p.x-pose.x)+math.abs(p.y-pose.y)+math.abs(p.z-pose.z) end
      return dist(a)<dist(b)
    end)
    local chosen
    for _,goal in ipairs(goals) do
      local path=P.path(pose,goal)
      local safe=true
      for _,cell in ipairs(path.cells) do
        local held=SO.mods.cells.owner(cell.x,cell.y,cell.z,cell.dim)
        if held or S.inLane(cell) or cell.x==point.x and cell.y==point.y and cell.z==point.z then safe=false break end
      end
      if safe then chosen=goal steps=path.steps break end
    end
    if not chosen then S.message="no free test route" return end
    local at=SO.store.copy(pose)
    for _,step in ipairs(steps) do at=P.apply(at,step.op) end
    while chosen.facing ~= nil and at.facing ~= chosen.facing do
      steps[#steps+1]={op="turnRight"} at=P.apply(at,"turnRight")
    end
    local outward=#steps
    steps[#steps+1]={op=point.side=="down" and "inspectDown" or "inspect",verify=point.id}
    local inverse={forward="back",back="forward",up="down",down="up",turnLeft="turnRight",turnRight="turnLeft"}
    for i=outward,1,-1 do steps[#steps+1]={op=inverse[steps[i].op]} end
  else
    S.candidates={}
    local function scan(op,p)
      p.dim=dim
      steps[#steps+1]={op=op,scan=p}
    end
    scan("inspectUp",{x=pose.x,y=pose.y+1,z=pose.z,side="down"})
    scan("inspectDown",{x=pose.x,y=pose.y-1,z=pose.z,side="down"})
    local at=SO.store.copy(pose)
    for _=1,4 do
      local x,y,z=P.ahead(at,"forward")
      scan("inspect",{x=x,y=y,z=z,side="front"})
      steps[#steps+1]={op="turnRight"} at=P.apply(at,"turnRight")
    end
  end
  local cells,at={pose},pose
  for _,step in ipairs(steps) do at=P.apply(at,step.op) cells[#cells+1]=at end
  if not P.inRange(SO.mods.lease,id,cells) then S.message="test route out of range" return end
  for _,cell in ipairs(cells) do if S.inLane(cell) then S.message="mining lane" return end end
  local owner="setup:"..id
  local claimed,claimErr=SO.mods.lease.claimProbe(id,owner,pose)
  if claimed==false then S.message=claimErr return end
  local ok,why=SO.mods.cells.reserveMany(owner,cells)
  if not ok then S.message=why return end
  S.task={id=id,owner=owner,steps=steps,next=1,pose=pose,point=point and SO.store.copy(point),
    frame=P.frame(pose,SO.mods.lease.status(id).pose)}
  S.message=point and "testing chest" or "scanning"
  S.setupSend()
end

S.testPoint = function(id)
  local idx=S.find(id)
  if not idx then S.message="missing point" return end
  local lease=SO.mods.lease
  for _,turtleId in ipairs(lease and lease.candidates and lease.candidates() or {}) do
    local pose,err=S.freeTurtle(turtleId)
    if pose or err=="choose facing" then S.beginSetup(turtleId,S.points[idx]) return end
  end
  S.message="no idle turtle with known facing"
end

S.finishRelease = function(id,pose)
  local cells=SO.mods.cells
  local owner="setup:"..id
  local held=cells.owner(pose.x,pose.y,pose.z,pose.dim)
  local ok,why
  if held==owner then ok,why=cells.handoff(owner,"gps:"..id,pose.x,pose.y,pose.z,pose.dim)
  else ok,why=cells.reserve("gps:"..id,pose.x,pose.y,pose.z,pose.dim) end
  if not ok then S.message=why return end
  ok,why=cells.releaseOwner(owner)
  if ok == false then S.message=why return end
  S.task=nil S.message="setup released"
end

S.releaseSetup = function(id)
  local lease=SO.mods.lease
  if S.releasing or S.task and (S.task.id ~= id or S.task.lease) then S.message="setup busy" return end
  local config=SO.store.read("so-server.cfg") or {}
  local pose,err=lease.world(id,config.pos and config.pos.dim)
  if not pose then S.message=err return end
  local status=lease.status(id)
  if not status.setupFence or not status.journal then S.message="update worker for setup safety" return end
  local lid,why=lease.send(id,{{op="gps",park=true}},{owner="setup",ms=15000,journal=status.journal})
  if not lid then S.message=why return end
  S.releasing={id=id,lease=lid,journal=status.journal,dim=pose.dim}
  S.message="confirming release"
end

S.row = function(text)
  return { text = text, fg = "0", bg = "f" }
end

S.button = function(id, x, y, label)
  return { id = id, x = x, y = y, w = #label, label = label }
end

S.view = function(id)
  id = id or 0
  if not S.views[id] then S.views[id] = { page = 1, pages = 1 } end
  return S.views[id]
end

S.legacyRender = function(w, h, clientId)
  w, h = w or 26, h or 9
  local rows = { S.row("drops") }
  local buttons = {}
  local view = S.view(clientId)
  local count = math.max(1, math.floor((h - 7) / 2))
  view.pages = math.max(1, math.ceil(#S.points / count))
  view.page = math.min(view.page, view.pages)
  local first = (view.page - 1) * count + 1
  for i = first, math.min(#S.points, first + count - 1) do
    local p = S.points[i]
    local detail = " " .. p.kind .. " " .. p.side .. (p.fails >= S.strikes and " broken" or "")
    rows[#rows + 1] = S.row(p.id:sub(1, math.max(1, w - #detail)) .. detail)
    rows[#rows + 1] = S.row("")
    buttons[#buttons + 1] = S.button("fix:" .. p.id, 1, #rows, "fix")
    buttons[#buttons + 1] = S.button("remove:" .. p.id, 6, #rows, "remove")
  end
  rows[#rows + 1] = S.row("          " .. view.page .. "/" .. view.pages)
  buttons[#buttons + 1] = S.button("prev", 1, #rows, "prev")
  buttons[#buttons + 1] = S.button("next", 6, #rows, "next")
  local d = S.draft
  rows[#rows + 1] = S.row(string.format("draft %s %s dim %d", d.kind, d.side, d.dim))
  rows[#rows + 1] = S.row(string.format("%d %d %d", d.x, d.y, d.z))
  for _, names in ipairs({ { "kind", "side", "add", "dim+", "dim-" },
      { "x+", "x-", "y+", "y-", "z+", "z-" } }) do
    rows[#rows + 1] = S.row("")
    local x = 1
    for _, label in ipairs(names) do
      buttons[#buttons + 1] = S.button(label, x, #rows, label)
      x = x + #label + 1
    end
  end
  rows[#rows + 1] = S.row(S.message)
  return { rev = S.rev, rows = rows, buttons = buttons }
end

S.addDraft = function()
  local d = S.draft
  local ok, err = S.add({
    id = string.format("%d_%d_%d_%d_%s_%s", d.dim, d.x, d.y, d.z, d.side, d.kind),
    dim = d.dim, x = d.x, y = d.y, z = d.z, side = d.side, kind = d.kind, room = d.room,
  })
  S.message = ok and "point added" or (S.errText[err] or tostring(err))
end

S.typed = function(text)
  local scan=text:match("^scan%s+(%d+)$")
  if scan then S.beginSetup(tonumber(scan)) return end
  local visit=text:match("^test%s+([%w_%-]+)$")
  if visit then S.testPoint(visit) return end
  local release=text:match("^release%s+(%d+)$")
  if release then S.releaseSetup(tonumber(release)) return end
  local words = {}
  for word in text:gmatch("%S+") do words[#words + 1] = word end
  if words[1] == "room" then
    if #words ~= 3 or words[3] ~= "on" and words[3] ~= "off" then S.message = "invalid room command" return end
    local ok, err
    if words[2] == "sink" then ok,err = S.setRoomSink(words[3] == "on")
    else ok,err = S.roomMark(words[2],words[3] == "on") end
    S.message = ok and "room saved" or (S.errText[err] or tostring(err))
    return
  end
  local d = S.draft
  local dim, kind, side = d.dim, d.kind, d.side
  local x, y, z
  local direct = words[1] == "add"
  if direct then
    if #words < 5 or #words > 7 then S.message = "add kind x y z [side/dim]" return end
    kind = words[2]
    if not S.kinds[kind] then S.message = "bad kind" return end
    x, y, z = tonumber(words[3]), tonumber(words[4]), tonumber(words[5])
    if words[6] then
      if S.face[words[6]] then
        side = words[6]
        if words[7] then dim = tonumber(words[7]) end
      elseif #words == 6 then
        dim = tonumber(words[6])
      else
        S.message = "bad side" return
      end
    end
  elseif #words == 3 then
    x, y, z = tonumber(words[1]), tonumber(words[2]), tonumber(words[3])
  elseif #words == 4 then
    dim, x, y, z = tonumber(words[1]), tonumber(words[2]), tonumber(words[3]), tonumber(words[4])
  else
    S.message = "use x y z or dim x y z" return
  end
  if not S.whole(dim) or not S.whole(x) or not S.whole(y) or not S.whole(z) then
    S.message = "dim/x/y/z: integers only" return
  end
  S.draft = { dim = dim, x = x, y = y, z = z, kind = kind, side = side, room = d.room }
  S.message = "draft ready"
  if direct then S.addDraft() end
end

S.selectedPoint = function()
  if S.selected and S.find(S.selected) then return S.selected end
  for _, p in ipairs(S.points) do if p.fails >= S.strikes then return p.id end end
  return S.points[1] and S.points[1].id
end

S.fromTurtle = function(id)
  S.fromError = true
  local lease = SO.mods.lease
  local config = SO.store.read("so-server.cfg")
  local dim = config and config.pos and config.pos.dim
  local number = ({["minecraft:overworld"]=0,["minecraft:the_nether"]=-1,["minecraft:the_end"]=1})[dim]
  if not number or not lease or not lease.world then S.message = "turtle world pose unavailable" return end
  local p, err = lease.world(id, dim)
  if not p then S.message = err return end
  local x, y, z = p.x, p.y, p.z
  if S.draft.side == "down" then y = y-1
  elseif p.facing == nil then S.message = "facing unknown; add turtle first" return
  else x, z = x+({[0]=0,1,0,-1})[p.facing], z+({[0]=-1,0,1,0})[p.facing] end
  S.draft.x, S.draft.y, S.draft.z, S.draft.dim = x, y, z, number
  S.message, S.fromError = nil, nil
end

S.gather = function(view)
  local turtles = {}
  local state = SO.mods.state
  local machines = state and type(state.get) == "function" and state.get("machines") or {}
  for id, row in pairs(machines) do
    if (row.role == "turtle" or row.role == "worker") and SO.pair.key(tonumber(id)) then turtles[#turtles+1] = tonumber(id) end
  end
  if SO.mods.lease and SO.mods.lease.candidates then turtles=SO.mods.lease.candidates() end
  table.sort(turtles)
  return { setupActions = true, compass = S.compass, testing = S.testing, candidates = S.candidates, points = S.clone(S.points), selected = S.selectedPoint(), draft = SO.store.copy(S.draft),
    fromError = S.fromError, turtles = turtles, fromPage = view and view.fromPage or 0, editing = S.editing, roomSink = S.roomSink, message = S.message, page = view and view.page or 1 }
end

S.listSize = function(count, w, h)
  local compact = w < 39 or h < 16
  local navColumns = w < 26 and 2 or w < 41 and 3 or 6
  local navRows = math.ceil(6/navColumns)
  local actionY = compact and h-navRows-1 or math.min(math.max(11, count+6), h-navRows*3-3)
  local capacity = math.max(1, actionY-5)
  return { compact = compact, actionY = actionY, capacity = capacity, navColumns = navColumns, navRows = navRows,
    pages = math.max(1, math.ceil(count/capacity)) }
end

S.layout = function(model, w, h)
  local C = U.canvas(w, h)
  if model.testing then
    C.header("CHEST SETUP", "")
    if model.compass then
      C.header("FACING #"..model.compass.id, "")
      local cols=U.grid(w,h,4)
      for i,label in ipairs({"N","E","S","W"}) do
        C.button(cols[i].x,5,cols[i].w,label,"facing:"..(i-1),"9",1)
      end
      C.button(1,h,w,"BACK","list","7",1)
      return C.frame()
    end
    if model.message then C.alert(model.message) end
    for _,p in ipairs(model.points) do
      if p.id==model.selected then C.put(1,2,(p.x..","..p.y..","..p.z):sub(1,w)) end
    end
    C.button(1,4,w,"TEST #"..tostring(model.selected or "-"),"test","9",1)
    local cols=U.grid(w,h,2)
    C.button(cols[1].x,h-2,cols[1].w,"FIX","fix","9",1)
    C.button(cols[2].x,h-2,cols[2].w,"RELEASE","release","7",1)
    local count=math.max(1,h-8)
    local pages=math.max(1,math.ceil((#model.turtles+#model.candidates)/count))
    local first=((model.fromPage or 0)%pages)*count+1
    for i=first,math.min(#model.turtles+#model.candidates,first+count-1) do
      local y=5+i-first
      local id=model.turtles[i]
      if id then C.button(1,y,w,"SCAN #"..id,"scan:"..id,"9",1)
      else
        local n=i-#model.turtles
        local p=model.candidates[n]
        C.button(1,y,w,p.x..","..p.y..","..p.z,"candidate:"..n,"7",1)
      end
    end
    C.button(1,h-1,w,"NEXT","from-next","7",1)
    C.button(1,h,w,"BACK","list","7",1)
    return C.frame()
  end
  if model.editing then
    C.header("ADD DROP POINT", "")
    if model.fromError then C.alert(model.message) end
    local d = model.draft
    local cols = U.grid(w, h, 2)
    for i, field in ipairs({"kind", "side"}) do
      C.button(cols[i].x, 4, cols[i].w, tostring(d[field]), field, '7', 1)
    end
    for i, field in ipairs({"dim", "x", "y", "z"}) do
      local y = i + 4
      C.put(2, y, (field .. " " .. tostring(d[field])):sub(1,math.max(0,w-2)))
      C.button(w-5, y, 3, "-", field.."-", '7', 1)
      C.button(w-2, y, 3, "+", field.."+", '7', 1)
    end
    local start = h >= 12 and 10 or 9
    if h >= 12 then
      C.button(cols[1].x,9,cols[1].w,"ROOM "..(d.room and "ON" or "OFF"),"room-point","7",1)
      C.button(cols[2].x,9,cols[2].w,"SINKS "..(model.roomSink and "ON" or "OFF"),"room-sink","7",1)
    end
    local count = math.max(1, h-start-2)
    local pages = math.max(1, math.ceil(#model.turtles/count))
    local first = ((model.fromPage or 0)%pages)*count+1
    for i = first, math.min(#model.turtles,first+count-1) do
      local id, y = model.turtles[i], start+i-first
      local width = pages > 1 and y == h-2 and cols[1].w or w
      C.button(1,y,width,"FROM #"..id,"from:"..id,"9",1)
    end
    if pages > 1 then
      local shared = start+count-1 == h-2
      C.button(shared and cols[2].x or 1,h-2,shared and cols[2].w or w,"NEXT","from-next","7",1)
    end
    C.put(2, h-1, (model.message or ""):sub(1,math.max(0,w-2)))
    C.button(1, h, cols[1].w, "ADD", "add", '9', 1)
    C.button(cols[2].x, h, cols[2].w, "BACK", "list", '7', 1)
    return C.frame()
  end
  C.header("DROP POINTS", #model.points .. " points")
  if model.message then C.alert(model.message) end
  if not model.message then C.fill(1, 3, w, 1, '7'); C.put(2, 3, "ID  KIND     WHERE          SIDE   STATE") end
  local size = S.listSize(#model.points, w, h)
  local compact, actionY, capacity, pages = size.compact, size.actionY, size.capacity, size.pages
  local navHeight = compact and 1 or 3
  local page = math.min(model.page or 1, pages)
  local first = (page-1)*capacity+1
  local selectedRow
  for i,p in ipairs(model.points) do if p.id == model.selected then selectedRow=i end end
  for i=first,math.min(#model.points,first+capacity-1) do
    local p = model.points[i]
    local text = string.format("%-3d%-9s%-15s%-7s%s", i, p.kind,
      string.format("%2d,%d,%d",p.x,p.y,p.z), p.side, p.fails >= 3 and 'broken' or p.room and (model.roomSink and 'room' or 'off') or 'ok')
    if compact then text=i.." "..p.kind.." "..p.x..","..p.y..","..p.z.." "..(p.fails>=3 and "!" or p.verified and "V" or "?") end
    C.listRow(i-first+4, text, p.fails >= 3 and 'e' or 'd')
    C.hit('select:'..p.id, 1, i-first+4, w, 1)
  end
  if model.setupActions then C.button(w-7,2,8,"TEST","testing","9",1) end
  if pages > 1 then
    C.button(1, actionY-1, math.floor(w/2), "PREV", "prev", '7', 1)
    C.button(math.floor(w/2)+1, actionY-1, w-math.floor(w/2), "NEXT", "next", '7', 1)
  end
  local actions = {{'FIX #'..(selectedRow or '-'),'fix','9'},{'REMOVE','remove'},{'ADD NEW','new'},{'BACK','status'}}
  local cols = U.grid(w,h,compact and 2 or 4)
  if w==57 and not compact then cols={{x=1,w=13},{x=15,w=13},{x=29,w=14},{x=44,w=14}} end
  for i,b in ipairs(actions) do
    local col = cols[(i-1)%#cols+1]
    C.button(col.x, actionY+(compact and math.floor((i-1)/2) or 0), col.w, b[1], b[2], b[3], navHeight)
  end
  local nav = {'mining', 'lumber', 'shop', 'ar', 'panel', 'build'}
  local navCols = U.grid(w, h, size.navColumns)
  for i, id in ipairs(nav) do
    local col = navCols[(i-1)%#navCols+1]
    local y = h-size.navRows*navHeight+1+math.floor((i-1)/#navCols)*navHeight
    C.button(col.x, y, col.w, id:upper(), id, id == 'shop' and 'a' or '7', navHeight)
  end
  return C.frame()
end

S.render = function(w, h, session)
  if not U then return S.legacyRender(w, h, session) end
  w, h = w or 57, h or 24
  local view = S.view(type(session) == "table" and session.id or session)
  local model = S.gather(view)
  local size = S.listSize(#model.points, w, h)
  if view.focus then
    for i,p in ipairs(model.points) do if p.id==view.focus then model.page=math.floor((i-1)/size.capacity)+1 end end
    view.focus=nil
  end
  model.page = math.min(model.page, size.pages)
  view.page = model.page
  local frame = S.layout(model, w, h)
  frame.rev = S.rev
  return frame
end

S.input = function(ev)
  if type(ev) ~= "table" then return end
  if type(ev.text) == "string" then S.typed(ev.text); if U then S.editing = true end; return end
  if type(ev.id) ~= "string" then return end
  if ev.id == "mining" or ev.id == "lumber" or ev.id == "shop" or ev.id == "ar" or ev.id == "panel" then
    S.editing = false return
  end
  if ev.id == "room-sink" then
    local ok,err = S.setRoomSink(not S.roomSink)
    S.message = ok and "room saved" or tostring(err)
    return
  end
  if ev.id == "room-point" then
    if S.draft.kind == "ore" or S.draft.kind == "wood" then S.draft.room = not S.draft.room or nil
    else S.message = "room needs ore or wood" end
    return
  end
  if ev.id == "new" then S.editing = true return end
  if ev.id == "list" then S.editing, S.testing = false, false return end
  local facing=tonumber(ev.id:match("^facing:([0-3])$"))
  if facing and S.compass then local pick=S.compass S.beginSetup(pick.id,pick.point,facing) return end
  if ev.id == "testing" then S.testing=true return end
  if ev.id == "test" then local id=S.selectedPoint(); if id then S.testPoint(id) end return end
  if ev.id == "release" and S.task then S.releaseSetup(S.task.id) return end
  local scan=ev.id:match("^scan:(%d+)$")
  if scan then S.beginSetup(tonumber(scan)) return end
  local candidate=tonumber(ev.id:match("^candidate:(%d+)$"))
  if candidate and S.candidates[candidate] then
    local p=S.candidates[candidate]
    S.draft={dim=p.dim,x=p.x,y=p.y,z=p.z,side=p.side,kind="ore"}
    S.testing,S.editing=false,true return
  end
  if not U and (ev.id == "prev" or ev.id == "next") then
    local view = S.view(ev.from)
    view.page = math.max(1, math.min(view.pages, view.page + (ev.id == "next" and 1 or -1)))
    return
  end
  local view = S.view(ev.from or (ev.session and ev.session.id))
  if ev.id == "next" then view.page = view.page + 1 return end
  if ev.id == "prev" then view.page = math.max(1, view.page-1) return end
  if ev.id == "from-next" then view.fromPage = (view.fromPage or 0)+1 return end
  local from = ev.id:match("^from:(%d+)$")
  if from then S.fromTurtle(tonumber(from)) return end
  local focused = ev.id:match("^focus:(.+)$")
  if focused and S.find(focused) then
    S.editing=false S.selected=focused view.focus=focused return
  end
  local selected = ev.id:match("^select:(.+)$")
  if selected and S.find(selected) then S.selected = selected return end
  if ev.id == "fix" then local id = S.selectedPoint(); if id then S.selected = id; S.fix(id) end return end
  if ev.id == "remove" then local id = S.selectedPoint(); if id then S.remove(id) end return end
  local fixId = ev.id:match("^fix:(.+)$")
  if fixId then S.fix(fixId) return end
  local removeId = ev.id:match("^remove:(.+)$")
  if removeId then S.remove(removeId) return end
  if ev.id == "kind" then
    local at = 1
    for i = 1, #S.kindOrder do
      if S.kindOrder[i] == S.draft.kind then at = i end
    end
    S.draft.kind = S.kindOrder[at % #S.kindOrder + 1]
    if S.draft.kind ~= "ore" and S.draft.kind ~= "wood" then S.draft.room = nil end
    return
  end
  if ev.id == "side" then
    if S.draft.side == "front" then S.draft.side = "down" else S.draft.side = "front" end
    return
  end
  if ev.id == "add" then
    S.addDraft()
    return
  end
  local step = S.nudge[ev.id]
  if not step then return end
  S.draft[step[1]] = S.draft[step[1]] + step[2]
end

S.tick = function()
  if not S.callback and SO.mods.lease and SO.mods.lease.onReport then
    SO.mods.lease.onReport("setup",S.setupReport) S.callback=true
  end
  if S.wired then return end
  local display = SO.mods.display
  if type(display) ~= "table" or type(display.screen) ~= "function" then return end
  display.screen("generic", S.render, S.input)
  S.wired = true
end

S.box = SO.store.store("so-drops", S.valid)
if S.box.value and type(S.box.value.points) == "table" then
  S.points = S.clone(S.box.value.points)
  S.roomSink = S.box.value.roomSink == true
end

return {
  name = "drops",
  handlers = { ["drops.edit"] = S.onEdit },
  tick = S.tick,
  list = function()
    local out = {}
    for i, point in ipairs(S.points) do
      out[i] = S.pub(point)
      out[i].broken = point.fails >= S.strikes
    end
    return out
  end,
  pick = S.pick,
  steps = S.steps,
  add = S.add,
  remove = S.remove,
  fix = S.fix,
  note = S.note,
  roomMark = S.roomMark,
  roomSink = S.setRoomSink,
  busy = function(id) return S.task and S.task.id == id or S.releasing and S.releasing.id == id end,
}
