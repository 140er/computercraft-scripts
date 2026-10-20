local seconds = ...
seconds = assert(tonumber(seconds))
local id = os.getComputerID()
local result = { ok = false, booted = false, errors = {}, lines = {}, rx = 0, httpOK = 0, httpAttempts = 0 }
local function fail(err) result.errors[#result.errors + 1] = tostring(err) end

local function wireless()
  assert(periphemu.create("left", "modem", 1))
  local call = peripheral.call
  peripheral.call = function(name, method, ...)
    if name == "left" and method == "isWireless" then return true end
    return call(name, method, ...)
  end
end

local function finish(ok)
  result.free = fs.getFreeSpace("/")
  result.capacity = fs.getCapacity("/")
  result.ok = ok and result.booted and #result.errors == 0
  if #result.errors == 0 then result.errors = textutils.empty_json_array end
  if #result.lines == 0 then result.lines = textutils.empty_json_array end
  local file = assert(fs.open("sandbox-result.tmp", "w"))
  file.write(textutils.serializeJSON(result))
  file.close()
  fs.move("sandbox-result.tmp", "sandbox-result.json")
  while true do os.pullEvent() end
end

local ok, err = pcall(function()
  assert(fs.getCapacity("/") == 1000000, "capacity " .. tostring(fs.getCapacity("/")))
  wireless()
  if id == 0 then
    assert(periphemu.create("1", "computer"))
    sleep(1)
    assert(periphemu.create("2", "computer"))
    sleep(1)
    assert(periphemu.create("3", "computer"))
    local hosted = false
    parallel.waitForAny(function()
      local chunk, loadErr = loadfile("mirror.lua", "t", _ENV)
      if not chunk then error(loadErr, 0) end
      chunk("fleet")
      if not hosted then error("mirror stopped", 0) end
    end, function()
      sleep(2)
      hosted = true
      result.booted = true
      sleep(seconds)
    end)
    result.lines = { "fleet mirror hosted" }
  elseif id == 1 then
    sleep(4)
    rednet.open("left")
    local roles = dofile("roles.lua")
    local shelf = dofile("shelf.lua")
    local A = dofile("atomic.lua")
    local programs = roles.program("miner")
    assert(not fs.exists("miner.lua"), "fresh disk already had miner.lua")
    local fetched = 0
    for _, name in ipairs(programs) do
      local text, why
      for _ = 1, 40 do
        text, why = shelf.fetch(name)
        if text or why == "current" then break end
        sleep(0.5)
      end
      if text then
        assert(A.replaceBytes(name, text, function(body) return body == text end), name)
        fetched = fetched + 1
      else
        assert(why == "current" and fs.exists(name), name .. " " .. tostring(why))
      end
    end
    assert(fetched > 0, "mirror sent nothing")
    assert(fs.exists("miner.lua"), "miner.lua missing after fetch")
    for _, name in ipairs(programs) do
      local text, why = shelf.fetch(name)
      assert(text == nil and why == "current", name .. " " .. tostring(text) .. " " .. tostring(why))
    end
    result.booted = true
    result.lines = { "fetched " .. fetched .. " of " .. #programs }
  elseif id == 2 then
    local roles = dofile("roles.lua")
    assert(not fs.exists("miner.lua"), "server disk has miner.lua")
    local sum = 0
    for _, name in ipairs(roles.program("server")) do
      assert(fs.exists(name), "missing " .. name)
      sum = sum + fs.getSize(name)
    end
    assert(sum < 1000000, "server program " .. sum)
    local A = dofile("atomic.lua")
    local disk = A.mount("/")
    local control = disk:open("probe.control", function(v) return type(v) == "table" end,
      { class = "control", limit = 32768 })
    local bulk = disk:open("probe.bulk", function(v) return type(v) == "table" end,
      { class = "bulk", limit = 900000, anchor = "probe.control" })
    assert(control:save({ n = 1 }))
    local target = 45000
    local filler = fs.open("filler.bin", "w")
    while true do
      local free = fs.getFreeSpace("/")
      if type(free) ~= "number" or free <= target then break end
      local chunk = math.min(2048, free - target)
      filler.write(string.rep("x", chunk))
      sleep(0)
    end
    filler.close()
    local okBulk = bulk:save({ n = 1, pad = string.rep("y", 8000) })
    local reported = A.report()
    assert(okBulk == false, "bulk save accepted a full disk")
    assert(type(reported) == "table" and type(reported.error) == "string", "save failure was not reported")
    assert(control.value.n == 1)
    local okControl, why = control:save({ n = 2 })
    assert(okControl, tostring(why))
    assert(control.value.n == 2)
    local S = dofile("ssot.lua")
    local api = S.open({ controllers = { ["7"] = "test-secret-123456" } })
    local pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }
    local function req(op, n, extra)
      local fields = { v = 1, type = "ssot", expect = "ssot_reply", op = op, rid = op .. "-" .. n,
        counter = n, boot = "turtle", secret = "test-secret-123456", pose = pose }
      if extra then for k, v in pairs(extra) do fields[k] = v end end
      return api.handle(7, fields)
    end
    local synced = req("sync", 1)
    assert(synced and synced.ok, synced and synced.error)
    local reserved = req("reserve", 2, { to = { dim = pose.dim, x = 0, y = 64, z = 1 } })
    assert(reserved and reserved.ok, reserved and reserved.error)
    local scanned = req("scan", 3, { revision = 0, cells = { { dim = pose.dim, x = 1, y = 64, z = 0, name = "minecraft:stone" } } })
    assert(scanned and scanned.ok == false, "scan accepted a full disk")
    reported = A.report()
    assert(type(reported) == "table" and type(reported.error) == "string", "panel has no save failure")
    result.booted = true
    result.lines = { "server program " .. sum, "free " .. tostring(fs.getFreeSpace("/")),
      "report " .. reported.error, "reserve ok scan " .. tostring(scanned.error) }
  elseif id == 3 then
    local roles = dofile("roles.lua")
    assert(not fs.exists("miner.lua"), "hub disk has miner.lua")
    local sum = 0
    for _, name in ipairs(roles.program("hub")) do
      assert(fs.exists(name), "missing " .. name)
      assert(name ~= "miner.lua")
      sum = sum + fs.getSize(name)
    end
    assert(sum <= 142143, "hub program " .. sum)
    parallel.waitForAny(function()
      local chunk, loadErr = loadfile("hub.lua", "t", _ENV)
      if not chunk then error(loadErr, 0) end
      chunk()
      if not result.booted then error("hub stopped", 0) end
    end, function()
      sleep(5)
      result.booted = true
    end)
    result.lines = { "hub program " .. sum }
  end
end)
if not ok then fail(err) end
finish(ok)
