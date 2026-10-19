local M = {}

function M.encode(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) ~= "table" then return tostring(value) end
  local keys, parts = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = "[" .. M.encode(key) .. "]=" .. M.encode(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Only the bytecode-verified methods used by the hub are exposed.
local specs = {
  clear = {}, update = {},
  drawLine3D = { "string", "int", "number", "number", "number", "number", "number", "number" },
  drawText3D = { "string", "int", "number", "number", "number", "number", "number", "number", "string", "boolean" },
}

function M.new(attached, state)
  local m = { output = {}, messages = {}, arCalls = {}, elements = {}, frames = {}, rejected = 0,
    detachedCalls = 0, attached = attached, time = 0 }
  local env = setmetatable({}, { __index = _G })
  local function record(...)
    m.output[#m.output + 1] = M.encode({ ... })
  end
  local function screen(name, width, height, color)
    local t = { getSize = function() return width, height end, isColor = function() return color end }
    for _, method in ipairs({ "setTextScale", "setBackgroundColor", "setTextColor", "clear", "setCursorPos", "write" }) do
      t[method] = function(...) record(name, method, ...) end
    end
    return t
  end
  local native = screen("term", 51, 19, true)
  local monitor = screen("dashboard", 80, 40, true)
  local info = screen("info", 26, 20, false)
  local modem = { isWireless = function() return true end, open = function() end }
  local ar = {}
  for method, spec in pairs(specs) do
    ar[method] = function(...)
      if not m.attached then
        m.detachedCalls = m.detachedCalls + 1
        if method ~= "clear" and method ~= "update" then
          error("call on detached controller")
        end
      end
      assert(select("#", ...) == #spec, method .. ": wrong argument count")
      local args = { ... }
      for i, kind in ipairs(spec) do
        local value = args[i]
        if kind == "int" then
          assert(type(value) == "number" and value % 1 == 0 and value >= -2147483648 and value <= 2147483647,
            method .. ": expected Java int")
        else
          assert(type(value) == kind, method .. ": argument " .. i .. " expected " .. kind)
        end
      end
      m.arCalls[#m.arCalls + 1] = { method = method, args = args }
      if m.fail == method then error("controller unavailable") end
      if method == "clear" then m.elements = {}
      elseif method == "update" then
        local frame = {}
        for id, element in pairs(m.elements) do frame[id] = element end
        m.frames[#m.frames + 1] = frame
      else m.elements[args[1]] = { method = method, args = args } end
    end
  end
  setmetatable(ar, { __index = function(_, method)
    m.rejected = m.rejected + 1
    error("unverified 3D method: " .. method)
  end })
  m.ar = ar
  local devices = { radio = modem, dashboard = monitor, info = info, arbitrary_controller_name = ar }
  local types = { radio = "modem", dashboard = "monitor", info = "monitor", arbitrary_controller_name = "ar_controller" }
  env.peripheral = {
    getNames = function() return { "radio", "dashboard", "info" } end,
    getType = function(name) return types[name] end,
    getName = function(device)
      for name, d in pairs(devices) do if d == device then return name end end
      error("unknown peripheral")
    end,
    call = function(name, method, ...) return devices[name][method](...) end,
    find = function(kind, filter)
      local found = {}
      for _, name in ipairs({ "radio", "dashboard", "info", "arbitrary_controller_name" }) do
        if types[name] == kind and (name ~= "arbitrary_controller_name" or m.attached)
          and (not filter or filter(name, devices[name])) then found[#found + 1] = devices[name] end
      end
      return table.unpack(found)
    end,
  }
  env.term = { native = function() return native end }
  env.colors = {}
  for i, name in ipairs({ "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
    "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }) do
    env.colors[name] = 2 ^ (i - 1)
  end
  env.textutils = {
    serialize = M.encode,
    unserialize = function(text) return assert(load("return " .. text, "=state", "t", {}))() end,
    formatTime = function() return "12:00" end,
  }
  m.files = { ["hub.state"] = M.encode(state or {}) }
  env.fs = {
    exists = function(path) return m.files[path] ~= nil end,
    open = function(path, mode)
      return {
        readAll = function() return assert(m.files[path], path) end,
        write = function(text) m.files[path] = text end,
        close = function() end,
      }
    end,
  }
  local timer = 0
  env.os = {
    clock = function() return m.time end, epoch = function() return 1000000 + m.time * 1000 end,
    time = function() return 12 end, getComputerID = function() return 99 end,
    getComputerLabel = function() return "Hub" end,
    startTimer = function(delay) timer = timer + 1 record("timer", delay) m.timer = timer return timer end,
    pullEvent = function(filter) return coroutine.yield(filter) end,
  }
  env.print = function(...) record("print", ...) end
  env.rednet = {
    open = function(...) record("rednet.open", ...) end,
    host = function(...) record("rednet.host", ...) end,
    send = function(id, msg, protocol)
      record("rednet.send", id, msg, protocol)
      m.messages[#m.messages + 1] = msg
    end,
    broadcast = function(msg, protocol)
      record("rednet.broadcast", msg, protocol)
      m.messages[#m.messages + 1] = msg
    end,
    receive = function(protocol)
      while true do
        local _, id, msg, proto = env.os.pullEvent("rednet_message")
        if proto == protocol then return id, msg, proto end
      end
    end,
  }
  env.parallel = { waitForAny = function(...)
    local threads, filters = {}, {}
    local function resume(i, ...)
      local ok, filter = coroutine.resume(threads[i], ...)
      assert(ok, filter)
      filters[i] = filter
      return coroutine.status(threads[i]) == "dead"
    end
    for i, fn in ipairs({ ... }) do
      threads[i] = coroutine.create(fn)
      if resume(i) then return end
    end
    while true do
      local event = table.pack(coroutine.yield())
      for i in ipairs(threads) do
        if filters[i] == nil or filters[i] == event[1] then
          if resume(i, table.unpack(event, 1, event.n)) then return end
        end
      end
    end
  end }
  function m.start(code)
    m.app = coroutine.create(assert(load(code, "=hub.lua", "t", env)))
    m.push()
  end
  function m.push(...)
    local ok, err = coroutine.resume(m.app, ...)
    assert(ok, err)
  end
  function m.tick()
    m.time = m.time + 1
    m.push("timer", m.timer)
  end
  function m.status(id, packet) m.push("rednet_message", id, packet, "minearmy") end
  m.env = env
  return m
end

return M
