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
  counted = { refuel = true, drop = true, dropDown = true, suck = true, suckDown = true },
}

local W = {}

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
  local ok, err = W.box.save(W.journal)
  if not ok then print("worker: journal " .. tostring(err)) end
end

W.load = function()
  local saved = W.box.value
  if type(saved) ~= "table" then
    W.journal = {
      id = tostring(os.getComputerID()) .. "-0",
      seq = 0,
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
  W.save()
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

W.counts = function()
  local counts = {}
  for slot = 1, 16 do counts[slot] = turtle.getItemCount(slot) end
  return counts
end

W.gpsFix = function()
  if type(gps) ~= "table" or type(gps.locate) ~= "function" then return nil end
  local ok, x, y, z = pcall(gps.locate, 2)
  if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
    return nil
  end
  return { x = x, y = y, z = z }
end

W.hello = function()
  local key = W.pair.key(W.server)
  if not key then return end
  local body = {
    role = "turtle",
    fuel = W.fuelBody(),
    free = W.free(),
    inv = W.inv(),
    journal = W.journal,
  }
  local label = os.getComputerLabel()
  if type(label) == "string" and #label > 0 then body.label = label end
  local where = W.gpsFix()
  if where then body.gps = where end
  W.transmit(W.server, W.proto.build(key, "hello", body))
end

W.beacon = function()
  local key = W.pair.key(W.server)
  if not key then return end
  W.transmit(nil, W.proto.build(key, "beacon", {
    id = os.getComputerID(),
    fuel = W.fuelBeacon(),
    journal = W.journal.id,
    pose = { x = W.pose.x, y = W.pose.y, z = W.pose.z, f = W.pose.f },
  }))
end

W.report = function(results)
  local key = W.pair.key(W.server)
  if not key then return end
  local msg = W.proto.build(key, "step.report", {
    lease = W.lease, results = results,
    pose = { x = W.pose.x, y = W.pose.y, z = W.pose.z, f = W.pose.f },
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
  local seen = W.seen and tostring(W.seen) or "-"
  term.clear()
  term.setCursorPos(1, 1)
  term.write("lease " .. (W.lease or "-"))
  term.setCursorPos(1, 2)
  term.write("step " .. (W.stepName or "-"))
  term.setCursorPos(1, 3)
  term.write("fuel " .. tostring(W.fuelRaw()))
  term.setCursorPos(1, 4)
  term.write("seen " .. seen)
end

W.accept = function(sender, payload)
  if sender ~= W.server then return end
  local msg = W.proto.decode(payload)
  if not msg or msg.from ~= sender then return end
  local key = W.pair.key(W.server)
  if not key or not W.proto.macOk(key, msg) then return end
  if not W.proto.fresh(msg) then return end
  W.seen = os.epoch("utc")
  if msg.t == "lease.batch" then W.queued = msg end
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
    elseif ev == "timer" and a == id then
      return
    end
  end
end

W.exec = function(step)
  local result = { ok = false, counts = W.counts() }
  if type(step) ~= "table" or type(step.op) ~= "string" then
    result.err = "bad op"
    return result
  end
  local op = step.op
  local fn = turtle[op]
  if type(fn) ~= "function" then
    result.err = "bad op"
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
  local body = msg.body
  if type(body) ~= "table" or type(body.lease) ~= "string" then return end
  if type(body.expires) ~= "number" or type(body.steps) ~= "table" then return end
  local n = #body.steps
  if n < 1 or n > 16 then return end
  W.mode = "idle"
  W.lease = body.lease
  W.expires = body.expires
  local results = {}
  for i = 1, n do
    if os.epoch("utc") >= W.expires then
      W.refuse(results, i, n)
      break
    end
    local step = body.steps[i]
    local op = "?"
    if type(step) == "table" and type(step.op) == "string" then op = step.op end
    W.stepName = tostring(i)
    W.paint()
    W.markPending(op)
    W.breathe(C.pause)
    if os.epoch("utc") >= W.expires then
      W.refuse(results, i, n)
      break
    end
    results[i] = W.exec(step)
    W.journal.pending = nil
    W.save()
  end
  W.report(results)
  if W.queued then
    W.mode = "idle"
    W.stepName = "idle"
    W.paint()
    return
  end
  if W.expires and os.epoch("utc") >= W.expires then
    W.enterFast()
  else
    W.mode = "idle"
    W.stepName = "idle"
    W.paint()
  end
end

W.enterFast = function()
  local now = os.epoch("utc")
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
  W.stepName = "slow"
  W.nextPing = os.epoch("utc") + C.slowGap
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
  local now = os.epoch("utc")
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
  local now = os.epoch("utc")
  if W.mode == "idle" then
    if not W.seen then W.hello() end
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
  if type(read) ~= "function" then return nil end
  term.setCursorPos(1, 5)
  term.write("Code: ")
  local line = read()
  if type(line) ~= "string" then return nil end
  return line:match("%d%d%d%d%d%d")
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
  W.pair.open(W.proto, store)
  W.box = store.store("so-journal", W.valid, 16000)
  W.load()
  W.mode = "idle"
  W.stepName = "idle"
  while true do
    W.server = rednet.lookup("so", "server")
    if type(W.server) ~= "number" then W.server = nil end
    if W.server and W.pair.key(W.server) then break end
    local code = W.readCode()
    if W.server and code then
      local ok = W.pair.join(code)
      if ok then
        fs.delete("so-code")
        break
      end
    end
    sleep(2)
  end
  W.hello()
  W.paint()
  W.loop()
end

W.boot()
