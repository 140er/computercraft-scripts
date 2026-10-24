-- worker.lua - runs lease steps and does not choose a path.

local C = {
  max = 32,
  pause = 0.05,
  fastN = 12,
  fastGap = 5000,
  fastWindow = 60000,
  slowGap = 30000,
  moves = { forward = true, back = true, up = true, down = true, turnLeft = true, turnRight = true },
  digs = { dig = "forward", digUp = "up", digDown = "down" },
  rev = { forward = "back", back = "forward", up = "down", down = "up", turnLeft = "turnRight", turnRight = "turnLeft" },
  dx = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 },
  dz = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 },
  tags = { "c:ores", "forge:ores", "minecraft:logs", "minecraft:leaves",
    "minecraft:saplings", "minecraft:dirt", "c:chests", "forge:chests" },
  transfers = { drop = "front", dropUp = "top", dropDown = "bottom",
    suck = "front", suckUp = "top", suckDown = "bottom" },
  counted = { refuel = true, drop = true, dropUp = true, dropDown = true, suck = true, suckUp = true, suckDown = true },
  discard = { front = { "front", "inspect", "drop" }, up = { "top", "inspectUp", "dropUp" },
    down = { "bottom", "inspectDown", "dropDown" } },
}

local W = {}
W.now = function() return math.floor(os.clock() * 1000 + 0.5) end

W.proto = dofile("so-proto.lua")
W.pair = dofile("so-pair.lua")

W.valid = function(v)
  return type(v) == "table" and type(v.id) == "string" and type(v.moves) == "table"
end

W.key = function(x, y, z)
  return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

W.cell = function(dir)
  local p = W.pose
  if dir == "up" then return p.x, p.y + 1, p.z end
  if dir == "down" then return p.x, p.y - 1, p.z end
  local f = p.f
  if dir == "back" then f = (f + 2) % 4 end
  return p.x + C.dx[f], p.y, p.z + C.dz[f]
end

W.apply = function(op)
  local p = W.pose
  if op == "turnLeft" then
    p.f = (p.f + 3) % 4
  elseif op == "turnRight" then
    p.f = (p.f + 1) % 4
  elseif op == "forward" or op == "back" or op == "up" or op == "down" then
    local x, y, z = W.cell(op)
    p.x, p.y, p.z = x, y, z
  end
end

W.noteDug = function(x, y, z)
  local list = W.journal.dug
  list[#list + 1] = { x = x, y = y, z = z }
  while #list > C.max do table.remove(list, 1) end
  W.dug = {}
  for i = 1, #list do
    local d = list[i]
    W.dug[W.key(d.x, d.y, d.z)] = true
  end
end

W.save = function()
  local p = W.pose
  W.journal.pose = { x = p.x, y = p.y, z = p.z, f = p.f }
  if W.journal.dim == "minecraft:overworld" then W.journal.dim=nil end
  local ok, err = W.box.save(W.journal)
  if not ok then print("worker: journal " .. tostring(err)) end
  return ok
end

W.load = function()
  local saved = W.box.value
  if type(saved) ~= "table" then
    W.journal = {
      id = tostring(os.getComputerID()) .. "-0",
      seq = 0, dim = W.dimension() ~= "minecraft:overworld" and W.dimension() or nil,
      pose = { x = 0, y = 0, z = 0, f = 0 },
      moves = {},
      dug = {},
    }
  else
    W.journal = saved
    if type(W.journal.moves) ~= "table" then W.journal.moves = {} end
    if type(W.journal.dug) ~= "table" then W.journal.dug = {} end
    if type(W.journal.id) ~= "string" then
      W.journal.id = tostring(os.getComputerID()) .. "-0"
    end
    if type(W.journal.seq) ~= "number" then W.journal.seq = 0 end
  end
  local p = W.journal.pose
  if type(p) ~= "table" then p = {} end
  W.pose = {
    x = type(p.x) == "number" and p.x or 0,
    y = type(p.y) == "number" and p.y or 0,
    z = type(p.z) == "number" and p.z or 0,
    f = type(p.f) == "number" and p.f or 0,
  }
  W.dug = {}
  for i = 1, #W.journal.dug do
    local d = W.journal.dug[i]
    if type(d) == "table" then W.dug[W.key(d.x, d.y, d.z)] = true end
  end
end

W.bump = function()
  local j = W.journal
  j.seq = (j.seq or 0) + 1
  j.id = tostring(os.getComputerID()) .. "-" .. tostring(j.seq)
end

-- Saved before the turtle call so a reboot still shows this step.
W.markPending = function(op)
  W.bump()
  W.journal.pending = { n = W.journal.seq, op = op, lease = W.lease }
  if C.moves[op] and op ~= "turnLeft" and op ~= "turnRight" then
    W.journal.pending.fuel = W.fuelRaw()
    if W.journal.pending.fuel == "unlimited" then W.journal.pending.gps = W.gpsFix() end
  end
  return W.save()
end

W.pushMove = function(op)
  local moves = W.journal.moves
  moves[#moves + 1] = { n = W.journal.seq, op = op, ok = true }
  while #moves > C.max do table.remove(moves, 1) end
end

W.fuelRaw = function()
  return turtle.getFuelLevel()
end

W.fuelBody = function()
  local fuel = W.fuelRaw()
  if fuel == "unlimited" or type(fuel) == "number" then return fuel end
  return 0
end

W.fuelBeacon = function()
  local fuel = W.fuelRaw()
  if type(fuel) == "number" then return fuel end
  return -1
end

W.free = function()
  local n = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then n = n + 1 end
  end
  return n
end

W.inv = function()
  local items = {}
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if type(detail) == "table" and type(detail.count) == "number" and detail.count > 0 then
      items[#items + 1] = { slot = slot, name = detail.name, count = detail.count }
    end
  end
  return items
end

W.isTool = function(name)
  return type(name) == "string" and (name:match("_pickaxe$") or name:match("_axe$")
    or name:match("_shovel$") or name:match("_hoe$") or name:match("_sword$")) ~= nil
end

W.tools = function()
  if type(turtle.getEquippedLeft) ~= "function" or type(turtle.getEquippedRight) ~= "function" then return nil end
  local left, right = turtle.getEquippedLeft(), turtle.getEquippedRight()
  return { left = left and left.name or false, right = right and right.name or false }
end

W.tool = function(step)
  local tools = W.tools()
  local kind = step.kind
  if kind ~= "pickaxe" and kind ~= "axe" then return false, "bad tool" end
  if not tools then return false, "tools unknown" end
  for _, name in pairs(tools) do
    if type(name) == "string" and name:match("_" .. kind .. "$") then return true end
  end
  if not W.autoToolSwap then return false, "tool swaps disabled" end
  local slot
  for _, item in ipairs(W.inv()) do
    if item.name:match("_" .. kind .. "$") and item.count == 1 then slot = item.slot break end
  end
  if not slot then return false, "needs " .. kind end
  local side
  for _, candidate in ipairs({ "left", "right" }) do
    if tools[candidate] == false or W.isTool(tools[candidate]) then side = candidate break end
  end
  if not side then return false, "no tool side free" end
  local selected = turtle.getSelectedSlot()
  if not turtle.select(slot) then return false, "tool slot unavailable" end
  local ok, err = turtle[side == "left" and "equipLeft" or "equipRight"]()
  turtle.select(selected)
  return ok, err
end

W.counts = function()
  local counts = {}
  for slot = 1, 16 do counts[slot] = turtle.getItemCount(slot) end
  return counts
end

W.dimension = function()
  local config = W.store.read("so-worker.cfg")
  return type(config) == "table" and config.dim or nil
end

W.checkDimension = function()
  local j, dim = W.journal, W.dimension() or "minecraft:overworld"
  if (j.dim or "minecraft:overworld") == dim or j.dimensionChanged then return end
  if j.seq == 0 and #j.moves == 0 and #j.dug == 0 and not j.pending then
    j.dim=dim ~= "minecraft:overworld" and dim or nil return
  end
  j.uncertain, j.dimensionChanged = true, true
  j.recovery = {outcome="dimension changed"}
  W.save()
end

W.gpsFix = function()
  if W.locating or type(gps) ~= "table" or type(gps.locate) ~= "function" then return nil end
  W.locating = true
  local lookup = coroutine.create(gps.locate)
  local result = table.pack(coroutine.resume(lookup, 2))
  while result[1] and coroutine.status(lookup) ~= "dead" do
    local event = table.pack(os.pullEvent())
    if event[1] == "rednet_message" and event[4] == "so" then W.accept(event[2], event[3]) end
    if not result[2] or result[2] == event[1] then
      result = table.pack(coroutine.resume(lookup, table.unpack(event, 1, event.n)))
    end
  end
  W.locating = nil
  local ok, x, y, z = table.unpack(result, 1, result.n)
  if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
    return nil
  end
  local fix = { x = x, y = y, z = z }
  local config = W.store.read("so-worker.cfg")
  if type(config) == "table" and type(config.dim) == "string"
    and config.dim:match("^[%w_]+:[%w_./%-]+$") then fix.dim = config.dim end
  return fix
end

W.resolvePending = function()
  if W.journal.dimensionChanged then return end
  local pending = W.journal.pending
  if not pending or not C.moves[pending.op] then return end
  local moved
  if pending.op ~= "turnLeft" and pending.op ~= "turnRight" then
    local fuel = W.fuelRaw()
    if type(fuel) == "number" and type(pending.fuel) == "number" then
      if fuel == pending.fuel then moved = false
      elseif fuel == pending.fuel - 1 then moved = true end
    elseif type(pending.gps) == "table" then
      local fix, before = W.gpsFix(), pending.gps
      if fix and (fix.dim == before.dim) and (fix.dim == "minecraft:overworld" or fix.dim == nil) then
        local dx, dy, dz = fix.x-before.x, fix.y-before.y, fix.z-before.z
        if dx == 0 and dy == 0 and dz == 0 then moved = false
        elseif pending.op == "up" and dx == 0 and dy == 1 and dz == 0 then moved = true
        elseif pending.op == "down" and dx == 0 and dy == -1 and dz == 0 then moved = true
        elseif (pending.op == "forward" or pending.op == "back") and dy == 0
          and ((math.abs(dx) == 1 and dz == 0) or (dx == 0 and math.abs(dz) == 1)) then moved = true end
      end
    end
  end
  W.journal.recovery = { n = pending.n, op = pending.op,
    outcome = moved == nil and "uncertain" or moved and "applied" or "not applied" }
  W.journal.uncertain = moved == nil or nil
  if moved ~= nil then
    if moved then W.apply(pending.op) W.pushMove(pending.op) end
    W.journal.pending = nil
  end
  W.save()
end

W.hello = function()
  W.checkDimension()
  local key = W.pair.key(W.server)
  if not key then return end
  local where = W.gpsFix()
  local body = {
    role = "turtle",
    capabilities = { parkBatch = true, setupFence = true, dimensionSafety = true, autoToolSwap = W.autoToolSwap or nil },
    tools = W.tools(),
    dim = W.dimension(),
    fuel = W.fuelBody(),
    free = W.free(),
    inv = W.inv(),
    journal = W.journal,
  }
  local label = os.getComputerLabel()
  if type(label) == "string" and #label > 0 then body.label = label end
  if where then body.gps = where end
  W.transmit(W.server, W.proto.build(key, "hello", body))
  W.lastHello = W.now()
end

W.beacon = function()
  local key = W.pair.key(W.server)
  if not key then return end
  W.transmit(nil, W.proto.build(key, "beacon", {
    id = os.getComputerID(),
    fuel = W.fuelBeacon(),
    journal = W.journal.id,
    pose = not W.journal.uncertain and { x = W.pose.x, y = W.pose.y, z = W.pose.z, f = W.pose.f } or nil,
    uncertain = W.journal.uncertain,
  }))
end

W.report = function(results)
  W.checkDimension()
  local key = W.pair.key(W.server)
  if not key then return end
  local msg = W.proto.build(key, "step.report", {
    lease = W.lease, results = results, capabilities = { parkBatch = true, setupFence = true, dimensionSafety = true, autoToolSwap = W.autoToolSwap or nil },
    tools = W.tools(),
    dim = W.dimension(),
    pose = not W.journal.uncertain and { x = W.pose.x, y = W.pose.y, z = W.pose.z, f = W.pose.f } or nil,
    uncertain = W.journal.uncertain,
    journal = W.journal.id, fuel = W.fuelBeacon(), inv = W.inv(), dug = W.journal.dug,
  })
  while not W.proto.encode(msg) do
    local longest, selected
    for _, result in ipairs(results) do
      local tags = result.data and result.data.tags
      for tag in pairs(tags or {}) do
        if (tag:match("^c:ores/") or tag:match("^forge:ores/"))
          and (not longest or #tag > #longest) then longest, selected = tag, tags end
      end
    end
    if not selected then break end
    selected[longest] = nil
  end
  msg.mac = W.proto.sign(key, msg)
  W.transmit(W.server, msg)
end

W.transmit = function(id, msg)
  local wire = W.proto.encode(msg)
  if not wire then return end
  if id then rednet.send(id, wire, "so") else rednet.broadcast(wire, "so") end
end

W.paint = function()
  local age = W.seen and math.max(0, math.floor((W.now() - W.seen) / 1000))
  local seen = age and (age < 60 and age .. "s ago" or math.floor(age / 60) .. "m ago") or "-"
  term.clear()
  term.setCursorPos(1, 1)
  term.write((os.getComputerLabel() or ("turtle " .. os.getComputerID())):sub(1, 32))
  term.setCursorPos(1, 2)
  term.write(W.job and (W.job .. " " .. (W.stepName or "idle")) or ("step " .. (W.stepName or "-")))
  term.setCursorPos(1, 3)
  term.write("fuel " .. tostring(W.fuelRaw()))
  term.setCursorPos(1, 4)
  local width = term.getSize()
  term.write((W.reason or ("seen " .. seen)):sub(1, width))
  term.setCursorPos(1, 5)
  term.write(age and age < 60 and ("server " .. W.server .. " ok") or "waiting for server")
  if W.repair then
    term.setCursorPos(1, 6)
    term.write("Key changed? Old key kept.")
    term.setCursorPos(1, 7)
    term.write("Press P on server. Code: " .. (W.codeText or ""))
    term.setCursorPos(1, 8)
    term.write(W.pairError or "Type 6 digits, then Enter")
  end
  if W.journal.uncertain then
    term.setCursorPos(1, 5)
    term.write("pose uncertain: re-add turtle " .. os.getComputerID())
  end
end

W.reanchor = function(body)
  if type(body) ~= "table" then return end
  local recovered = W.journal.recovery
  if not W.journal.uncertain and type(recovered) == "table" and recovered.outcome == "anchored"
    and recovered.journal == body.journal then W.hello() return end
  if not W.journal.uncertain or body.journal ~= W.journal.id then return end
  local p = body.pose
  if type(p) ~= "table" then return end
  for _, field in ipairs({ "x", "y", "z", "f" }) do
    local n = p[field]
    if type(n) ~= "number" or n ~= n or n % 1 ~= 0 or math.abs(n) >= 30000000 then return end
  end
  if p.f < 0 or p.f > 3 then return end
  local old, pose = W.journal, W.pose
  W.pose = { x = p.x, y = p.y, z = p.z, f = p.f }
  W.journal = { seq = old.seq, dim = W.dimension() ~= "minecraft:overworld" and W.dimension() or nil, moves = {}, dug = {}, park = true,
    recovery = { outcome = "anchored", journal = old.id } }
  W.bump()
  if not W.save() then W.journal, W.pose = old, pose return end
  W.dug, W.queued, W.expires, W.lease = {}, nil, nil, nil
  W.mode, W.stepName = "idle", "idle"
  W.hello()
end

W.accept = function(sender, payload)
  if sender ~= W.server then return end
  if W.pair.repairHint(sender, payload, W.server) then
    W.repair = true
    W.paint()
    return
  end
  local msg = W.proto.decode(payload)
  if not msg or msg.from ~= sender then return end
  local key = W.pair.key(W.server)
  if not key or not W.proto.macOk(key, msg) then return end
  if not W.proto.fresh(msg) then return end
  W.repair, W.codeText, W.pairError = nil, nil, nil
  W.seen = W.now()
  if msg.t == "worker.status" then
    if type(msg.body.job) == "string" and type(msg.body.reason) == "string" then
      W.job, W.reason = msg.body.job:sub(1, 16), msg.body.reason:sub(1, 48)
    end
  elseif msg.t == "worker.anchor" then W.reanchor(msg.body)
  elseif msg.t == "lease.batch" then
    local body = msg.body
    if type(body) ~= "table" then return end
    local ttl = body.ttl
    msg.legacyExpires = ttl == nil and body.expires or nil
    if ttl == nil and type(body.expires) == "number" then ttl = math.max(0, body.expires - os.epoch("utc")) end
    if type(ttl) ~= "number" or ttl ~= ttl or ttl < 0 or ttl == math.huge then return end
    msg.deadline = W.now() + ttl
    if W.queued and W.queued.body.lease == body.lease and W.queued.legacyExpires == msg.legacyExpires then
      msg.deadline = math.min(msg.deadline, W.queued.deadline)
    end
    W.queued = msg
  end
end

W.breathe = function(seconds)
  local id = os.startTimer(seconds)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == "so" then
      W.accept(a, b)
      if W.queued then
        os.cancelTimer(id)
        return
      end
    elseif W.repair and (ev == "char" or ev == "paste") then
      W.codeText = ((W.codeText or "") .. tostring(a):gsub("%D", "")):sub(1, 6)
      W.paint()
    elseif W.repair and ev == "key" and (a == 259 or a == 14) then
      W.codeText = (W.codeText or ""):sub(1, -2)
      W.paint()
    elseif W.repair and ev == "key" and (a == 257 or a == 28) and #(W.codeText or "") == 6 then
      os.cancelTimer(id)
      local ok, err = W.pair.join(W.codeText, W.server)
      id = os.startTimer(seconds)
      W.codeText = ""
      if ok then
        W.repair, W.pairError = nil, nil
        W.hello()
      else
        W.pairError = "Pair failed: " .. tostring(err)
      end
      W.paint()
    elseif ev == "timer" and a == id then
      return
    end
  end
end

W.discard = function(step)
  local side = C.discard[step.side or "down"]
  if not side then return false, "bad side" end
  if peripheral.hasType(side[1], "inventory") then return false, "inventory present" end
  local exists, block = turtle[side[2]]()
  if exists ~= true and (exists ~= false or block ~= "No block to inspect") then
    return false, "cell unknown"
  end
  if exists and (type(block) ~= "table" or (block.name ~= "minecraft:air"
    and block.name ~= "minecraft:cave_air" and block.name ~= "minecraft:void_air")) then
    return false, "cell occupied"
  end
  return turtle[side[3]](step.n)
end

W.safeMove = function(step)
  local dim, guard = W.dimension(), step.safety
  if not guard and (dim == nil or dim == "minecraft:overworld") then return end
  if type(guard) ~= "table" or guard.dim ~= dim then return "remote safety: dimension mismatch" end
  local bounds = ({["minecraft:the_nether"]={1,126}, ["minecraft:the_end"]={1,255}})[dim]
  if not bounds or type(guard.y) ~= "number" or guard.y ~= guard.y or guard.y%1 ~= 0 then
    return "remote safety: invalid height"
  end
  if guard.y < bounds[1] or guard.y > bounds[2] then
    return dim == "minecraft:the_nether" and "remote safety: Nether bedrock boundary" or "remote safety: End void boundary"
  end
  if dim == "minecraft:the_nether" then
    for _,field in ipairs({"x","z","facing"}) do
      local n=guard[field]
      if type(n)~="number" or n~=n or n%1~=0 or math.abs(n)>=30000000 then return "remote safety: invalid position" end
    end
    if guard.facing<0 or guard.facing>3 then return "remote safety: invalid facing" end
  end
  local inspect = ({forward="inspect",up="inspectUp",down="inspectDown"})[step.op]
  if not inspect then return "remote safety: reverse move requires inspection" end
  local exists, block = turtle[inspect]()
  if exists then
    if type(block) ~= "table" or type(block.name) ~= "string" then return "remote safety: cell unknown" end
    if block.name == "minecraft:lava" and dim=="minecraft:the_nether" then
      return string.format("remote safety: lava at %d,%d,%d",guard.x,guard.y,guard.z)
    end
    if block.name == "minecraft:lava" or block.name == "minecraft:water" or block.name == "minecraft:bubble_column" then
      return "remote safety: " .. block.name:gsub("^minecraft:", "")
    end
  elseif exists ~= false or block ~= "No block to inspect" then return "remote safety: cell unknown" end
end

W.scanNether = function(guard)
  local hazard
  local function inspect(op,x,y,z)
    local exists,block=turtle[op]()
    if exists and type(block)=="table" and block.name=="minecraft:lava" then
      hazard=string.format("remote safety: lava at %d,%d,%d",x,y,z)
    elseif exists and (type(block)~="table" or type(block.name)~="string")
      or not exists and (exists~=false or block~="No block to inspect") then
      hazard="remote safety: surroundings unknown"
    end
  end
  inspect("inspectUp",guard.x,guard.y+1,guard.z)
  if not hazard then inspect("inspectDown",guard.x,guard.y-1,guard.z) end
  for turn=0,3 do
    if not hazard then
      local f=(guard.facing+turn)%4
      inspect("inspect",guard.x+C.dx[f],guard.y,guard.z+C.dz[f])
    end
    if hazard and turn==0 then return hazard end
    if not W.markPending("turnRight") then
      W.journal.uncertain=true return "remote safety: surroundings journal failed"
    end
    local result=W.exec({op="turnRight"})
    if not result.ok then W.journal.uncertain=true return "remote safety: surroundings turn failed" end
    W.journal.pending=nil
    if not W.save() then W.journal.uncertain=true return "remote safety: surroundings journal failed" end
  end
  return hazard
end

W.exec = function(step)
  local result = { ok = false, counts = W.counts() }
  if type(step) ~= "table" or type(step.op) ~= "string" then
    result.err = "bad op"
    return result
  end
  local op = step.op
  if op == "forward" or op == "back" or op == "up" or op == "down" then
    local hazard = W.safeMove(step)
    if hazard then result.err=hazard return result end
  end
  if op == "gps" then
    local fix = W.gpsFix()
    result.ok, result.data, result.err = fix ~= nil, fix, not fix and "no GPS" or nil
    return result
  end
  if op == "tool" then
    result.ok, result.err = W.tool(step)
    result.ok = result.ok == true
    if result.ok then result.err = nil end
    return result
  end
  if op == "equipLeft" or op == "equipRight" then result.err = "use tool step" return result end
  if op == "discard" or op == "drop" or op == "dropUp" or op == "dropDown" or op == "refuel" then
    local item = turtle.getItemDetail()
    if item and W.isTool(item.name) then result.err = "tool kept" return result end
  end
  local fn = op == "discard" and function() return W.discard(step) end or turtle[op]
  if type(fn) ~= "function" then
    result.err = "bad op"
    return result
  end
  local side = C.transfers[op]
  if side and not peripheral.hasType(side, "inventory") then
    result.err = "no inventory"
    return result
  end
  local ok, info
  if op == "select" then
    ok, info = turtle.select(step.slot)
  elseif C.counted[op] then
    ok, info = fn(step.n)
  else
    ok, info = fn()
  end
  result.ok = ok == true
  if result.ok then
    if type(info) == "table" and type(info.name) == "string" then
      result.data = { name = info.name }
      if type(info.tags) == "table" then
        local tags, n = {}, 0
        for _, tag in ipairs(C.tags) do
          if info.tags[tag] == true then tags[tag], n = true, n + 1 end
        end
        for tag, present in pairs(info.tags) do
          if present == true and type(tag) == "string" and n < 8
            and (tag:match("^c:ores/") or tag:match("^forge:ores/")) then
            tags[tag], n = true, n + 1
          end
        end
        if n > 0 then result.data.tags = tags end
      end
      if type(info.state) == "table" and type(info.state.level) == "number" then
        result.data.level = info.state.level
      end
    end
    if C.moves[op] then
      W.apply(op)
      W.pushMove(op)
      if step.safety and step.safety.dim=="minecraft:the_nether" then
        W.journal.pending=nil
        if W.save() then result.hazard=W.scanNether(step.safety)
        else
          W.journal.uncertain=true
          result.hazard="remote safety: movement journal failed"
        end
      end
    elseif C.digs[op] then
      local x, y, z = W.cell(C.digs[op])
      W.noteDug(x, y, z)
    end
  elseif type(info) == "string" then
    result.err = info
  else
    result.err = "failed"
  end
  result.counts = W.counts()
  return result
end

W.refuse = function(results, from, n)
  W.journal.pending = nil
  W.save()
  for j = from, n do
    results[j] = { ok = false, err = "expired", counts = W.counts() }
  end
end

W.startBatch = function(msg)
  W.checkDimension()
  local body = msg.body
  if type(body) ~= "table" or type(body.lease) ~= "string" then return end
  if type(body.expires) ~= "number" or type(body.steps) ~= "table" then return end
  local n = #body.steps
  if n < 1 or n > 16 then return end
  if W.journal.uncertain then
    W.lease = body.lease
    local results = {}
    for i = 1, n do results[i] = { ok = false, err = "pose uncertain", counts = W.counts() } end
    W.report(results)
    W.enterSlow()
    return
  end
  if body.journal ~= nil and body.journal ~= W.journal.id then
    W.lease = body.lease
    local results = {}
    for i=1,n do results[i]={ok=false,err="journal changed"} end
    W.report(results)
    return
  end
  W.journal.park = type(body.steps[1]) == "table" and (body.steps[1].park == true or body.steps[1].op == "tool"
    or n == 1 and body.steps[1].op == "inspectDown")
  W.mode = "idle"
  local deadline = msg.deadline
  if W.lease == body.lease and W.legacyExpires == msg.legacyExpires and W.expires then
    deadline = math.min(deadline, W.expires)
  end
  W.lease, W.expires, W.legacyExpires = body.lease, deadline, msg.legacyExpires
  local results, safetyStop = {}, false
  for i = 1, n do
    if W.now() >= W.expires then
      W.refuse(results, i, n)
      break
    end
    local step = body.steps[i]
    local op = "?"
    if type(step) == "table" and type(step.op) == "string" then op = step.op end
    W.stepName = op
    W.paint()
    local saved = W.markPending(op)
    if op == "tool" and not saved then
      results[i] = {ok=false,err="tool journal save failed",counts=W.counts()}
      for j = i+1, n do results[j] = {ok=false,err="tool journal save failed",counts=W.counts()} end
      W.journal.pending = nil
      break
    end
    if body.journal ~= nil and not saved then
      W.refuse(results,i,n)
      break
    end
    W.breathe(C.pause)
    if W.now() >= W.expires then
      W.refuse(results, i, n)
      break
    end
    results[i] = W.exec(step)
    if results[i].hazard or not results[i].ok and (type(results[i].err)=="string" and results[i].err:match("^remote safety:")
      or type(step)=="table" and step.safety and C.moves[op]) then
      local hazard=results[i].hazard or results[i].err
      if not hazard:match("^remote safety:") then hazard="remote safety: "..hazard results[i].err=hazard end
      for j=i+1,n do results[j]={ok=false,err=hazard,counts=W.counts()} end
      if not W.journal.uncertain then W.journal.pending=nil end
      W.journal.park,safetyStop=true,true
      W.save()
      break
    end
    W.journal.pending = nil
    W.save()
  end
  W.report(results)
  if safetyStop then W.queued=nil W.enterSlow() return end
  if W.queued then
    W.mode = "idle"
    W.stepName = "idle"
    W.paint()
    return
  end
  if W.expires and W.now() >= W.expires then
    W.enterFast()
  else
    W.mode = "idle"
    W.stepName = "idle"
    W.paint()
  end
end

W.enterFast = function()
  if W.journal.park or W.journal.uncertain or W.dimension() and W.dimension() ~= "minecraft:overworld" then
    W.enterSlow()
    W.beacon()
    return
  end
  local now = W.now()
  W.mode = "fast"
  W.stepName = "beacon"
  W.fastStart = now
  W.fastUntil = now + C.fastWindow
  W.fastSent = 1
  W.nextPing = now + C.fastGap
  W.beacon()
  W.paint()
end

W.enterSlow = function()
  W.mode = "slow"
  W.stepName = W.journal.uncertain and "pose uncertain" or "slow"
  W.nextPing = W.now() + C.slowGap
  W.paint()
end

W.digToward = function(dir)
  if dir == "up" then return turtle.digUp() end
  if dir == "down" then return turtle.digDown() end
  if dir == "forward" then return turtle.dig() end
  if dir ~= "back" then return false end
  turtle.turnLeft()
  turtle.turnLeft()
  local ok = turtle.dig()
  turtle.turnLeft()
  turtle.turnLeft()
  return ok
end

W.reverse = function(entry)
  local rev = C.rev[entry.op]
  if not rev then return true end
  local ok = turtle[rev]()
  if ok then
    W.apply(rev)
    return true
  end
  local x, y, z = W.cell(rev)
  if not W.dug[W.key(x, y, z)] then return false end
  W.digToward(rev)
  ok = turtle[rev]()
  if not ok then return false end
  W.apply(rev)
  return true
end

W.backOne = function()
  if W.dimension() and W.dimension() ~= "minecraft:overworld" then W.enterSlow() return end
  local moves = W.journal.moves
  if #moves == 0 then
    W.enterSlow()
    return
  end
  local entry = moves[#moves]
  if not W.reverse(entry) then
    W.enterSlow()
    return
  end
  table.remove(moves, #moves)
  W.bump()
  W.save()
end

W.arm = function()
  local now = W.now()
  local pause = C.pause
  if W.mode == "back" then return pause end
  if W.mode == "fast" then
    local left = (W.fastUntil - now) / 1000
    if W.fastSent < C.fastN then
      local gap = (W.nextPing - now) / 1000
      if left < gap then gap = left end
      if gap < pause then return pause end
      return gap
    end
    if left < pause then return pause end
    return left
  end
  if W.mode == "slow" then
    local gap = (W.nextPing - now) / 1000
    if gap < pause then return pause end
    return gap
  end
  if W.expires and W.expires > now then
    local gap = (W.expires - now) / 1000
    if gap < pause then return pause end
    if gap > 5 then return 5 end
    return gap
  end
  if W.expires and now >= W.expires then return pause end
  return 5
end

W.onWake = function()
  local now = W.now()
  if not W.lastHello or now - W.lastHello >= 30000 then W.hello() end
  if W.mode == "idle" then
    if W.expires and now >= W.expires then W.enterFast() end
    return
  end
  if W.mode == "fast" then
    if W.fastSent < C.fastN and now >= W.nextPing and now < W.fastUntil then
      W.beacon()
      W.fastSent = W.fastSent + 1
      W.nextPing = now + C.fastGap
    end
    if now >= W.fastUntil then
      W.mode = "back"
      W.stepName = "back"
      W.paint()
    end
    return
  end
  if W.mode == "back" then
    W.backOne()
    return
  end
  if W.mode == "slow" and now >= W.nextPing then
    W.beacon()
    W.nextPing = now + C.slowGap
  end
end

W.loop = function()
  while true do
    W.paint()
    if W.queued then
      local msg = W.queued
      W.queued = nil
      W.startBatch(msg)
    else
      W.breathe(W.arm())
      if not W.queued then W.onWake() end
    end
  end
end

W.readCode = function()
  if fs.exists("so-code") then
    local handle = fs.open("so-code", "r")
    if not handle then return nil end
    local text = handle.readAll()
    handle.close()
    if type(text) == "string" then return text:match("%d%d%d%d%d%d") end
    return nil
  end
  W.codeText = W.codeText or ""
  term.setCursorPos(1, 5)
  term.write("Code: " .. W.codeText)
  local timer = os.startTimer(2)
  while true do
    local ev, value = os.pullEvent()
    if ev == "timer" and value == timer then return nil end
    if ev == "char" or ev == "paste" then
      W.codeText = (W.codeText .. tostring(value):gsub("%D", "")):sub(1, 6)
    elseif ev == "key" and value == 259 then
      W.codeText = W.codeText:sub(1, -2)
    elseif ev == "key" and value == 257 and #W.codeText == 6 then
      os.cancelTimer(timer)
      local code = W.codeText
      W.codeText = ""
      return code
    end
    term.setCursorPos(1, 5)
    term.write("Code: " .. W.codeText .. " ")
  end
end

W.boot = function()
  if not turtle then
    print("worker: need a turtle")
    return
  end
  local modem = peripheral.find("modem")
  if not modem then
    print("worker: no modem")
    while not modem do
      sleep(2)
      modem = peripheral.find("modem")
    end
  end
  rednet.open(peripheral.getName(modem))
  local store = dofile("so-store.lua")
  W.store = store
  local config = store.read("so-worker.cfg")
  W.autoToolSwap = type(config) == "table" and config.autoToolSwap == true or false
  W.pair.open(W.proto, store, W.now)
  W.box = store.store("so-journal", W.valid, 16000)
  W.load()
  W.checkDimension()
  W.resolvePending()
  W.mode = "idle"
  W.stepName = "idle"
  local saved = W.pair.peer()
  local delay, code = 2, nil
  while true do
    local found = rednet.lookup("so", "server")
    W.server = type(found) == "number" and found or nil
    if saved then
      if not W.server or not W.pair.key(W.server) then W.server = saved end
      W.stepName = "waiting for server"
      W.paint()
      W.hello()
      W.breathe(delay)
      if W.seen then break end
      delay = math.min(delay * 2, 30)
    else
      W.paint()
      code = code or W.readCode()
      if W.server and code then
        if W.pair.join(code) then
          fs.delete("so-code")
          break
        end
        code = nil
      end
      if code or fs.exists("so-code") then sleep(2) end
    end
  end
  W.stepName = "idle"
  if W.journal.uncertain then W.enterSlow() end
  W.hello()
  W.paint()
  W.loop()
end

W.boot()
