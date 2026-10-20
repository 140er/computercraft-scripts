local seconds, scenario = ...
seconds = assert(tonumber(seconds))
if scenario == "ar" then
  local ok,err = pcall(assert(loadfile("ar-driver.lua","t",_ENV)))
  local h = assert(fs.open("sandbox-result.json","w"))
  h.write(textutils.serializeJSON({ok=false,booted=false,errors={tostring(err or "driver stopped")},lines={}})) h.close()
  while true do os.pullEvent() end
elseif scenario=="views" then
  local ok,err=pcall(function()
    parallel.waitForAny(assert(loadfile("views-driver.lua","t",_ENV)),function()
      local count=0
      while true do
        local e={os.pullEvent()}
        local m,from,packet
        if e[1]=="modem_message" and type(e[5])=="table" then
          packet=e[5].nMessageID from=e[5].nSender m=e[5].message
        elseif e[1]=="rednet_message" then from=e[2] m=e[3] end
        if type(m)=="table" and m.rid and (m.type=="ssot" or m.type=="ssot_reply") and count<2000 then
          count=count+1
          local f=assert(fs.open("transport.jsonl","a"))
          f.writeLine(textutils.serializeJSON({event=e[1],from=from,packet=packet,rid=m.rid,
            op=m.op,type=m.type,ok=m.ok,at=os.epoch("utc")})) f.close()
        end
      end
    end)
  end)
  local h=assert(fs.open("sandbox-result.json","w"))
  h.write(textutils.serializeJSON({ok=false,booted=false,errors={tostring(err or "views driver stopped")},lines={}})) h.close()
  while true do os.pullEvent() end
elseif scenario == "planner" then
  local ok, err = pcall(function() assert(loadfile("planner-driver.lua", "t", _ENV))() end)
  if not ok and not fs.exists("sandbox-result.json") then
    local handle = fs.open("sandbox-result.json", "w")
    if handle then
      handle.write(textutils.serializeJSON({ ok = false, booted = false, errors = { tostring(err) }, lines = {} }))
      handle.close()
    end
  end
  while true do os.pullEvent() end
end
if scenario == "ssot" or scenario=="nav" or scenario=="mining" or scenario=="warehouse" then
  local ok,err = pcall(assert(loadfile("ssot-driver.lua","t",_ENV)),scenario)
  local h = assert(fs.open("sandbox-result.json","w"))
  h.write(textutils.serializeJSON({ok=false,booted=false,errors={tostring(err or "driver stopped")},lines={}})) h.close()
  while true do os.pullEvent() end
end
local id = os.getComputerID()
local role = ({ [0] = "server", "hub", "miner" })[id]
local result = { ok = false, booted = false, errors = {}, lines = {}, rx = 0,
  httpOK = 0, httpAttempts = 0 }
local peers, messages, screen = {}, {}, nil
local function fail(err) result.errors[#result.errors + 1] = tostring(err) end
local function readTable(path)
  local f = assert(fs.open(path, "r"), "missing " .. path)
  local value = textutils.unserialize(f.readAll())
  f.close()
  return assert(value, "invalid " .. path)
end
local function writeTable(path, value)
  local f = assert(fs.open(path, "w"))
  f.write(textutils.serialize(value))
  f.close()
end
local ok, err = pcall(function()
  assert(config.get("standardsMode") == true, "standardsMode disabled")
  assert(fs.getCapacity("/") == 4000000, "wrong disk limit")
  assert(periphemu.create("left", "modem", 1))
  -- Keep native modem transport. Only its wireless flag is absent in CraftOS-PC.
  local call = peripheral.call
  peripheral.call = function(name, method, ...)
    if name == "left" and method == "isWireless" then return true end
    return call(name, method, ...)
  end
  if id ~= 2 then
    local noop = function() end
    local ar = { clear = noop, update = noop, drawLine3D = noop, drawText2D = noop, drawText3D = noop }
    local find, getName = peripheral.find, peripheral.getName
    peripheral.find = function(kind, ...)
      if kind == "ar_controller" then return ar end
      return find(kind, ...)
    end
    peripheral.getName = function(p)
      if p == ar then return "sandbox_ar" end
      return getName(p)
    end
  end
  gps.locate = function() return id * 2, 64, 0 end
  if id == 2 then
    assert(not turtle, "review fixture for native turtle support")
    turtle = dofile("turtle.lua").idle()
    _G.turtle = turtle
    writeTable("miner.cfg", { home = { x = 4, y = 64, z = 0 }, facing = 0, spine = 1, chest = 2 })
    os.setComputerLabel("Sandbox-miner")
  end
  if id == 0 then
    assert(periphemu.create("1", "computer"))
    sleep(2)
    assert(periphemu.create("2", "computer"))
  end
  sleep(id * 3)
  local native = term.native()
  local w, h = native.getSize()
  screen = window.create(native, 1, 1, w, h, true)
  term.redirect(screen)
  term.native = function() return screen end
  local originalPrint, originalError = print, printError
  print = function(...)
    local parts = table.pack(...)
    for n = 1, parts.n do parts[n] = tostring(parts[n]) end
    messages[#messages + 1] = table.concat(parts, " ")
    if #messages > 3 then table.remove(messages, 1) end
    originalPrint(...)
  end
  printError = function(...) fail(table.concat(table.pack(...), " ")) originalError(...) end
  _G.print, _G.printError = print, printError
  local get = http.get
  http.get = function(...)
    result.httpAttempts = result.httpAttempts + 1
    local url=...
    local file=type(url)=="string" and url:match("/([^/?]+)%?t=")
    if (file=="atomic.lua" or file=="ssot.lua" or file=="ssot-client.lua" or file=="nav.lua"
      or file=="mine-tasks.lua" or file=="mining.lua" or file=="warehouse-tasks.lua" or file=="warehouse.lua" or file=="store.lua") and fs.exists(file) then
      local h=assert(fs.open(file,"r")) local bytes=h.readAll() h.close()
      result.httpOK=result.httpOK+1
      return {readAll=function() return bytes end,close=function() end}
    end
    local response, why = get(...)
    if response then result.httpOK = result.httpOK + 1 end
    return response, why
  end
  parallel.waitForAny(function()
    assert(shell.run(role .. ".lua"), role .. " Lua error")
    error(role .. " stopped before timeout", 0)
  end, function()
    sleep(1)
    result.booted = true
    sleep(seconds - 1)
  end, function()
    while true do
      local _, sender, packet, protocol = os.pullEvent("rednet_message")
      result.rx = result.rx + 1
      peers[sender] = true
      if type(packet) == "table" then
        if packet.lastError then fail(packet.lastError) end
        if packet.type == "error" then fail(packet.error or packet.text or "remote error") end
      end
    end
  end)
  local expected = id == 0 and 1 or 0
  assert(peers[expected], "no rednet traffic from " .. (id == 0 and "hub" or "server"))
  if id == 1 then assert(peers[2], "hub never heard miner") end
  if id == 2 then assert(peers[1], "miner never heard hub") end
  if id == 0 then
    local state = readTable("server.state")
    assert(state.hub, "server has no hub mirror")
    assert(state.bots[2], "server has no miner telemetry")
    for _, entry in ipairs(state.log or {}) do
      if entry.kind:find("error") then fail(entry.kind .. ": " .. entry.text) end
    end
  end
  if fs.exists("miner.log") then
    local f = fs.open("miner.log", "r")
    local log = f.readAll() f.close()
    if log ~= "" then fail(log) end
  end
end)
if not ok then fail(err) end
result.lines = messages
if screen then
  local _, h = screen.getSize()
  for y = 1, h do
    local line = screen.getLine(y):gsub("%s+$", "")
    if line ~= "" then result.lines[#result.lines + 1] = line end
  end
end
while #result.lines > 4 do table.remove(result.lines, 1) end
result.free = fs.getFreeSpace("/")
result.ok = ok and #result.errors == 0
local file = assert(fs.open("sandbox-result.tmp", "w"))
if #result.errors == 0 then result.errors = textutils.empty_json_array end
if #result.lines == 0 then result.lines = textutils.empty_json_array end
file.write(textutils.serializeJSON(result))
file.close()
fs.move("sandbox-result.tmp", "sandbox-result.json")
-- Host stops this PID after every computer has reported.
while true do os.pullEvent() end
