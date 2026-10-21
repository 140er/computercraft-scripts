local seconds = tonumber(...) or 120
local result = { ok = false, booted = false, errors = {}, lines = {}, rx = 0, httpOK = 0, httpAttempts = 0 }
local function fail(err) result.errors[#result.errors + 1] = tostring(err) end
local secret = "test-secret-123456"

local function trace(line)
  local h = fs.open("h3-trace.txt", "a")
  if h then h.writeLine(line) h.close() end
end

local ok, err = pcall(function()
  assert(config.get("standardsMode") == true, "standardsMode disabled")
  assert(fs.getCapacity("/") == 1000000, "wrong disk limit")
  if not peripheral.isPresent("left") then assert(periphemu.create("left", "modem", 1)) end
  local call = peripheral.call
  peripheral.call = function(name, method, ...)
    if name == "left" and method == "isWireless" then return true end
    return call(name, method, ...)
  end
  local cfg = assert(fs.open("ssot.cfg", "w"))
  cfg.write('{controllers={["1"]="' .. secret .. '"},maxChunks=64,leaseMs=30000}')
  cfg.close()

  local replies, fires = {}, {}
  local watched, hold, slowed = {}, false, false
  local find = peripheral.find
  peripheral.find = function(kind, filter)
    if hold and kind == "ar_controller" then
      trace("hold ar")
      os.pullEvent("h3_release")
      trace("released ar")
    end
    return find(kind, filter)
  end
  local nativeSend = rednet.send
  rednet.send = function(id, message, protocol)
    if protocol == "fleetserver" and type(message) == "table" and type(message.rid) == "string" then
      replies[message.rid] = (message.type == "busy" or message.error == "busy") and "busy" or "reply"
    end
    return nativeSend(id, message, protocol)
  end
  local startTimer = os.startTimer
  os.startTimer = function(delay)
    local id = startTimer(delay)
    if delay == 1 then watched[id] = true end
    return id
  end
  local nativeSerialize, serializes = textutils.serialize, 0
  textutils.serialize = function(value, options)
    if type(value) == "table" and value.schema == 1 and type(value.generation) == "number"
      and type(value.value) == "table" and type(value.value.chunks) == "table" then
      serializes = serializes + 1
      if serializes > 1 and not slowed then
        slowed = true
        trace("slow save " .. serializes)
        local start = os.epoch("utc")
        while os.epoch("utc") - start < 250 do end
      end
    end
    return nativeSerialize(value, options)
  end

  local function packet(i)
    return {
      type = "ssot", v = 1, expect = "ssot_reply", op = "snapshot",
      rid = "h3-burst-" .. i, counter = i, boot = "h3-burst", secret = secret,
      chunk = "minecraft:overworld|0|4|0",
    }
  end

  trace("start")
  parallel.waitForAny(function()
    local function explain(value)
      if debug and debug.traceback then return debug.traceback(tostring(value), 2) end
      return tostring(value)
    end
    local loaded, loadErr = xpcall(function() assert(loadfile("server.lua"))() end, explain)
    if not loaded then
      trace("server error " .. tostring(loadErr))
      fail(loadErr)
    end
    while true do os.pullEvent() end
  end, function()
    while true do
      local _, id = os.pullEvent("timer")
      if watched[id] then fires[#fires + 1] = os.epoch("utc") end
    end
  end, function()
    local startup = os.clock() + 20
    repeat sleep(0.2) until fs.exists("server.state") or os.clock() >= startup
    trace("booted timers=" .. #fires .. " state=" .. tostring(fs.exists("server.state")))
    result.booted = fs.exists("server.state")
    if not result.booted then fail("server did not finish startup") return end
    sleep(0.5)
    hold = true
    os.queueEvent("peripheral", "burst")
    sleep(0.5)
    trace("held")
    for i = 1, 200 do os.queueEvent("rednet_message", 1, packet(i), "fleetserver") end
    sleep(0.5)
    local early = 0
    for _ in pairs(replies) do early = early + 1 end
    trace("queued early=" .. early)
    os.queueEvent("h3_release")
    local deadline = os.clock() + math.max(8, seconds - 8)
    repeat
      local count = 0
      for _ in pairs(replies) do count = count + 1 end
      if count >= 200 then break end
      sleep(0.1)
    until os.clock() >= deadline
    local marked = #fires
    sleep(3.2)
    local count = 0
    for _ in pairs(replies) do count = count + 1 end
    trace("done replies=" .. count .. " fires=" .. #fires .. " marked=" .. marked .. " slowed=" .. tostring(slowed))
    local idleWidest = 0
    for i = marked + 2, #fires do idleWidest = math.max(idleWidest, fires[i] - fires[i - 1]) end
    if #fires - marked < 3 then fail("timer fired " .. (#fires - marked) .. " times while idle") end
    if idleWidest > 1300 then fail("idle timer gap " .. idleWidest .. " ms") end
  end)

  local reply, busy, missing = 0, 0, 0
  for i = 1, 200 do
    local status = replies["h3-burst-" .. i]
    if status == "busy" then busy = busy + 1
    elseif status == "reply" then reply = reply + 1
    else missing = missing + 1 end
  end
  result.rx = reply + busy
  if missing > 0 then fail(missing .. " requests got neither a reply nor busy") end
  if reply < 1 or reply > 32 then fail("admitted " .. reply .. " requests; the queue holds 32") end
  if busy < 200 - 32 then fail("full queue answered busy " .. busy .. " times") end
  if not slowed then fail("the forced slow save did not run") end
  local widest = 0
  for i = 2, #fires do widest = math.max(widest, fires[i] - fires[i - 1]) end
  result.lines = {
    "replies=" .. reply,
    "busy=" .. busy,
    "timers=" .. #fires,
    "widestGapMs=" .. widest,
  }
end)

if not ok then fail(err) end
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
