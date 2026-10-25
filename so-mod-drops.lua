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
  -- Each display keeps its own draft; one with no input for idle ms is dropped unsaved.
  blank = { dim = 0, x = 0, y = 64, z = 0, side = "front", kind = "ore" },
  idle = 300000,
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
  dimOf = { ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1, ["minecraft:the_end"] = 1 },
  -- The list's dimension filter, in tap order, with the short label narrow screens use; ALL shows every point.
  filters = { { "ALL", nil, "ALL" }, { "WORLD", 0, "OVW" }, { "NETHER", -1, "NTH" }, { "END", 1, "END" } },
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
      and key ~= "side" and key ~= "kind" and key ~= "fails" and key ~= "verified" and key ~= "room" and key ~= "suspended" then
      return false
    end
  end
  if keys ~= 8+(p.verified and 1 or 0)+(p.room ~= nil and 1 or 0)+(p.suspended ~= nil and 1 or 0) then return false end
  if p.verified then
    if type(p.verified) ~= "table" or not S.whole(p.verified.at) or p.verified.at<0
      or type(p.verified.block) ~= "string" or #p.verified.block > 256 then return false end
    for key in pairs(p.verified) do if key ~= "at" and key ~= "block" then return false end end
  end
  if p.suspended ~= nil and type(p.suspended) ~= "boolean" then return false end
  if p.room ~= nil and (type(p.room) ~= "boolean" or p.room and p.kind ~= "ore" and p.kind ~= "wood") then return false end
  if type(p.id) ~= "string" or not p.id:match("^[%w_%-]+$") then return false end
  if not S.whole(p.dim) or not S.whole(p.x) or not S.whole(p.y) or not S.whole(p.z) then return false end
  if not S.face[p.side] or not S.kinds[p.kind] then return false end
  if not S.whole(p.fails) or p.fails < 0 or p.fails > S.strikes then return false end
  return true
end

S.candidateKey = function(p)
  return string.format("%.0f/%.0f/%.0f/%.0f/%s", p.dim, p.x, p.y, p.z, p.side)
end
S.candidateOk = function(p)
  if type(p) ~= "table" then return false end
  local count = 0
  for key in pairs(p) do
    count = count + 1
    if key ~= "dim" and key ~= "x" and key ~= "y" and key ~= "z" and key ~= "side"
      and key ~= "block" and key ~= "at" then return false end
  end
  return count == 7 and (p.dim == 0 or p.dim == -1 or p.dim == 1)
    and S.whole(p.x) and S.whole(p.y) and S.whole(p.z) and S.face[p.side] ~= nil
    and type(p.block) == "string" and #p.block <= 256 and p.block:match("^[a-z0-9_.%-]+:[a-z0-9_./%-]+$") ~= nil
    and S.whole(p.at) and p.at >= 0
end
S.arrayOk = function(list, valid, keyOf)
  if type(list) ~= "table" or #list > S.cap then return false end
  local count, seen = 0, {}
  for key in pairs(list) do
    count = count + 1
    if not S.whole(key) or key < 1 or key > #list then return false end
  end
  if count ~= #list then return false end
  for _, p in ipairs(list) do
    if not valid(p) then return false end
    local key = keyOf(p)
    if seen[key] then return false end
    seen[key] = true
  end
  return true
end
S.valid = function(value)
  if type(value) ~= "table" or value.v ~= nil and value.v ~= 2 then return false end
  for key in pairs(value) do
    if key ~= "points" and key ~= "roomSink" and not (value.v == 2 and (key == "v" or key == "candidates")) then return false end
  end
  if value.roomSink ~= nil and type(value.roomSink) ~= "boolean" then return false end
  if not S.arrayOk(value.points, S.recordOk, function(p) return p.id end) then return false end
  if value.v == 2 then
    return type(value.roomSink) == "boolean" and S.arrayOk(value.candidates, S.candidateOk, S.candidateKey)
  end
  for _, p in ipairs(value.points) do if p.suspended ~= nil then return false end end
  return true
end

S.clone = function(list)
  local out = {}
  for i = 1, #list do
    local p = list[i]
    out[i] = {
      id = p.id, dim = p.dim, x = p.x, y = p.y, z = p.z,
      side = p.side, kind = p.kind, fails = p.fails, suspended = p.suspended, room = p.room, verified = p.verified and {at=p.verified.at,block=p.verified.block} or nil,
    }
  end
  return out
end

S.pub = function(p)
  return { id = p.id, dim = p.dim, x = p.x, y = p.y, z = p.z, side = p.side, kind = p.kind, room = p.room or nil, verified = p.verified and {at=p.verified.at,block=p.verified.block} or nil, suspended = p.suspended, disabled = (p.suspended or p.room and not S.roomSink) or nil }
end

S.find = function(id)
  for i = 1, #S.points do
    if S.points[i].id == id then return i end
  end
end

S.usable = function(id)
  if S.blocked then return false, "unreadable" end
  local idx = S.find(id)
  local p = idx and S.points[idx]
  if not p then return false, "missing" end
  if p.suspended then return false, "suspended" end
  if p.fails >= S.strikes then return false, "broken" end
  return true
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

S.enabled = function()
  local cfg = type(SO.store.read) == "function" and SO.store.read("so-server.cfg") or {}
  return cfg.dropsSavedSetup == true
end
S.preflight = function()
  if not fs or not fs.exists then return true end
  local newest, rejected = 0, 0
  for _, path in ipairs({"so-drops", "so-drops.tmp", "so-drops.bak"}) do
    if fs.exists(path) then
      local ok, t, bytes = pcall(SO.store.read, path)
      local generation = ok and type(t) == "table" and t.generation
      if not S.whole(generation) or generation < 1 then return false end
      if t.schema == 1 and S.valid(t.value) and (not bytes or #bytes <= 65536) then
        newest = math.max(newest, generation)
      else rejected = math.max(rejected, generation) end
    end
  end
  return rejected == 0 or rejected < newest
end
S.cloneFound = function(list)
  local out = {}
  for i, p in ipairs(list) do
    out[i] = {dim=p.dim, x=p.x, y=p.y, z=p.z, side=p.side, block=p.block, at=p.at}
  end
  return out
end
S.publishFound = function(list)
  S.candidates, S.candidateIndex = S.cloneFound(list), {}
  for i, p in ipairs(S.candidates) do S.candidateIndex[S.candidateKey(p)] = i end
end
S.envelope = function()
  local value = {points = S.clone(S.points), roomSink = S.roomSink or nil}
  if S.data.v == 2 or S.enabled() then
    value.v, value.roomSink = 2, S.roomSink
    value.candidates = S.cloneFound(S.data.candidates or {})
  end
  return value
end
S.commit = function(value, op, id)
  if S.blocked or not S.preflight() then S.blocked = true return false, "drops unreadable" end
  if not S.valid(value) then return false, "invalid state" end
  local ok, err = S.box.save(value)
  if not ok then return false, err end
  S.data, S.points, S.roomSink = value, value.points, value.roomSink == true
  if S.enabled() then S.publishFound(value.candidates or {}) end
  S.rev = S.rev + 1
  S.emit("drops", { op = op, id = id })
  return true
end
S.observe = function(p)
  if S.blocked then return false, "drops unreadable" end
  if not S.candidateOk(p) then return false, "bad candidate" end
  local list = S.cloneFound(S.candidates)
  local at = S.candidateIndex[S.candidateKey(p)] or #list + 1
  if at > S.cap then return false, "64 found" end
  list[at] = {dim=p.dim, x=p.x, y=p.y, z=p.z, side=p.side, block=p.block, at=p.at}
  if not S.enabled() then S.publishFound(list) return true end
  local value = S.envelope()
  value.candidates = list
  return S.commit(value, "found")
end
S.suspend = function(id, on)
  if not S.enabled() then return false, "dropsSavedSetup off" end
  local idx = S.find(id)
  if not idx then return false, "missing" end
  local value = S.envelope()
  value.points[idx].suspended = on
  return S.commit(value, on and "suspend" or "resume", id)
end
S.clearFound = function()
  if not S.enabled() then return false, "dropsSavedSetup off" end
  local value = S.envelope()
  value.candidates = {}
  return S.commit(value, "clear found")
end

S.check = function(point)
  if type(point) ~= "table" then return false, "bad" end
  if not S.whole(point.dim) or not S.whole(point.x) or not S.whole(point.y) or not S.whole(point.z) then
    return false, "bad"
  end
  if not S.kinds[point.kind] then return false, "kind" end
  if not S.face[point.side] then return false, "side" end
  if point.room ~= nil and (type(point.room) ~= "boolean" or point.room and point.kind ~= "ore" and point.kind ~= "wood") then return false,"kind" end
  return true
end

S.add = function(point)
  if S.blocked then return false, "drops unreadable" end
  if type(point) ~= "table" or type(point.id) ~= "string" or not point.id:match("^[%w_%-]+$") then
    return false, "bad"
  end
  local valid, why = S.check(point)
  if not valid then return false, why end
  local idx = S.find(point.id)
  if idx then
    if S.same(S.points[idx], point) then return true end
    return false, "exists"
  end
  if #S.points >= S.cap then return false, "full" end
  local value = S.envelope()
  value.points[#value.points + 1] = {
    id = point.id, dim = point.dim, x = point.x, y = point.y, z = point.z,
    side = point.side, kind = point.kind, fails = 0, room = point.room or nil,
  }
  return S.commit(value, "add", point.id)
end

-- The index of a point other than skip at point's place, side and kind.
S.match = function(point, skip)
  for i, p in ipairs(S.points) do
    if i ~= skip and p.dim == point.dim and p.x == point.x and p.y == point.y and p.z == point.z
      and p.side == point.side and p.kind == point.kind then return i end
  end
end

-- An edit keeps its stable id. Moving a point clears its strikes and verification.
S.edit = function(id, point)
  if S.blocked then return false, "drops unreadable" end
  local idx = S.find(id)
  if not idx then return false, "missing" end
  local valid, why = S.check(point)
  if not valid then return false, why end
  local other = S.match(point, idx)
  if other then return false, "exists" end
  local p = S.points[idx]
  if S.same(p, point) then return true end
  local value = S.envelope()
  p = value.points[idx]
  local moved = p.dim ~= point.dim or p.x ~= point.x or p.y ~= point.y or p.z ~= point.z or p.side ~= point.side
  p.dim, p.x, p.y, p.z, p.side, p.kind, p.room = point.dim, point.x, point.y, point.z, point.side, point.kind, point.room or nil
  if moved then p.fails, p.verified = 0, nil end
  return S.commit(value, "edit", id)
end

S.setRoomSink = function(on)
  if S.blocked then return false, "drops unreadable" end
  if type(on) ~= "boolean" then return false,"bad" end
  local value = S.envelope()
  value.roomSink = on
  return S.commit(value,"roomSink")
end

S.roomMark = function(id, on)
  if S.blocked then return false, "drops unreadable" end
  local idx = S.find(id)
  if not idx then return false,"missing" end
  if type(on) ~= "boolean" then return false,"bad" end
  if on and S.points[idx].kind ~= "ore" and S.points[idx].kind ~= "wood" then return false,"kind" end
  local value = S.envelope()
  value.points[idx].room = on or nil
  return S.commit(value,"room",id)
end

S.remove = function(id)
  if S.blocked then return false, "drops unreadable" end
  local idx = S.find(id)
  if not idx then return true end
  local value = S.envelope()
  table.remove(value.points, idx)
  return S.commit(value, "remove", id)
end

S.fix = function(id)
  if S.blocked then return false, "drops unreadable" end
  local idx = S.find(id)
  if not idx then return false, "missing" end
  if S.points[idx].fails == 0 then return true end
  local value = S.envelope()
  value.points[idx].fails = 0
  return S.commit(value, "fix", id)
end

S.note = function(id, blockName)
  if S.blocked then return false, "drops unreadable" end
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
  local value = S.envelope()
  if blockName == nil then value.points[idx].verified = nil end
  value.points[idx].fails = nextFails
  return S.commit(value, "note", id)
end

S.scan = function(kind, nearPos)
  local want, wantDist, wantId
  local anyPoint, anyDist, anyId
  local broken, brokenDist, off, suspended
  for i = 1, #S.points do
    local p = S.points[i]
    if p.suspended then suspended = suspended or p.dim == nearPos.dim and (p.kind == kind or p.kind == "any")
    elseif p.room and not S.roomSink then off = off or p.dim == nearPos.dim and p.kind == kind
    elseif p.dim == nearPos.dim and (p.kind == kind or p.kind == "any") then
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
  return want, anyPoint, broken, off, suspended
end

-- The chest a turtle at nearPos would use for kind, the fallback or HOLD. Reads only; pick and the
-- setup page's PREVIEW share it.
S.choose = function(kind, nearPos)
  if type(kind) ~= "string" or not S.kinds[kind] then return nil end
  if type(nearPos) ~= "table" or not S.whole(nearPos.dim) or not S.whole(nearPos.x)
    or not S.whole(nearPos.y) or not S.whole(nearPos.z) then
    return nil
  end
  if S.blocked then return {chain={"hold"}, reason="unreadable", alert="drops unreadable"} end
  local want, anyPoint, broken, off, suspended = S.scan(kind, nearPos)
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
    reason, failedPoint = broken and "broken" or suspended and "suspended" or "none", broken and S.pub(broken) or nil
    alert = broken and (kind .. " #" .. broken.id .. " broken at " .. broken.x .. "," .. broken.y .. "," .. broken.z)
      or suspended and (kind .. " chests suspended") or off and (kind .. " room chests off") or ("no " .. kind .. " chest set")
  end
  return { point = point, chain = chain, alert = alert, reason = reason, failedPoint = failedPoint }
end

S.pick = function(kind, nearPos)
  local got = S.choose(kind, nearPos)
  if got and not got.point then
    S.emit("drops.alert", { kind = kind, text = got.alert, reason = got.reason, point = got.failedPoint })
  end
  return got
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
  if S.blocked then return false, "drops unreadable" end
  local idx = S.find(id)
  if not idx then return false, "missing" end
  if S.points[idx].fails >= S.strikes then return false, "fix broken point first" end
  local value = S.envelope()
  if not result or not result.ok and result.err ~= "No block to inspect" then
    return false,"inspection failed; test again"
  end
  local block = result.ok and result.data and result.data.name or "minecraft:air"
  value.points[idx].verified = S.inventory(result) and {at=SO.now(),block=block} or nil
  value.points[idx].fails = S.inventory(result) and 0 or math.min(S.strikes,S.points[idx].fails+1)
  S.message = S.inventory(result) and "chest found" or ("no chest: "..tostring(block))
  return S.commit(value,"verify",id)
end

S.inLane = function(p)
  local mine = SO.mods.mine
  local map = mine and mine.mapView and mine.mapView()
  if not map or not map.homeSet or map.dim ~= p.dim then return false end
  local M = dofile("so-mine-plan.lua")
  return M.inLane({dim=map.dim,home=map.home,bottom=map.bottom,mode=map.mode,
    turtles={{branch=math.max(0,(map.branches or 0)-1)}}},p)
end

S.freeTurtle = function(id, facing, queued)
  local lease = SO.mods.lease
  if not lease or not lease.candidates or not lease.world then return nil,"lease unavailable" end
  local found = false
  for _, candidate in ipairs(lease.candidates()) do if candidate == id then found=true end end
  if not found then return nil,"no unassigned idle turtle" end
  local status=lease.status(id)
  if not status.parkBatch or not status.setupFence then return nil,"update worker for setup safety" end
  local config=SO.store.read("so-server.cfg") or {}
  local pose,err=lease.world(id,config.pos and config.pos.dim)
  local proof = S.setupProof
  if not pose and queued and err == "no fresh GPS; use explicit add" and proof and proof.id == id
    and config.pos and proof.pose.dim == config.pos.dim and SO.now() - proof.at <= 60000
    and not status.uncertain and not status.lost and status.journal == proof.journal and status.poseAt == proof.poseAt
    and status.pose and status.pose.x == proof.journalPose.x and status.pose.y == proof.journalPose.y
    and status.pose.z == proof.journalPose.z and status.pose.f == proof.journalPose.f then
    pose = SO.store.copy(proof.pose)
  end
  if not pose then return nil,err end
  if pose.facing == nil then pose.facing=facing end
  if pose.facing == nil then return nil,"facing unknown" end
  if not status.pose then return nil,"journal pose unavailable" end
  return pose
end

S.queueEnabled = function()
  return (SO.store.read("so-server.cfg") or {}).dropsTestQueue == true
end
S.queueBusy = function()
  return S.queue and (S.queue.state == "running" or S.queue.state == "stopping")
end
S.stopQueue = function(reason)
  local q = S.queue
  if not q or not S.queueBusy() then return end
  q.pending, q.reason = {}, reason
  q.state = S.task and not S.task.failed and "stopping" or "stopped"
end
S.queuePoint = function(entry, inspected)
  local idx = S.find(entry.id)
  if not idx or not S.same(S.points[idx], entry.geometry) then return nil, "point changed; test again" end
  local ok, why = S.usable(entry.id)
  if not ok and not (inspected and why == "broken") then return nil, why end
  local p = S.points[idx]
  if p.room and not S.roomSink then return nil, "room sink off" end
  return p
end
S.advanceQueue = function()
  local q = S.queue
  if not q or q.state ~= "running" or S.task or S.releasing then return end
  local entry = table.remove(q.pending, 1)
  if not entry then q.state = "done" return end
  q.current = {id=entry.id, geometry=entry.geometry, verified=false}
  local point, why = S.queuePoint(entry)
  if not point then S.stopQueue(why) return end
  if not SO.pair or not SO.pair.key(q.workerId) then S.stopQueue("worker forgotten") return end
  local ok, err = S.beginSetup(q.workerId, point, nil, true)
  if not ok then S.stopQueue(err) end
end
S.startQueue = function(view, owner, selected)
  if not S.queueEnabled() then S.message = "dropsTestQueue off" return end
  if (SO.store.read("so-server.cfg") or {}).setupMovement ~= true then S.message = "setupMovement off" return end
  if S.queueBusy() or S.task or S.releasing or S.compass then S.message = "setup busy" return end
  local pending, dim, seen = {}, view.dim, {}
  if dim == nil then
    local idx = S.find(S.selectedPoint(view) or "")
    dim = idx and S.points[idx].dim
  end
  if selected then
    for id in pairs(view.queueSelected or {}) do
      local idx = S.find(id)
      local p = idx and S.points[idx]
      if not p or p.dim ~= dim or not S.usable(id) or p.room and not S.roomSink then
        S.message = "selection unavailable" return
      end
    end
  end
  for _, p in ipairs(S.points) do
    local eligible = p.dim == dim and S.usable(p.id) and not (p.room and not S.roomSink)
    if not seen[p.id] and (selected and (view.queueSelected or {})[p.id] or not selected and eligible and not p.verified) then
      seen[p.id] = true
      pending[#pending+1] = {id=p.id, geometry=S.copy(p)}
    end
  end
  if #pending == 0 then S.message = "no points to test" return end
  local worker = view.turtle
  if not worker then
    local lease = SO.mods.lease
    local ids = lease and lease.candidates and lease.candidates() or {}
    table.sort(ids)
    for _, id in ipairs(ids) do
      local pose, why = S.freeTurtle(id, nil, true)
      if SO.pair and SO.pair.key(id) then
        if why == "facing unknown" then worker = id break end
        if pose and S.dimOf[pose.dim] == dim and S.beginSetup(id, S.points[S.find(pending[1].id)], nil, true, true) then
          worker = id break
        end
      end
    end
  end
  if not worker then S.message = "no idle turtle" return end
  S.queue = {ownerDisplay=owner, workerId=worker, pending=pending, completed=0, total=#pending, state="running"}
  S.advanceQueue()
end
S.setupRefuse = function(reason)
  S.message = reason
  return false, reason
end

S.setupSend = function()
  local task=S.task
  local step=task.steps[task.next]
  if not step then
    local message=task.message or "scan complete"
    if S.finishRelease(task.id,task.pose) then S.message=message end
    return
  end
  step.park=true
  local lid,err=SO.mods.lease.send(task.id,{step},{owner="setup",ms=15000,journal=SO.mods.lease.status(task.id).journal,pose=dofile("so-plan.lua").apply(task.pose,step.op)})
  if lid then task.lease=lid else
    task.failed=true
    S.stopQueue(tostring(err))
    return S.setupRefuse(tostring(err))
  end
  return true
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
  if task.failed then return end
  local P=dofile("so-plan.lua")
  local facts=lease.report
  if not results or not facts or not facts.pose or facts.uncertain then
    task.failed=true S.message="setup pose unknown; reservations held" S.stopQueue(S.message) return
  end
  local step=task.steps[task.next]
  local result=results[1]
  local actual=P.toWorld(task.frame,facts.pose)
  local expected=P.apply(task.pose,step.op)
  if actual.x ~= expected.x or actual.y ~= expected.y or actual.z ~= expected.z or actual.facing ~= expected.facing
    or not result or not result.ok and step.op ~= "inspect" and step.op ~= "inspectUp" and step.op ~= "inspectDown" then
    task.failed=true S.message="setup blocked; reservations held" S.stopQueue(S.message) return
  end
  task.pose=actual
  if step.scan and not task.collectFailed and S.inventory(result) then
    local p=SO.store.copy(step.scan)
    p.block, p.at = result.data.name, SO.now()
    local ok, err = S.observe(p)
    if not ok then
      task.collectFailed = true
      task.message = err == "64 found" and err or "save failed"
      S.message = task.message
    end
  end
  if step.verify then
    task.inspected = true
    local idx=S.find(step.verify)
    if idx and S.same(S.points[idx],task.point) then
      local ok,err=S.verify(step.verify,result)
      task.message=ok and S.message or tostring(err)
      if task.queued then
        S.queue.current.verified = ok and S.inventory(result) or false
        if not S.queue.current.verified then S.stopQueue(ok and "no chest" or tostring(err)) end
      end
    else task.message="point changed; test again" if task.queued then S.stopQueue(task.message) end end
  end
  task.next=task.next+1
  S.setupSend()
end

S.beginSetup = function(id, point, facing, queued, preview)
  if S.task or S.releasing then return S.setupRefuse("setup busy: #"..(S.task or S.releasing).id) end
  if not queued and S.queueBusy() then return S.setupRefuse("queue busy") end
  local config=SO.store.read("so-server.cfg") or {}
  if config.setupMovement ~= true then return S.setupRefuse("setupMovement off") end
  local pose,err=S.freeTurtle(id, facing, queued)
  if not pose then
    S.compass=err=="facing unknown" and {id=id,point=point} or nil
    return S.setupRefuse(err)
  end
  S.compass=nil
  local P=dofile("so-plan.lua")
  local dim=S.dimOf[pose.dim]
  if not dim then return S.setupRefuse("unknown dimension") end
  local steps={}
  if point then
    if point.dim ~= dim or point.fails >= S.strikes then return S.setupRefuse("fix point or dimension first") end
    local distance=math.abs(point.x-pose.x)+math.abs(point.y-pose.y)+math.abs(point.z-pose.z)
    if distance>64 then return S.setupRefuse("test route exceeds 64 blocks") end
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
    if not chosen then return S.setupRefuse("no free test route") end
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
  local cells,at,moves={pose},pose,0
  for _,step in ipairs(steps) do
    at=P.apply(at,step.op) cells[#cells+1]=at
    if step.op=="forward" or step.op=="back" or step.op=="up" or step.op=="down" then moves=moves+1 end
  end
  if moves>0 then
    local fuel=SO.mods.lease.status(id).fuel
    if fuel ~= "unlimited" and fuel ~= -1 then
      if not S.whole(fuel) or fuel<0 then return S.setupRefuse("fuel #"..id.." unknown") end
      if fuel<moves then return S.setupRefuse("fuel #"..id..": need "..moves..", have "..fuel) end
    end
  end
  if not P.inRange(SO.mods.lease,id,cells) then return S.setupRefuse("test route out of range") end
  for _,cell in ipairs(cells) do if S.inLane(cell) then return S.setupRefuse("mining lane") end end
  if preview then return true end
  local owner="setup:"..id
  local claimed,claimErr=SO.mods.lease.claimProbe(id,owner,pose)
  if claimed==false then return S.setupRefuse(claimErr) end
  local ok,why=SO.mods.cells.reserveMany(owner,cells)
  if not ok then return S.setupRefuse(why) end
  S.task={id=id,owner=owner,steps=steps,next=1,pose=pose,point=point and SO.store.copy(point),
    start=SO.store.copy(pose), queued=queued, frame=P.frame(pose,SO.mods.lease.status(id).pose)}
  S.message=point and "testing chest" or "scanning"
  return S.setupSend()
end

-- TEST with the turtle chosen on the setup page, else the first idle one; beginSetup still refuses a
-- turtle without the fuel, route or idle state for it.
S.testPoint = function(id, turtle)
  local idx=S.find(id)
  if not idx then S.message="missing point" return end
  if turtle then S.beginSetup(turtle,S.points[idx]) return end
  local lease=SO.mods.lease
  for _,turtleId in ipairs(lease and lease.candidates and lease.candidates() or {}) do
    local pose,err=S.freeTurtle(turtleId)
    if pose or err=="facing unknown" then S.beginSetup(turtleId,S.points[idx]) return end
  end
  S.message="no idle turtle with known facing"
end

S.finishRelease = function(id,pose)
  local task = S.task
  if task and task.queued and not task.failed and (pose.dim ~= task.start.dim or pose.x ~= task.start.x or pose.y ~= task.start.y
    or pose.z ~= task.start.z or pose.facing ~= task.start.facing) then
    task.failed = true
    S.stopQueue("return pose unconfirmed")
    return S.setupRefuse("return pose unconfirmed; reservations held")
  end
  local cells=SO.mods.cells
  local owner="setup:"..id
  local held=cells.owner(pose.x,pose.y,pose.z,pose.dim)
  local ok,why
  if held==owner then ok,why=cells.handoff(owner,"gps:"..id,pose.x,pose.y,pose.z,pose.dim)
  else ok,why=cells.reserve("gps:"..id,pose.x,pose.y,pose.z,pose.dim) end
  if not ok then
    if task and task.queued then task.failed=true S.stopQueue(why) end
    return S.setupRefuse(why)
  end
  ok,why=cells.releaseOwner(owner)
  if ok == false then
    if task and task.queued then task.failed=true S.stopQueue(why) end
    return S.setupRefuse(why)
  end
  if task and not task.failed then
    local status = SO.mods.lease.status(id)
    S.setupProof = {id=id, pose=SO.store.copy(pose), journal=status.journal,
      journalPose=SO.store.copy(status.pose), poseAt=status.poseAt, at=SO.now()}
  end
  S.task=nil S.message="setup released"
  if task and task.queued then
    local q = S.queue
    if not task.failed and q.current.verified then q.completed = q.completed + 1 end
    if q.state == "stopping" then q.state = "stopped"
    elseif q.state == "running" and #q.pending == 0 then q.state = "done" end
  end
  return true
end

S.releaseSetup = function(id)
  local lease=SO.mods.lease
  if S.releasing or S.task and (S.task.id ~= id or S.task.lease) then S.message="setup busy: #"..(S.releasing or S.task).id return end
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

S.forget = function(id)
  if S.setupProof and S.setupProof.id == id then S.setupProof = nil end
  if S.queue and (S.queue.ownerDisplay == id or S.queue.workerId == id) then S.stopQueue("device forgotten") end
  S.views[id] = nil
  local task = S.task and S.task.id == id and S.task
  local releasing = S.releasing and S.releasing.id == id and S.releasing
  if task then task.failed, task.lease = true, nil end
  if releasing then releasing.lease = nil end
  local cells = SO.mods.cells
  if not cells or not cells.list or not cells.handoff then return false, "cells unavailable" end
  local owner = "setup:" .. id
  -- A forgotten worker may still receive a delayed visit step. Keep the route
  -- protected until explicit re-add claims its actual pose and clears GPS holds.
  for _, cell in ipairs(cells.list(owner, math.huge)) do
    local ok, err = cells.handoff(owner, "gps:" .. id, cell.x, cell.y, cell.z, cell.dim)
    if not ok then return false, err end
  end
  local ok, err = cells.releaseOwner(owner)
  if not ok then return false, err end
  if task then
    S.task = nil
    if S.data.v ~= 2 and not S.enabled() then S.publishFound({}) end
  end
  if releasing then S.releasing = nil end
  if S.compass and S.compass.id == id then S.compass = nil end
  if S.queue and S.queue.workerId == id and S.queue.state == "stopping" then S.queue.state = "stopped" end
  return true
end

S.row = function(text)
  return { text = text or "", fg = "0", bg = "f" }
end

S.button = function(id, x, y, label)
  return { id = id, x = x, y = y, w = #label, label = label }
end

S.view = function(id)
  id = id or 0
  if not S.views[id] then S.views[id] = { page = 1, pages = 1 } end
  return S.views[id]
end
S.copy = function(p)
  return { dim = p.dim, x = p.x, y = p.y, z = p.z, side = p.side, kind = p.kind, room = p.room or nil }
end
S.draftOf = function(view)
  view.draft = view.draft or S.copy(S.blank)
  return view.draft
end
-- Two-tap controls (U.confirm); the kit-free screen carries its own copy.
S.confirm = U and U.confirm or function(state, tapped, now)
  if state.confirm and now - (state.confirmAt or now) > 5000 then state.confirm = nil end
  if tapped == nil or state.confirm == tapped then
    local hit = tapped ~= nil
    state.confirm = nil
    return hit
  end
  state.confirm, state.confirmAt = tapped, now
  return false
end
setmetatable(S.views, { __mode = "k" })

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
    buttons[#buttons + 1] = S.button("remove:" .. p.id, 6, #rows, view.confirm == "remove:" .. p.id and "confirm" or "remove")
  end
  rows[#rows + 1] = S.row("          " .. view.page .. "/" .. view.pages)
  buttons[#buttons + 1] = S.button("prev", 1, #rows, "prev")
  buttons[#buttons + 1] = S.button("next", 6, #rows, "next")
  local d = view.draft or S.blank
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

-- A draft's id comes from its place, side and kind. An edited point keeps its old id, so when that id
-- is taken by a point that has since moved, the new one gets the first free numbered id.
S.idOf = function(d)
  local base = string.format("%d_%d_%d_%d_%s_%s", d.dim, d.x, d.y, d.z, d.side, d.kind)
  local id, n = base, 1
  while S.find(id) do n = n + 1 id = base .. "_" .. n end
  return id
end
-- ADD makes a new point; the next NEW starts again from the selection. A point already at the
-- draft's place, side and kind is a duplicate whatever its id: a tapped ADD says so, and a typed
-- add of the same point still reads as added.
S.addDraft = function(view, tapped)
  local d = S.draftOf(view)
  local same = S.match(d)
  if same and tapped then S.message = S.errText.exists return end
  local ok, err = same and S.same(S.points[same], d), "exists"
  if not same then
    ok, err = S.add({ id = S.idOf(d), dim = d.dim, x = d.x, y = d.y, z = d.z, side = d.side, kind = d.kind, room = d.room })
  end
  S.message = ok and "point added" or (S.errText[err] or tostring(err))
  if ok then view.drafted, view.edit = false, nil end
  -- An editor opened from a FOUND chest goes back to chest setup, where the chest stays listed.
  if ok and view.found then
    view.found, view.editing, view.testing = nil, false, true
    return true
  end
end

-- A typed point is its list number or, when not a number, its id; a number past the list is missing.
S.pointId = function(word)
  if not word:match("^%d+$") then return word end
  local p = S.points[tonumber(word)]
  return p and p.id or false
end

S.typed = function(text, view)
  local scan=text:match("^scan%s+(%d+)$")
  if scan then S.beginSetup(tonumber(scan)) return end
  local visit=text:match("^test%s+([%w_%-]+)$")
  if visit then S.testPoint(S.pointId(visit), view.turtle) return end
  local release=text:match("^release%s+(%d+)$")
  if release then S.releaseSetup(tonumber(release)) return end
  local words = {}
  for word in text:gmatch("%S+") do words[#words + 1] = word end
  if words[1] == "room" then
    if #words ~= 3 or words[3] ~= "on" and words[3] ~= "off" then S.message = "invalid room command" return end
    local ok, err
    if words[2] == "sink" then ok,err = S.setRoomSink(words[3] == "on")
    else ok,err = S.roomMark(S.pointId(words[2]),words[3] == "on") end
    S.message = ok and "room saved" or (S.errText[err] or tostring(err))
    return
  end
  local d = S.draftOf(view)
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
  view.draft = { dim = dim, x = x, y = y, z = z, kind = kind, side = side, room = (kind == "ore" or kind == "wood") and d.room or nil }
  view.drafted = true
  S.message = nil
  if direct then return S.addDraft(view) end
end

-- Route A screen (docs/ui/SCHEMATIC-SPEC.md); docs/ui/schematic/jobs.py is the twin of S.gather
-- and the layouts and writes their fixtures. Page, selection and the editor belong to the display.
S.scales = { 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64 }
S.dirs = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
S.key = function(session, from)
  if type(session) == "table" then return session.id or session end
  return from or session
end
-- The selection stays inside the display's dimension filter.
S.shown = function(view, p) return not view or view.dim == nil or p.dim == view.dim end
S.selectedPoint = function(view)
  local idx = view and view.selected and S.find(view.selected)
  if idx and S.shown(view, S.points[idx]) then return view.selected end
  for _, p in ipairs(S.points) do if p.fails >= S.strikes and S.shown(view, p) then return p.id end end
  for _, p in ipairs(S.points) do if S.shown(view, p) then return p.id end end
end
S.previewKind = function(view)
  local idx = S.find(S.selectedPoint(view) or "")
  return view.previewKind or idx and S.points[idx].kind or "ore"
end
-- What PREVIEW shows for the chosen turtle: the chest pick would use, the fallback or HOLD.
S.preview = function(view)
  local id, kind = view.turtle, S.previewKind(view)
  local out, lease = { id = id, kind = kind }, SO.mods.lease
  local cfg = SO.store.read("so-server.cfg") or {}
  local pose = lease and lease.world and lease.world(id, cfg.pos and cfg.pos.dim)
  local dim = pose and (S.dimOf[pose.dim] or S.whole(pose.dim) and pose.dim)
  if not dim then out.text = "position unknown" return out end
  local got = S.choose(kind, { dim = dim, x = pose.x, y = pose.y, z = pose.z })
  local p = got and (got.point or got.failedPoint)
  local n = p and S.find(p.id)
  if got and got.point then out.text, out.short = n .. " " .. p.kind .. " " .. S.at(p), n .. " " .. S.at(p)
  elseif n then out.hold = n .. " broken"
  else out.hold = got and got.alert or "position unknown" end
  return out
end
S.fromTurtle = function(id, view)
  S.fromError = true
  local lease = SO.mods.lease
  local config = SO.store.read("so-server.cfg")
  local dim = config and config.pos and config.pos.dim
  local number = S.dimOf[dim]
  if not number or not lease or not lease.world then S.message = "turtle world pose unavailable" return end
  local p, err = lease.world(id, dim)
  if not p then S.message = err return end
  local x, y, z, d = p.x, p.y, p.z, S.draftOf(view)
  if d.side == "down" then y = y-1
  elseif p.facing == nil then S.message = "facing unknown; add turtle first" return
  else x, z = x+({[0]=0,1,0,-1})[p.facing], z+({[0]=-1,0,1,0})[p.facing] end
  d.x, d.y, d.z, d.dim = x, y, z, number
  view.drafted, S.message, S.fromError = true, nil, nil
end
S.call = function(name, fn)
  local mod = SO.mods[name]
  if type(mod) ~= "table" or type(mod[fn]) ~= "function" then return end
  local ok, got = pcall(mod[fn])
  if ok and type(got) == "table" then return got end
end
-- The plan's context: the server from so-server.cfg, the shaft and the farm, read every five seconds.
S.context = function()
  local now = SO.now()
  if S.ctx and now >= S.ctx.at and now < S.ctx.at + 5000 then return S.ctx end
  local ctx, read = { at = now }, SO.store.read
  local cfg = type(read) == "function" and read("so-server.cfg")
  if type(cfg) == "table" and type(cfg.pos) == "table" and S.whole(cfg.pos.x) and S.whole(cfg.pos.z) then
    ctx.server = { x = cfg.pos.x, z = cfg.pos.z }
  end
  local mine, wood = S.call("mine", "mapView"), S.call("lumber", "mapView")
  local home = mine and mine.homeSet ~= false and mine.home
  if type(home) == "table" and S.dirs[home.facing] then
    ctx.shaft = { x = home.x + S.dirs[home.facing][1], z = home.z + S.dirs[home.facing][2] }
  end
  if wood and type(wood.area) == "table" then ctx.area = wood.area end
  S.ctx = ctx
  return ctx
end
S.gather = function(view)
  local ctx, list = S.context(), {}
  -- The list page shows only the filter's dimension; points keep their numbers.
  local filter, dims = not view.editing and not view.testing and view.dim, {}
  for i, p in ipairs(S.points) do
    dims[p.dim] = true
    if not filter or p.dim == filter then list[#list + 1] = { n = i, id = p.id, dim = p.dim, kind = p.kind, x = p.x, y = p.y, z = p.z, side = p.side,
      suspended = p.suspended == true, broken = p.fails >= S.strikes, verified = p.verified ~= nil, room = p.room == true } end
  end
  local multi = next(dims) ~= nil and next(dims, next(dims)) ~= nil
  -- Unassigned turtles for the editor's from row and the setup tab's scans.
  local turtles, state, lease = {}, SO.mods.state, SO.mods.lease
  local machines = state and type(state.get) == "function" and state.get("machines") or {}
  for id, row in pairs(machines) do
    if (row.role == "turtle" or row.role == "worker") and SO.pair and SO.pair.key(tonumber(id)) then turtles[#turtles+1] = tonumber(id) end
  end
  if lease and lease.candidates then turtles = lease.candidates() end
  table.sort(turtles)
  local chosen = S.task ~= nil and view.turtle == S.task.id
  for _, id in ipairs(turtles) do chosen = chosen or id == view.turtle end
  local edit = view.edit and S.find(view.edit)
  return { points = list, selected = S.selectedPoint(view), page = view.page, editing = view.editing,
    edit = view.editing and edit or nil,
    confirm = view.confirm and SO.now() - (view.confirmAt or 0) <= 5000 and view.confirm or nil,
    -- A turtle waiting for its facing shows the compass on every drop display until it is answered.
    testing = view.testing or S.compass ~= nil and not view.editing,
    savedSetup = S.enabled(), queueEnabled = S.queueEnabled(), queue = S.queue,
    queueTools = view.queueTools, queueSelected = view.queueSelected or {},
    message = S.message, draft = view.draft or S.blank, roomSink = S.roomSink, turtles = turtles,
    from = view.fromPage or 0, compass = S.compass, found = S.candidates, task = S.task and S.task.id,
    failed = S.task and S.task.failed,
    server = ctx.server, shaft = ctx.shaft, area = ctx.area,
    dim = view.dim, dims = view.dim ~= nil or multi,
    turtle = chosen and view.turtle or nil, preview = chosen and view.testing and S.preview(view) or nil }
end
S.at = function(p) return p.x .. "," .. p.y .. "," .. p.z end
-- The chests around home, one block per cell when they fit, labelled by number; the server, the
-- shaft and the farm edge for context. Returns the last row drawn.
S.plan = function(C, m, x0, y0, pw, ph, draft)
  local pts, items, dim = {}, {}, 0
  for _, p in ipairs(m.points) do if p.id == m.selected then dim = p.dim end end
  if draft then dim = draft.dim end
  for _, p in ipairs(m.points) do if p.dim == dim then pts[#pts + 1] = p items[#items + 1] = { p.x, p.z } end end
  -- The server, the shaft and the farm are in the overworld.
  if dim ~= 0 then m = { points = m.points, selected = m.selected } end
  local function span(i)
    local lo, hi = math.huge, -math.huge
    for _, it in ipairs(items) do lo, hi = math.min(lo, it[i]), math.max(hi, it[i]) end
    return lo, hi
  end
  if draft and #items > 0 then
    local x1, x2 = span(1)
    local z1, z2 = span(2)
    if draft.x < x1 - 32 or draft.x > x2 + 32 or draft.z < z1 - 32 or draft.z > z2 + 32 then draft = nil end
  end
  if draft then items[#items + 1] = { draft.x, draft.z } end
  if #items == 0 then return y0 - 1 end
  -- North is up, as on the map; the compass sits on the row above the plan.
  if y0 > 2 then C.put(x0 + pw - 2, y0 - 1, "\24N", "8") end
  for _, k in ipairs({ "server", "shaft" }) do if m[k] then items[#items + 1] = { m[k].x, m[k].z } end end
  -- Both farm corners are in the fit, so the farm edge is never cut.
  if m.area then items[#items + 1], items[#items + 2] = { m.area.x1, m.area.z1 }, { m.area.x2, m.area.z2 } end
  local bx1, bx2 = span(1)
  local bz1, bz2 = span(2)
  local s = S.scales[#S.scales]
  for _, v in ipairs(S.scales) do
    if math.floor((bx2 - bx1) / v) + 1 <= pw - 4 and math.floor((bz2 - bz1) / v) + 1 <= ph then s = v break end
  end
  local left = bx1 - math.floor((pw - math.floor((bx2 - bx1) / s) - 1) / 2) * s
  local top = bz1 - math.floor((ph - math.floor((bz2 - bz1) / s) - 1) / 2) * s
  local function cell(x, z)
    local c, r = math.floor((x - left) / s), math.floor((z - top) / s)
    if c >= 0 and c < pw and r >= 0 and r < ph then return { x0 + c, y0 + r } end
  end
  local taken, marks = {}, {}
  local function take(x, y) taken[x .. "," .. y] = true end
  local a = m.area
  local c1, c2 = a and cell(a.x1, a.z1), a and cell(a.x2, a.z2)
  if c1 and c2 then
    for x = c1[1], c2[1] do
      for _, y in ipairs({ c1[2], c2[2] }) do C.put(x, y, "-", "c") take(x, y) end
    end
    for y = c1[2], c2[2] do
      for _, x in ipairs({ c1[1], c2[1] }) do C.put(x, y, "|", "c") take(x, y) end
    end
    for _, p in ipairs({ { c1[1], c1[2] }, { c2[1], c1[2] }, { c1[1], c2[2] }, { c2[1], c2[2] } }) do C.put(p[1], p[2], "+", "c") end
  end
  if m.shaft then marks[#marks + 1] = { cell(m.shaft.x, m.shaft.z), U.g.shaft, "9", nil, "shaft", "8" } end
  if m.server then marks[#marks + 1] = { cell(m.server.x, m.server.z), "@", "9", nil, "server", "8" } end
  for _, p in ipairs(pts) do
    local c = p.broken and "e" or "0"
    marks[#marks + 1] = { cell(p.x, p.z), p.broken and U.g.cross or U.g.bullet, c, p.id == m.selected and not draft and c or nil,
      tostring(p.n), p.broken and "e" or "8", not draft and "select:" .. p.id or nil }
  end
  if draft then marks[#marks + 1] = { cell(draft.x, draft.z), U.g.bullet, "9", "9" } end
  local drawn = {}
  for _, mk in ipairs(marks) do
    local at = mk[1]
    if at then
      C.put(at[1], at[2], mk[2], mk[4] and "f" or mk[3], mk[4])
      if mk[7] then C.hit(mk[7], at[1], at[2], 1, 1) end
      take(at[1], at[2])
      drawn[#drawn + 1] = mk
    end
  end
  for _, mk in ipairs(drawn) do
    local at, label = mk[1], mk[5]
    if label then
      for _, x in ipairs({ at[1] + 1, at[1] - #label }) do
        local free = x >= x0 and x + #label <= x0 + pw
        for j = -1, #label do
          if free and taken[(x + j) .. "," .. at[2]] and x + j ~= at[1] then free = false end
        end
        if free then
          C.put(x, at[2], label, mk[6])
          for j = 0, #label - 1 do take(x + j, at[2]) end
          break
        end
      end
    end
  end
  return y0 + ph - 1
end
S.list = function(C, m)
  local w, h = C.w, C.h
  local room = w >= 52 and h >= 22
  local ya, pts, broken = room and h - 1 or h, m.points, {}
  for _, p in ipairs(pts) do if p.broken then broken[#broken + 1] = p end end
  local nf = math.min(#broken, h >= 19 and 2 or 1)
  local lw, head = room and 34 or w - 1, h >= 14 and 4 or 3
  local cap = math.max(1, math.min(24, ya - 1 - (nf > 0 and nf + 1 or 0) - head - (room and 1 or 0) + 1))
  local pages = math.max(1, math.ceil(#pts / cap))
  local page = math.min(m.page, pages)
  local right, roomy = tostring(#pts), w >= 30
  if pages > 1 then right = string.format(roomy and "    %d/%d    " or " %d/%d ", page, pages) end
  -- The dimension filter shows once points span two dimensions, or while it is set. Narrow screens
  -- shorten the title, then the labels, then drop the title, sized for the longest label so the
  -- chip never vanishes when tapped on.
  local title = roomy and "DROP POINTS" or "DROPS"
  if m.dims then
    local label
    for _, try in ipairs({ { title, 1, 6 }, { "DROPS", 1, 6 }, { "DROPS", 3, 3 }, { "", 3, 3 } }) do
      title, label = try[1], try[2]
      if (title == "" and 2 or #title + 3) + try[3] + 1 <= w - #right - 2 then break end
    end
    C.bar(title, {}, nil, right, "8")
    for _, f in ipairs(S.filters) do
      if f[2] == m.dim then C.chip(title == "" and 2 or #title + 3, 1, f[label], "dims", m.dim and "on" or "plain") end
    end
  else C.bar(title, {}, nil, right, "8") end
  if pages > 1 then
    C.chip(w - #right, 1, U.g.left, "prev", "plain", roomy and 3 or 1)
    C.chip(w - (roomy and 3 or 1), 1, U.g.right, "next", "plain", roomy and 3 or 1)
  end
  local wide = lw >= 34
  local wx = wide and 15 or 13
  if head == 4 then
    C.put(2, 3, "id", "8")
    C.put(5, 3, "kind", "8")
    C.put(wx, 3, "where", "8")
    if wide then C.put(28, 3, "side", "8") end
  end
  local shown, sel = 0, nil
  for i = (page - 1) * cap + 1, math.min(#pts, page * cap) do
    local p, y = pts[i], head + shown
    local bg = p.id == m.selected and "7" or nil
    if bg then C.fill(1, y, lw, 1, "7") end
    local c = p.broken and "e" or "0"
    -- Room points read "ore room" where it fits, muted while room sinks are off.
    local kind = p.room and #p.kind + 5 <= wx - 6 and p.kind .. " room" or p.kind
    C.put(2, y, tostring(p.n), c, bg)
    C.put(5, y, kind:sub(1, wx - 6), p.room and not m.roomSink and not p.broken and "8" or c, bg)
    if wide then
      C.put(15, y, S.at(p):sub(1, 12), "8", bg)
      C.put(28, y, p.side, "8", bg)
    else C.put(13, y, S.at(p):sub(1, lw - 14), "8", bg) end
    C.put(lw, y, p.broken and U.g.cross or p.verified and U.g.bullet or U.g.dot, p.broken and "e" or p.verified and "d" or "8", bg)
    C.hit("select:" .. p.id, 1, y, lw, 1)
    shown = shown + 1
  end
  for i = 1, nf do
    local p = broken[i]
    local text = (i == nf and #broken > nf) and (#broken .. " broken") or (p.n .. " " .. p.kind .. " broken")
    C.flag(2, head + shown + i, lw - 1, text)
  end
  for _, p in ipairs(pts) do if p.id == m.selected then sel = p end end
  local tag = sel and " " .. sel.n or ""
  -- SCAN opens chest setup from 24 columns; narrow rows shorten REMOVE before they cut it.
  local n, gap = w >= 24 and 4 or 3, room and 2 or 1
  local bw = math.floor((w - 2 - gap * (n - 1)) / n)
  -- EDIT takes FIX's place while the selection is not broken; an armed REMOVE reads CONFIRM.
  local first = sel and not sel.broken and "EDIT" or "FIX"
  local fix, rem = first .. tag, "REMOVE" .. tag
  if #rem > bw then fix, rem = first, "REMOVE" end
  if n == 4 and #rem > bw then rem = "DEL" end
  local items = { { fix, "fix", sel and (sel.broken and "primary" or "plain") or "muted" },
    U.confirmChip(m, sel and "remove:" .. sel.id or false, rem, "remove", sel and "stop" or "muted"), { "ADD", "new", "plain" } }
  if n == 4 then items[4] = { "SCAN", "testing", "plain" } end
  U.actions(C, ya, items, gap)
  if room then
    local bottom = S.plan(C, m, 38, 3, math.min(w - 38, 48), math.min(ya - 4, 32))
    for y = 3, bottom do C.put(36, y, "|", "c") end
  end
end
-- Chips in one row from x to right, starting at item first (wrapping); a + chip scrolls on.
S.scroll = function(C, list, first, x, y, right, chip)
  first = first % #list
  local shown = 0
  for k = first + 1, #list do
    local label, id = chip(list[k])
    if x + #label + 1 + ((k < #list or first > 0) and 4 or 0) > right then break end
    x = C.chip(x, y, label, id, "plain") + 1
    shown = shown + 1
  end
  if shown < #list then C.chip(x, y, "+", "from-next", "plain") end
end
-- Chest setup with an idle turtle: the selected point, the turtles to scan with (RELEASE on the one
-- doing setup), the chests the scans found, and TEST, FIX and BACK. A turtle without a facing
-- asks for it first.
S.okText = { ["chest found"] = true, ["scan complete"] = true, ["setup released"] = true, ["scanning"] = true,
  ["testing chest"] = true, ["confirming release"] = true, ["room saved"] = true, ["point added"] = true,
  ["point saved"] = true, ["point suspended"] = true, ["point resumed"] = true, ["found cleared"] = true }
S.queueSetup = function(C, m)
  local w, q = C.w, m.queue
  C.bar(w >= 30 and "CHEST SETUP" or "SETUP", {}, nil, "", "8")
  C.chip(w - 3, 1, "+", "from-next", "plain")
  local ya = U.controlRows(C, { {"TEST ALL", "test-all", "primary"},
    {w < 18 and "CHECK" or "CHECK SELECTED", "test-selected", "primary"},
    {"STOP QUEUE", "queue-stop", "stop"}, {"TOOLS", "queue-tools", "plain"} }, {"BACK", "list", "plain"})
  local dim = m.dim
  if dim == nil then for _, p in ipairs(m.points) do if p.id == m.selected then dim = p.dim end end end
  local points = {}
  for _, p in ipairs(m.points) do if p.dim == dim then points[#points+1] = p end end
  C.put(2, 2, q and (q.completed .. "/" .. q.total .. " " .. (q.state == "running" and "testing" or q.state)) or "-", "0")
  C.put(2, 3, (q and q.current and q.current.id or "-"):sub(1, w - 2), "8")
  local capacity = math.max(1, ya - 5)
  local first = (m.from % math.max(1, math.ceil(#points / capacity))) * capacity + 1
  for i = first, math.min(#points, first + capacity - 1) do
    local p, y = points[i], 4 + i - first
    local label = (m.queueSelected[p.id] and "[x] " or "[ ] ") .. p.id
    C.put(2, y, label:sub(1, w - 2), p.broken and "e" or p.suspended and "8" or "0")
    C.hit("queue-select:" .. p.id, 2, y, w - 2, 1)
  end
  local message = q and q.reason or m.message
  if message then C.flag(2, ya - 1, w - 2, message) end
end
S.setup = function(C, m)
  if m.queueEnabled and m.compass then
    C.bar("SETUP", {}, nil, "", "8")
    if m.queue then
      C.put(2, 2, m.queue.completed .. "/" .. m.queue.total .. " " .. m.queue.state, "0")
      C.put(2, 3, (m.queue.current and m.queue.current.id or "-"):sub(1, C.w - 2), "8")
    end
    C.section(2, 5, C.w - 2, "FACING #" .. m.compass.id)
    U.controlRows(C, {{"N", "facing:0", "primary"}, {"E", "facing:1", "primary"},
      {"S", "facing:2", "primary"}, {"W", "facing:3", "primary"},
      {"CANCEL", "facing-cancel", "plain"}}, {"BACK", "list", "plain"})
    return
  end
  if m.queueEnabled and not m.queueTools and not m.compass then S.queueSetup(C, m) return end
  local w, h = C.w, C.h
  local room = w >= 52 and h >= 22
  local ya, stop, sel = room and h - 1 or h, (room and h - 1 or h) - 2, nil
  C.bar(w >= 30 and "CHEST SETUP" or "SETUP", {}, nil, "", "8")
  for _, p in ipairs(m.points) do if p.id == m.selected then sel = p end end
  if m.savedSetup or m.queueEnabled then
    local controls = { { "TEST", "test", sel and "primary" or "muted" },
      { "FIX", "fix", sel and sel.broken and "primary" or "muted" } }
    if m.queueEnabled then controls[#controls+1] = {"QUEUE", "queue-tools", "plain"} end
    if sel and m.savedSetup then controls[#controls+1] = { sel.suspended and "RESUME" or "SUSPEND",
      (sel.suspended and "resume:" or "suspend:") .. sel.id, "plain" } end
    if m.savedSetup and #m.found > 0 then controls[#controls+1] = U.confirmChip(m, "clear-found", "CLEAR FOUND", "clear-found", "stop") end
    ya = U.controlRows(C, controls, { "BACK", "list", "plain" })
    stop = ya - 2
  end
  local py = m.savedSetup and h < 12 and 2 or 3
  if m.savedSetup then C.chip(w - 3, 1, "+", "from-next", "plain") end
  C.put(2, py, "point", "8")
  -- Narrow screens drop the kind, then the side, before they cut the position.
  local text = "-"
  if sel then
    for _, t in ipairs({ sel.n .. " " .. sel.kind .. " " .. S.at(sel) .. " " .. sel.side, sel.n .. " " .. S.at(sel) .. " " .. sel.side,
        sel.n .. " " .. S.at(sel) }) do
      text = t
      if #t <= w - 9 then break end
    end
  end
  C.put(8, py, text:sub(1, math.max(0, w - 9)), sel and (sel.broken and "e" or "0") or "8")
  if sel and sel.suspended then C.put(2, py + 1, "suspended", "8") end
  local y = py + 2
  if m.compass then
    C.section(2, y, w - 2, "FACING #" .. m.compass.id)
    local x = 2
    for i, label in ipairs({ "N", "E", "S", "W" }) do x = C.chip(x, y + 1, label, "facing:" .. (i - 1), "primary", 5) + 1 end
    C.chip(2, y + 3, "cancel", "facing-cancel", "plain")
  else
    -- A chosen turtle is TEST's turtle, and PREVIEW shows the chest it would use for the kind.
    local pv = m.preview
    if pv and y + 1 < stop then
      C.section(2, y, w - 2, "PREVIEW #" .. pv.id)
      local x = C.chip(2, y + 1, pv.kind, "preview-kind", "plain") + 1
      if pv.hold then
        C.put(x, y + 1, "HOLD", "e")
        C.put(x + 5, y + 1, pv.hold:sub(1, math.max(0, w - x - 5)), "8")
      else C.put(x, y + 1, (#pv.text < w - x and pv.text or pv.short or pv.text):sub(1, math.max(0, w - x)), "0") end
      y = y + 2
    end
    local items, section = {}, nil
    local listed = false
    for _, id in ipairs(m.turtles) do items[#items + 1] = { "TURTLES", id } listed = listed or id == m.task end
    if m.task and not listed then items[#items + 1] = { "TURTLES", m.task } end
    if #items == 0 then items[1] = { "TURTLES" } end
    for i, p in ipairs(m.found) do items[#items + 1] = { "FOUND", i, p } end
    local k = m.from % #items + 1
    while k <= #items and y <= stop do
      local it = items[k]
      if it[1] ~= section then
        if y + 1 > stop then break end
        section = it[1]
        C.section(2, y, w - 2, section == "FOUND" and m.savedSetup and "FOUND " .. #m.found or section)
        y = y + 1
      end
      if not m.savedSetup and y == stop and k < #items then
        C.put(4, y, "+" .. (#items - k + 1) .. " more", "8")
        C.hit("from-next", 2, y, w - 2, 1)
        break
      end
      if it[3] then
        C.put(2, y, U.g.bullet, "0")
        C.put(4, y, (S.at(it[3]) .. " " .. it[3].side):sub(1, math.max(0, w - 10)), "0")
        C.chip(w - 5, y, m.savedSetup and "ADD" or "add", "candidate:" .. it[2], "plain")
      elseif it[2] then
        local busy, bg = m.task == it[2], m.turtle == it[2] and "7" or nil
        if bg then C.fill(1, y, w - 7, 1, bg) end
        C.put(2, y, U.g.bullet, busy and (m.failed and "e" or "1") or "d", bg)
        C.put(4, y, "#" .. it[2], "0", bg)
        C.hit("turtle:" .. it[2], 1, y, w - 10, 1)
        if busy then C.chip(w - 9, y, "release", "release", "stop") else C.chip(w - 6, y, "scan", "scan:" .. it[2], "primary") end
      else C.put(4, y, "-", "8") end
      y, k = y + 1, k + 1
    end
  end
  if m.message and S.okText[m.message] then C.put(2, ya - 1, m.message, "d")
  elseif m.message then C.flag(2, ya - 1, w - 2, m.message) end
  if not m.savedSetup and not m.queueEnabled then U.actions(C, ya, { { "TEST", "test", sel and "primary" or "muted" }, { "FIX", "fix", sel and sel.broken and "primary" or "muted" },
    { "BACK", "list", "plain" } }, room and 2 or 1) end
end
S.editor = function(C, m)
  local w, h = C.w, C.h
  local room = w >= 52 and h >= 22
  local ya, d = room and h - 1 or h, m.draft
  C.bar(m.edit and "EDIT POINT " .. m.edit or "ADD DROP POINT", {}, nil, "", "8")
  local step, vx, vw = h >= 19 and 2 or 1, w >= 36 and 13 or 8, w >= 36 and 8 or 6
  local y = h >= 12 and 3 or 2
  for _, field in ipairs({ "kind", "side" }) do
    if w < 24 then C.chip(2, y, d[field], field, "plain", w - 2)
    else
      C.put(2, y, field, "8")
      C.chip(vx, y, d[field], field, "plain", vw + 9)
    end
    y = y + step
  end
  for _, field in ipairs({ "dim", "x", "y", "z" }) do
    if y > ya - 2 then break end
    C.put(2, y, field, "8")
    if w < 24 then
      C.put(3 + #field, y, tostring(d[field]):sub(1, math.max(0, w - 10 - #field)), "0")
      C.chip(w - 7, y, "-", field .. "-")
      C.chip(w - 3, y, "+", field .. "+")
    else U.stepper(C, vx, y, d[field], field, vw) end
    y = y + step
  end
  if w >= 24 and y <= ya - 2 then
    C.put(2, y, "room", "8")
    local nx = C.chip(vx, y, "point", "room-point", d.room and "on" or "off") + 1
    C.chip(nx, y, "sinks", "room-sink", m.roomSink and "on" or "off")
    y = y + step
  end
  -- The draft from a turtle's position: the cell ahead, or below for a down point.
  if w >= 24 and #m.turtles > 0 and y <= ya - 2 then
    C.put(2, y, "from", "8")
    S.scroll(C, m.turtles, m.from, vx, y, room and vx + vw + 11 or w - 1, function(id) return "#" .. id, "from:" .. id end)
  end
  if S.okText[m.message] then C.put(2, ya - 1, m.message, "d")
  elseif m.message then C.flag(2, ya - 1, w - 2, m.message) end
  U.actions(C, ya, { m.edit and { "SAVE", "save", "primary" } or { "ADD", "add", "primary" }, { "BACK", "list", "plain" } }, room and 3 or 1)
  if room then
    local rx = vx + vw + 13
    local bottom = S.plan(C, m, rx + 2, 3, math.min(w - rx - 2, 48), math.min(ya - 4, 32), d)
    for yy = 3, bottom do C.put(rx, yy, "|", "c") end
  end
end
S.layout = function(model, w, h)
  local C = U.canvas(w, h)
  if model.editing then S.editor(C, model) elseif model.testing then S.setup(C, model) else S.list(C, model) end
  return C.frame()
end
S.listSize = function(points, w, h)
  local room, count = w >= 52 and h >= 22, #points
  local broken = 0
  for _, p in ipairs(points) do if p.broken then broken = broken + 1 end end
  local nf = math.min(broken, h >= 19 and 2 or 1)
  local cap = math.max(1, math.min(24, (room and h - 1 or h) - 1 - (nf > 0 and nf + 1 or 0) - (h >= 14 and 4 or 3) - (room and 1 or 0) + 1))
  return { pages = math.max(1, math.ceil(count / cap)), capacity = cap }
end

S.render = function(w, h, session)
  if not U then return S.legacyRender(w, h, session) end
  w, h = w or 57, h or 24
  local view = S.view(S.key(session))
  local model = S.gather(view)
  local size = S.listSize(model.points, w, h)
  if view.focus then
    for i,p in ipairs(model.points) do if p.id==view.focus then model.page=math.floor((i-1)/size.capacity)+1 end end
    view.focus=nil
  end
  model.page = math.min(model.page, size.pages)
  view.page = model.page
  local sel = S.find(model.selected or "")
  view.chip = sel and { model.selected, S.points[sel].fails < S.strikes and "edit" or "fix" } or nil
  local frame = S.layout(model, w, h)
  view.queueButtons = {}
  for _, button in ipairs(frame.buttons) do
    if button.id:match("^queue%-") or button.id == "test-all" or button.id == "test-selected" then
      view.queueButtons[button.id] = true
    end
  end
  frame.rev = S.rev
  return frame
end

S.input = function(ev)
  if type(ev) ~= "table" then return end
  local view = S.view(S.key(ev.session, ev.from))
  local now = SO.now()
  view.touched = now
  -- REMOVE arms on the first tap and removes on the second; any other tap or text disarms. The key
  -- names the point, so a selection that moved on arms again instead of removing.
  local removing = ev.id == "remove" and S.selectedPoint(view) or type(ev.id) == "string" and ev.id:match("^remove:(.+)$")
  local clearing = ev.id == "clear-found"
  local confirmed = S.confirm(view, removing and "remove:" .. removing or clearing and "clear-found" or nil, now)
  if clearing then
    if confirmed then
      local ok, err = S.clearFound()
      S.message = ok and "found cleared" or "save failed: " .. tostring(err)
    end
    return
  end
  if S.blocked then S.message = "drops unreadable" return end
  if removing then
    if confirmed then S.remove(removing) end
    return
  end
  if type(ev.text) == "string" then
    if S.typed(ev.text, view) then return end
    -- Typed scan, test and release follow on the setup tab; room changes leave the page alone.
    if U and (ev.text:match("^scan%s") or ev.text:match("^test%s") or ev.text:match("^release%s")) then
      view.testing, view.editing, view.found = true, false, nil
    elseif U and not ev.text:match("^room%s") then view.editing = true end
    return
  end
  if type(ev.id) ~= "string" then return end
  if ev.id:match("^queue%-") or ev.id == "test-all" or ev.id == "test-selected" then
    if not S.queueEnabled() or not view.testing or view.editing or not view.queueButtons or not view.queueButtons[ev.id] then return end
    if ev.id == "queue-tools" then view.queueTools = not view.queueTools return end
    if ev.id == "queue-stop" then S.stopQueue("stopped by operator") return end
    if ev.id == "test-all" or ev.id == "test-selected" then
      S.startQueue(view, S.key(ev.session, ev.from) or 0, ev.id == "test-selected") return
    end
    local pointId = ev.id:match("^queue%-select:(.+)$")
    local idx = pointId and S.find(pointId)
    if idx and S.shown(view, S.points[idx]) then
      view.queueSelected = view.queueSelected or {}
      view.queueSelected[pointId] = not view.queueSelected[pointId] or nil
      view.selected = pointId
    end
    return
  end
  local suspended = ev.id:match("^suspend:(.+)$")
  local resumed = ev.id:match("^resume:(.+)$")
  if suspended or resumed then
    local ok, err = S.suspend(suspended or resumed, suspended ~= nil)
    S.message = ok and (suspended and "point suspended" or "point resumed") or tostring(err)
    return
  end
  -- NEW starts from the selected point, room mark included, unless this display has an unsaved draft.
  if ev.id == "new" then
    view.editing, view.testing, view.found = true, false, nil
    if view.edit then view.edit, view.draft, view.drafted = nil, nil, false end
    local idx = S.find(S.selectedPoint(view) or "")
    if not view.drafted and idx then view.draft = S.copy(S.points[idx]) end
    S.draftOf(view)
    return
  end
  -- The first chip is FIX on a broken point and EDIT otherwise; a tap does what the last frame drew
  -- for that point, so a double-tapped FIX never opens the editor. A second EDIT of a point keeps its unsaved changes.
  local id = (ev.id == "fix" or ev.id == "edit") and S.selectedPoint(view)
  local chip = id and (view.chip and view.chip[1] == id and view.chip[2]
    or S.points[S.find(id)].fails >= S.strikes and "fix" or "edit")
  if ev.id == "fix" and chip == "fix" then view.selected = id S.fix(id) return end
  if ev.id == "fix" or ev.id == "edit" then
    if not id then return end
    if view.edit ~= id or not view.drafted then view.draft, view.drafted = S.copy(S.points[S.find(id)]), false end
    view.edit, view.selected, view.editing, view.testing, view.found = id, id, true, false, nil
    return
  end
  if ev.id == "save" then
    if not view.edit then return end
    local saved = view.edit
    local ok, err = S.edit(saved, S.draftOf(view))
    if not ok then S.message = S.errText[err] or tostring(err) return end
    S.message, view.drafted, view.selected = "point saved", false, saved
    return
  end
  -- BACK and CANCEL drop an unanswered FACING prompt.
  if ev.id == "facing-cancel" then S.compass = nil return end
  if ev.id == "list" then
    if not view.editing then S.compass = nil end
    view.editing, view.testing, view.found = false, view.editing and view.found or false, nil return
  end
  if ev.id == "testing" then view.editing, view.testing = false, true return end
  if ev.id == "room-sink" then
    local ok,err = S.setRoomSink(not S.roomSink)
    S.message = ok and "room saved" or tostring(err)
    return
  end
  local d = (ev.id == "room-point" or ev.id == "kind" or ev.id == "side" or ev.id == "add" or S.nudge[ev.id])
    and S.draftOf(view)
  if ev.id == "room-point" then
    if d.kind == "ore" or d.kind == "wood" then d.room, view.drafted = not d.room or nil, true
    else S.message = "room needs ore or wood" end
    return
  end
  local facing=tonumber(ev.id:match("^facing:([0-3])$"))
  if facing and S.compass then local pick=S.compass S.beginSetup(pick.id,pick.point,facing) return end
  if ev.id == "test" then if S.selectedPoint(view) then S.testPoint(S.selectedPoint(view), view.turtle) end return end
  if ev.id == "release" and S.task then S.releaseSetup(S.task.id) return end
  local scan=ev.id:match("^scan:(%d+)$")
  if scan then S.beginSetup(tonumber(scan)) return end
  local candidate=tonumber(ev.id:match("^candidate:(%d+)$"))
  if candidate and S.candidates[candidate] then
    local p=S.candidates[candidate]
    -- The chest opens with the kind of this display's last draft.
    view.draft,view.drafted,view.edit={dim=p.dim,x=p.x,y=p.y,z=p.z,side=p.side,kind=view.draft and view.draft.kind or "ore"},true,nil
    view.testing,view.editing,view.found=false,true,true return
  end
  if not U and (ev.id == "prev" or ev.id == "next") then
    view.page = math.max(1, math.min(view.pages, view.page + (ev.id == "next" and 1 or -1)))
    return
  end
  if ev.id == "next" then view.page = view.page + 1 return end
  if ev.id == "prev" then view.page = math.max(1, view.page-1) return end
  if ev.id == "from-next" then view.fromPage = (view.fromPage or 0)+1 return end
  local from = ev.id:match("^from:(%d+)$")
  if from then S.fromTurtle(tonumber(from), view) return end
  local focused = ev.id:match("^focus:(.+)$")
  if focused and S.find(focused) then
    if not S.shown(view,S.points[S.find(focused)]) then view.dim=nil end
    view.editing,view.testing,view.selected,view.focus=false,false,focused,focused return
  end
  if ev.id == "dims" then
    local at = 1
    for i, f in ipairs(S.filters) do if f[2] == view.dim then at = i end end
    view.dim = S.filters[at % #S.filters + 1][2]
    return
  end
  local turtle = tonumber(ev.id:match("^turtle:(%d+)$"))
  if turtle then view.turtle = view.turtle ~= turtle and turtle or nil return end
  if ev.id == "preview-kind" then
    local at, kind = 1, S.previewKind(view)
    for i, k in ipairs(S.kindOrder) do if k == kind then at = i end end
    view.previewKind = S.kindOrder[at % #S.kindOrder + 1]
    return
  end
  local selected = ev.id:match("^select:(.+)$")
  if selected and S.find(selected) then view.selected = selected return end
  local fixId = ev.id:match("^fix:(.+)$")
  if fixId then S.fix(fixId) return end
  if ev.id == "kind" then
    local at = 1
    for i = 1, #S.kindOrder do
      if S.kindOrder[i] == d.kind then at = i end
    end
    d.kind, view.drafted = S.kindOrder[at % #S.kindOrder + 1], true
    if d.kind ~= "ore" and d.kind ~= "wood" then d.room = nil end
    return
  end
  if ev.id == "side" then
    if d.side == "front" then d.side = "down" else d.side = "front" end
    view.drafted = true
    return
  end
  if ev.id == "add" then
    -- The tapped ADD says when the draft is a point that already exists; typed add stays as it was.
    S.addDraft(view, true)
    return
  end
  local step = S.nudge[ev.id]
  if not step then return end
  d[step[1]] = d[step[1]] + step[2]
  view.drafted = true
end

S.tick = function()
  -- A draft with no input for five minutes is dropped unsaved, and its display goes back to the list.
  local now = SO.now()
  if S.queueBusy() then
    if not SO.pair or not SO.pair.key(S.queue.workerId) then S.stopQueue("worker forgotten") end
    if S.task and S.task.queued then
      local point, why = S.queuePoint(S.queue.current, S.task.inspected)
      if not point then
        S.task.failed = true
        S.stopQueue(why)
      end
    end
    S.advanceQueue()
  end
  for _, view in pairs(S.views) do
    if (view.draft or view.editing) and now - (view.touched or now) >= S.idle then
      view.draft, view.drafted, view.edit, view.editing, view.found = nil, false, nil, false, nil
    end
  end
  if not S.callback and SO.mods.lease and SO.mods.lease.onReport then
    SO.mods.lease.onReport("setup",S.setupReport) S.callback=true
  end
  if S.wired then return end
  local display = SO.mods.display
  if type(display) ~= "table" or type(display.screen) ~= "function" then return end
  display.screen("generic", S.render, S.input)
  S.wired = true
end

S.blocked = not S.preflight()
S.data = {points = {}}
S.publishFound({})
if not S.blocked then
  local ok, box = pcall(SO.store.store, "so-drops", S.valid, 65536)
  if ok then S.box = box else S.blocked = true end
end
if S.blocked then S.message = "drops unreadable"
elseif S.box.value then
  S.data = S.box.value
  S.points = S.clone(S.data.points)
  S.roomSink = S.data.roomSink == true
  S.publishFound(S.data.candidates or {})
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
      out[i].n = i
    end
    return out
  end,
  pick = S.pick,
  choose = S.choose,
  usable = S.usable,
  steps = S.steps,
  add = S.add,
  remove = S.remove,
  fix = S.fix,
  note = S.note,
  roomMark = S.roomMark,
  roomSink = S.setRoomSink,
  forget = S.forget,
  busy = function(id) return S.task and S.task.id == id or S.releasing and S.releasing.id == id end,
}
