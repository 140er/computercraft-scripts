local PROTO = "fleet_test"
local DIM = "minecraft:overworld"
local id = os.getComputerID()
local A = dofile("atomic.lua")

local function report(lines)
  local result = { ok = true, booted = true, errors = textutils.empty_json_array, lines = lines,
    free = fs.getFreeSpace("/"), rx = 0 }
  local h = assert(fs.open("sandbox-result.json", "w"))
  h.write(textutils.serializeJSON(result))
  h.close()
end

local function framed(frame, x, conf)
  local absolute = frame == "abs"
  return { v = 1, frame = frame, yAbs = absolute, dim = DIM, x = x, y = 65, z = 0, h = 0,
    conf = conf, src = absolute and "gps" or "inherited", anchoredAt = absolute and os.epoch("utc") or 0 }
end

if id == 0 then
  local Dispatch = dofile("wh2-dispatch.lua")
  local config = { enabled = true, operators = { ["4"] = true },
    enrolledRoles = { ["1"] = "miner", ["2"] = "miner", ["3"] = "store" } }
  local state = { schema = 1, warehouse = { locationsRevision = 3, sites = {
    near = { kind = "drop", pose = { dim = DIM, x = 2, y = 65, z = 0, h = 1 }, side = "front" },
    far = { kind = "drop", pose = { dim = DIM, x = 40, y = 65, z = 0, h = 1 }, side = "front" },
    bay = { kind = "charge", pose = { dim = DIM, x = 1, y = 65, z = 2, h = 0 }, side = "top" },
  } } }
  local function poseOk(p)
    return type(p) == "table" and type(p.dim) == "string" and type(p.x) == "number"
      and type(p.y) == "number" and type(p.z) == "number"
  end
  local capacity = fs.getCapacity("/")
  local context = { epoch = 1, pose = poseOk, diskCapacity = capacity, config = config }
  local dispatch = Dispatch.open(config, poseOk)
  local store = A.store("fleet-sandbox.state", function(v)
    return type(v) == "table" and v.schema == 1 and type(v.warehouse) == "table"
  end, 300000)
  local function handleRpc(from, msg)
    context.now = os.epoch("utc")
    local result, hint = dispatch.run(state, from, { op = msg.op, body = msg.body }, context)
    if result and result.ok then assert(store.save(state)) end
    rednet.send(from, { kind = "rpc-reply", rid = msg.rid, result = result }, PROTO)
    if type(hint) == "table" then
      for peer = 1, 3 do
        rednet.send(peer, { kind = "hint", op = "wh2-changed",
          body = { wh2 = 1, topic = hint.topic, revision = hint.revision } }, PROTO)
      end
    end
  end
  local function pull(timeout)
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
      local timer = os.startTimer(math.min(0.2, deadline - os.clock()))
      while true do
        local event, sender, message, protocol = os.pullEvent()
        if event == "rednet_message" and protocol == PROTO and type(message) == "table" then
          if message.kind == "rpc" then handleRpc(sender, message)
          else return sender, message end
        elseif event == "timer" and sender == timer then break end
      end
    end
  end
  local function waitKind(kind, timeout)
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
      local _, message = pull(deadline - os.clock())
      if message and message.kind == kind then return message end
    end
    error("timeout waiting for " .. kind)
  end
  local function command(peer, name, extra)
    extra = extra or {}
    extra.kind, extra.name = "cmd", name
    rednet.send(peer, extra, PROTO)
    local deadline = os.clock() + 20
    while os.clock() < deadline do
      local sender, message = pull(deadline - os.clock())
      if sender == peer and message and (message.kind == "done" or message.kind == "fail") then
        assert(message.kind == "done", message.detail or "peer failed")
        return message
      end
    end
    error("timeout waiting for computer " .. peer)
  end
  rednet.broadcast({ kind = "go" }, PROTO)
  local seen = {}
  while not (seen[1] and seen[2] and seen[3] and seen[4]) do
    local hello = waitKind("hello", 20)
    seen[hello.peer] = true
  end
  for peer = 1, 3 do
    local row = command(peer, "refresh")
    assert(row.revision == 0 and row.fuelLow == 200 and row.offlineAutonomy == false)
  end
  command(1, "report", { frame = "abs", x = 0, conf = "certain" })
  command(2, "report", { frame = "abs", x = 8, conf = "certain" })
  command(3, "report", { frame = "f:3:legacy", x = 0, conf = "suspect" })
  local records = state.wh2.fleet.records
  assert(records["cc:1"].kind == "turtle" and records["cc:1"].pose.frame == "abs" and records["cc:1"].pose.h == 0)
  assert(records["cc:2"].pose.x == 8 and records["cc:3"].pose.frame == "f:3:legacy")
  assert(records["cc:3"].pose.conf == "suspect" and records["cc:1"].inventory.fullness == 1 / 16)
  local view = dofile("wh2-ar.lua").entries(records, os.epoch("utc"))
  local byId = {}
  for _, entry in ipairs(view) do byId[entry.id] = entry end
  assert(byId[1].x == 0 and byId[1].poseConfirmed and byId[3].x == nil and not byId[3].poseConfirmed)
  command(4, "patch")
  local revision = state.wh2.fleet.settings.revision
  for peer = 1, 3 do command(peer, "await", { revision = revision }) end
  local miner = command(1, "status")
  local other = command(2, "status")
  local storeBot = command(3, "status")
  assert(miner.fuelLow == 150 and miner.fuelTarget == 4000 and miner.returnHome == false)
  assert(other.fuelLow == 150 and other.fuelTarget == 2000 and other.returnHome == false)
  assert(storeBot.fuelLow == 150 and storeBot.returnHome == true and storeBot.fuelTarget == 2000)
  assert(command(1, "location").locationId == "near")
  local saved = A.read("fleet-sandbox.state")
  assert(saved.value.wh2.fleet.records["cc:1"].label == "Turtle 1")
  assert(saved.value.wh2.fleet.settings.computers["1"].fuelTarget == 4000)
  assert(saved.value.wh2.fleet.settings.roles.miner.returnHome == false)
  local secret = "test-secret-123456"
  local probe = dofile("ssot.lua").new(
    { schema = 1, chunks = {}, names = {}, poses = {}, moves = {}, clients = {}, rev = 0, seq = 0, epoch = 0 },
    { controllers = { ["1"] = secret }, wh2 = { enabled = true } },
    function() return os.epoch("utc") end, 1, function() return true end)
  local rejected = probe.handle(1, { v = 1, type = "ssot", op = "wh2-get", rid = "probe", boot = "1:1",
    counter = 1, secret = secret, expect = "ssot_reply", body = { wh2 = 1, topic = "settings" } })
  assert(rejected and rejected.ok == false and rejected.code == "incompatible")
  assert(dofile("wh2-program.lua").run("panel.lua") == false)
  assert(capacity == 1000000 and fs.getFreeSpace("/") > 65536)
  for peer = 1, 4 do command(peer, "finish") end
  report({ "3 turtles reported; global < role < computer; near dropoff; v1 wh2 rejected; disk 1000000" })
  return
end

local deadline = os.clock() + 20
local started = false
while not started do
  local _, msg = rednet.receive(PROTO, 20)
  if msg and msg.kind == "go" then started = true end
  if os.clock() > deadline then error("server did not start the fleet scenario") end
end

local role = id == 3 and "store" or id == 4 and "other" or "miner"
if id <= 3 then
  _G.turtle = {
    getFuelLevel = function() return 1800 end,
    getFuelLimit = function() return 20000 end,
    getItemCount = function(slot) return slot == 1 and 1 or 0 end,
  }
end
local Client = dofile("wh2-client.lua")
local deferred = {}
local function rpcCall(op, fields)
  local rid = tostring(os.epoch("utc")) .. ":" .. id .. ":" .. tostring(math.random(1000000))
  rednet.send(0, { kind = "rpc", rid = rid, op = op, body = fields and fields.body or {} }, PROTO)
  local timer = os.startTimer(8)
  while true do
    local event, sender, message, protocol = os.pullEvent()
    if event == "rednet_message" and protocol == PROTO and type(message) == "table" then
      if message.kind == "rpc-reply" and message.rid == rid then
        os.cancelTimer(timer)
        return message.result, message.result and message.result.error
      elseif message.kind == "hint" or message.kind == "cmd" then
        deferred[#deferred + 1] = message
      end
    elseif event == "timer" and sender == timer then
      return nil, "fleet rpc timeout"
    end
  end
end
local rpc = { call = rpcCall, boot = "fleet:" .. id }
function rpc.dispatch(sender, message, protocol, verified)
  if sender == 0 and protocol == PROTO and type(message) == "table" and message.kind == "hint" then
    verified(message)
    return true
  end
  return false
end
local applied
local client = Client.new({ rpc = rpc, enabled = id ~= 4, role = role, dimension = DIM,
  apply = function(values, revision) applied = { values = values, revision = revision } end })
rednet.send(0, { kind = "hello", peer = id }, PROTO)

local function values()
  local current, revision = client.settings()
  return current, revision
end
local stop = false
local function run(cmd)
  if cmd.name == "refresh" then
    assert(client.refresh())
    local current, revision = values()
    return { revision = revision, fuelLow = current.fuelLow, offlineAutonomy = current.offlineAutonomy }
  elseif cmd.name == "report" then
    assert(client.record({ label = "Turtle " .. id, role = role, state = "idle", detail = "",
      pose = framed(cmd.frame, cmd.x, cmd.conf),
      fuel = { level = 1800, limit = 20000 },
      inventory = { slots = 16, usedSlots = 1, fullness = 1 / 16 },
      currentJob = false, capabilities = { navigation = false, inventory = true, crafting = false }, error = false }))
    assert(client.tick())
    return {}
  elseif cmd.name == "await" then
    local limit = os.clock() + 15
    while os.clock() < limit do
      local _, revision = values()
      if applied and applied.revision >= cmd.revision and revision >= cmd.revision then return {} end
      local message
      if deferred[1] and deferred[1].kind == "hint" then message = table.remove(deferred, 1)
      else
        local _, _, pulled, protocol = os.pullEvent("rednet_message")
        if protocol == PROTO then message = pulled end
      end
      if type(message) == "table" and message.kind == "hint" then client.dispatch(0, message, PROTO) end
      assert(client.tick())
    end
    error("settings " .. tostring(cmd.revision) .. " were not applied")
  elseif cmd.name == "status" then
    local current = applied and applied.values or values()
    return { fuelLow = current.fuelLow, fuelTarget = current.fuelTarget, returnHome = current.returnHome }
  elseif cmd.name == "location" then
    local site, why = client.location("dropoff", framed("abs", 0, "certain"), false)
    assert(site, why)
    local blocked, reason = client.location("dropoff", framed("f:" .. id .. ":legacy", 0, "suspect"), false)
    assert(not blocked and reason:find("blocked", 1, true))
    return { locationId = site.id }
  elseif cmd.name == "patch" then
    local dev = dofile("wh2-dev.lua").open({ client = client })
    local done = false
    parallel.waitForAny(function()
      while not done do client.tick() sleep(0.05) end
    end, function()
      assert(dev.select(false) and dev.set("fuelLow", 150))
      dev.tick()
      assert(dev.select("miner") and dev.set("returnHome", false))
      dev.tick()
      assert(dev.select(1) and dev.set("fuelTarget", 4000))
      dev.tick()
      done = true
    end)
    return {}
  elseif cmd.name == "finish" then
    report({ "computer " .. id .. " finished the fleet scenario" })
    stop = true
    return {}
  end
  error("unknown fleet command")
end

while not stop do
  local message
  if #deferred > 0 then message = table.remove(deferred, 1)
  else
    local _, _, pulled, protocol = os.pullEvent("rednet_message")
    if protocol == PROTO then message = pulled end
  end
  if type(message) == "table" and message.kind == "cmd" then
    local ok, row = pcall(run, message)
    local reply = { kind = ok and "done" or "fail", detail = ok and "" or tostring(row) }
    if ok then
      reply.revision, reply.fuelLow, reply.fuelTarget = row.revision, row.fuelLow, row.fuelTarget
      reply.returnHome, reply.offlineAutonomy, reply.locationId = row.returnHome, row.offlineAutonomy, row.locationId
    end
    rednet.send(0, reply, PROTO)
  elseif type(message) == "table" and message.kind == "hint" then
    client.dispatch(0, message, PROTO)
    assert(client.tick())
  end
end
