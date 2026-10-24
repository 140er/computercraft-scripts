-- tests/so/harness.lua - several fake computers on one rednet, plus a block world.
-- Each machine has its own disk, clock events, and optional turtle.

local H = {}

local base = {
  bit32 = bit32, string = string, table = table, math = math, coroutine = coroutine,
  pairs = pairs, ipairs = ipairs, type = type, tostring = tostring, tonumber = tonumber,
  error = error, assert = assert, pcall = pcall, xpcall = xpcall, select = select,
  unpack = unpack, next = next, setmetatable = setmetatable, getmetatable = getmetatable,
  rawget = rawget, rawset = rawset, rawequal = rawequal, load = load,
}

H.encode = function(value)
  local seen = {}
  local function write(v)
    local kind = type(v)
    if kind == "string" then return string.format("%q", v) end
    if kind == "number" then
      if v == v and v % 1 == 0 and v > -2 ^ 53 and v < 2 ^ 53 then return string.format("%d", v) end
      return string.format("%.17g", v)
    end
    if kind == "boolean" then return v and "true" or "false" end
    if kind ~= "table" then error("bad type", 0) end
    if seen[v] then error("cycle", 0) end
    seen[v] = true
    local keys, ranks = {}, {}
    for key in pairs(v) do
      keys[#keys + 1] = key
      ranks[key] = type(key) .. ":" .. tostring(key)
    end
    table.sort(keys, function(a, b) return ranks[a] < ranks[b] end)
    local parts = {}
    for i = 1, #keys do parts[i] = "[" .. write(keys[i]) .. "]=" .. write(v[keys[i]]) end
    seen[v] = nil
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return write(value)
end

local function attachTurtle(m, opts, world)
  m.pos = { x = opts.x or 0, y = opts.y or 0, z = opts.z or 0 }
  m.heading = opts.facing or 0
  m.fuel = opts.fuel or 1000
  m.selected = 1
  m.inv = {}
  local step = { dx = { [0] = 0, 1, 0, -1 }, dz = { [0] = -1, 0, 1, 0 } }
  local function spot(d)
    local x, y, z = m.pos.x, m.pos.y, m.pos.z
    if d == 4 then return x, y + 1, z end
    if d == 5 then return x, y - 1, z end
    return x + step.dx[d], y, z + step.dz[d]
  end
  local function key(d)
    local x, y, z = spot(d)
    return x .. "," .. y .. "," .. z
  end
  local function dig(d)
    local name = world[key(d)]
    if not name then return false end
    if opts.physics and type(name) == "table" and
      (name.name == "minecraft:lava" or name.name == "minecraft:water" or name.name == "minecraft:chest") then return false end
    world[key(d)] = nil
    if opts.drops then
      local block = type(name) == "table" and name.name or name
      local item = block == "minecraft:stone" and "minecraft:cobblestone" or block
      if block == "minecraft:diamond_ore" then item = "minecraft:diamond" end
      if block == "minecraft:iron_ore" then item = "minecraft:raw_iron" end
      for i = 1, 16 do
        if m.inv[i] and m.inv[i].name == item and m.inv[i].count < 64 then
          m.inv[i].count = m.inv[i].count + 1
          return true
        end
      end
      for i = 1, 16 do
        if not m.inv[i] then m.inv[i] = { name = item, count = 1 } return true end
      end
    end
    return true
  end
  local function move(d)
    if m.fuel ~= "unlimited" and m.fuel < 1 then return false, "Out of fuel" end
    local block=world[key(d)]
    local fluid=type(block)=="table" and (block.name=="minecraft:lava" or block.name=="minecraft:water")
    if block and not (opts.physics and fluid) then return false, "Movement obstructed" end
    m.pos.x, m.pos.y, m.pos.z = spot(d)
    if m.fuel ~= "unlimited" then m.fuel = m.fuel - 1 end
    return true
  end
  local function inspect(d)
    local name = world[key(d)]
    if type(name) == "table" then return true, { name = name.name, tags = name.tags, state = name.state } end
    if name then return true, { name = name } end
    return false, "No block to inspect"
  end
  local function place(d)
    local item = m.inv[m.selected]
    if not item or item.count < 1 then return false end
    local block = world[key(d)]
    if opts.physics and type(block) == "table" and (block.name == "minecraft:lava" or block.name == "minecraft:water") then
      if item.name == "minecraft:bucket" and block.name == "minecraft:lava" and block.state and block.state.level == 0 then
        item.name, world[key(d)] = "minecraft:lava_bucket", nil
        return true
      end
      if item.name ~= "minecraft:cobblestone" and item.name ~= "minecraft:stone" then return false end
    elseif block then return false end
    world[key(d)] = item.name
    item.count = item.count - 1
    if item.count < 1 then m.inv[m.selected] = nil end
    return true
  end
  local function suck(d, n)
    local chest = world[key(d)]
    if type(chest) ~= "table" or type(chest.inv) ~= "table" then return false end
    for slot = 1, #chest.inv do
      local item = chest.inv[slot]
      local selected = m.inv[m.selected]
      if item and item.count > 0 and (not selected or selected.name == item.name) then
        local take = math.min(n or 64, item.count, 64 - (selected and selected.count or 0))
        if take > 0 then
          m.inv[m.selected] = { name = item.name, count = (selected and selected.count or 0) + take }
          item.count = item.count - take
          return true
        end
      end
    end
    return false
  end
  local function drop(n, d)
    local item = m.inv[m.selected]
    if not item or item.count < 1 then return false end
    local take = n or item.count
    if take > item.count then take = item.count end
    if take < 1 then return false end
    local chest = world[key(d)]
    if type(chest) == "table" and type(chest.inv) == "table" then
      chest.inv[#chest.inv + 1] = { name = item.name, count = take }
    end
    item.count = item.count - take
    if item.count < 1 then m.inv[m.selected] = nil end
    return true
  end
  local function refuel(n)
    local item = m.inv[m.selected]
    if not item or item.count < 1 then return false end
    local each = 0
    if item.name == "minecraft:coal" or item.name == "minecraft:charcoal" then each = 80 end
    if item.name == "minecraft:lava_bucket" then each = 1000 end
    if item.name == "minecraft:coal_block" then each = 800 end
    if item.name == "minecraft:blaze_rod" then each = 120 end
    if each == 0 then return false end
    local take = n or 1
    if take > item.count then take = item.count end
    if take < 1 then return false end
    if item.name == "minecraft:lava_bucket" then item.name = "minecraft:bucket"
    else
      item.count = item.count - take
      if item.count < 1 then m.inv[m.selected] = nil end
    end
    if m.fuel ~= "unlimited" then m.fuel = m.fuel + each * take end
    return true
  end
  local function turn(n)
    m.heading = (m.heading + n) % 4
    return true
  end
  m.env.turtle = {
    forward = function() return move(m.heading) end,
    back = function() return move((m.heading + 2) % 4) end,
    up = function() return move(4) end,
    down = function() return move(5) end,
    turnLeft = function() return turn(3) end,
    turnRight = function() return turn(1) end,
    dig = function() return dig(m.heading) end,
    digUp = function() return dig(4) end,
    digDown = function() return dig(5) end,
    place = function() return place(m.heading) end,
    placeUp = function() return place(4) end,
    placeDown = function() return place(5) end,
    suck = function(n) return suck(m.heading, n) end,
    suckUp = function(n) return suck(4, n) end,
    suckDown = function(n) return suck(5, n) end,
    drop = function(n) return drop(n, m.heading) end,
    dropUp = function(n) return drop(n, 4) end,
    dropDown = function(n) return drop(n, 5) end,
    refuel = function(n) return refuel(n) end,
    select = function(slot)
      if type(slot) ~= "number" or slot < 1 or slot > 16 or slot % 1 ~= 0 then return false end
      m.selected = slot
      return true
    end,
    inspect = function() return inspect(m.heading) end,
    inspectUp = function() return inspect(4) end,
    inspectDown = function() return inspect(5) end,
    getFuelLevel = function() return m.fuel end,
    getSelectedSlot = function() return m.selected end,
    getItemCount = function(slot)
      local item = m.inv[slot or m.selected]
      return item and item.count or 0
    end,
    getItemDetail = function(slot)
      local item = m.inv[slot or m.selected]
      if item and item.count > 0 then return { name = item.name, count = item.count } end
    end,
  }
end

-- The fake clock does not move during a busy wait, so the real timing
-- loop would not finish. Record the call and skip that loop.
local function noteRandom(m, result)
  if m.randomWrapped or type(result) ~= "table" or type(result.initWithTiming) ~= "function" then return end
  m.randomWrapped = true
  m.randomLog = {}
  m.randomOut = {}
  local saved = {
    initWithTiming = result.initWithTiming,
    mix = result.mix,
    random = result.random,
    init = result.init,
  }
  result.initWithTiming = function()
    m.randomLog[#m.randomLog + 1] = "initWithTiming"
    if m.timingError then error("timing failed") end
    if m.skipTiming == false then return saved.initWithTiming() end
    return saved.init("skip")
  end
  result.mix = function(data)
    m.randomLog[#m.randomLog + 1] = "mix:" .. tostring(data)
    return saved.mix(data)
  end
  result.random = function(n)
    local out = saved.random(n)
    m.randomLog[#m.randomLog + 1] = "random:" .. tostring(n)
    m.randomOut[#m.randomOut + 1] = out
    return out
  end
end

H.new = function(options)
  options = options or {}
  local rate = options.tickRate or 1
  assert(type(rate) == "number" and rate > 0 and rate < math.huge, "tickRate")
  local net = {
    machines = {}, order = {}, hosts = {}, world = {}, time = 1700000000000,
  }

  local epochBase = net.time
  net.tickRate = rate
  net.utc = function() return epochBase + (net.time - epochBase) / rate end
  net.advanceReal = function(seconds) return net.advance(seconds * rate) end

  local function used(files)
    local n = 0
    for _, text in pairs(files) do n = n + #text end
    return n
  end

  net.flush = function()
    local guard = 0
    while guard < 10000 do
      guard = guard + 1
      local pick
      for i = 1, #net.order do
        local m = net.order[i]
        if m.co and coroutine.status(m.co) == "suspended" and #m.inbox > 0 then
          if not pick or m.id < pick.id then pick = m end
        end
      end
      if not pick then return end
      pick.resume(table.remove(pick.inbox, 1))
    end
    error("flush did not settle", 0)
  end

  net.advance = function(seconds)
    local dest = net.time + seconds * 1000
    local guard = 0
    while guard < 10000 do
      guard = guard + 1
      net.flush()
      if net.time >= dest then return end
      local nextAt
      for i = 1, #net.order do
        local m = net.order[i]
        if m.co and coroutine.status(m.co) == "suspended" then
          for j = 1, #m.timers do
            local at = m.timers[j].at
            if at >= net.time and (not nextAt or at < nextAt) then nextAt = at end
          end
        end
      end
      if not nextAt or nextAt > dest then
        net.time = dest
        return
      end
      net.time = nextAt
      for i = 1, #net.order do
        local m = net.order[i]
        if m.co and coroutine.status(m.co) == "suspended" then
          local keep = {}
          for j = 1, #m.timers do
            local timer = m.timers[j]
            if timer.at <= net.time then
              m.inbox[#m.inbox + 1] = table.pack("timer", timer.id)
            else
              keep[#keep + 1] = timer
            end
          end
          m.timers = keep
        end
      end
    end
    error("advance did not settle", 0)
  end

  net.kill = function(m)
    m.killed, m.co, m.inbox, m.timers = true, nil, {}, {}
  end

  net.boot = function(m)
    local files, program, opts = m.files, m.program, m.opts
    for i = #net.order, 1, -1 do
      if net.order[i] == m then table.remove(net.order, i) end
    end
    local fresh = net.machine(opts)
    fresh.files = files
    if net.onBoot then net.onBoot(fresh) end
    fresh.boot(program)
    return fresh
  end

  net.machine = function(opts)
    local m = {
      opts = opts, id = opts.id, files = {}, log = {}, screen = {}, sent = {}, inbox = {},
      timers = {}, timerSeq = 0, cx = 1, cy = 1, capacity = opts.capacity or 16000000,
      randomLog = {}, randomOut = {},
      skipTiming = opts.skipTiming ~= false, timingError = opts.timingError == true,
    }
    local bootAt = net.time
    local env = setmetatable({}, { __index = base })
    m.env = env
    m.resume = function(packed)
      if not m.co or coroutine.status(m.co) == "dead" then return end
      local ok, err
      if packed then ok, err = coroutine.resume(m.co, table.unpack(packed, 1, packed.n))
      else ok, err = coroutine.resume(m.co) end
      if not ok and not m.killed then m.error = err end
      if net.afterResume then net.afterResume(m) end
    end
    m.alive = function()
      return m.co ~= nil and coroutine.status(m.co) == "suspended" and not m.error
    end
    m.install = function(paths)
      for i = 1, #paths do
        local path = paths[i]
        local handle = assert(io.open(path, "rb"))
        local data = handle:read("*a")
        handle:close()
        m.files[path:match("([^/]+)$")] = data
      end
    end
    m.boot = function(path)
      m.program = path
      local text = assert(m.files[path], "missing " .. tostring(path))
      local fn, err = load(text, "@" .. path, "t", env)
      if not fn then m.error = err return end
      m.co = coroutine.create(fn)
      m.resume()
    end
    m.spawn = function(code)
      local fn, err = load(code, "@spawn", "t", env)
      if not fn then m.error = err return end
      m.co = coroutine.create(fn)
      m.resume()
    end

    env.pcall = function(fn, ...)
      local result = table.pack(pcall(fn, ...))
      if m.killed then error("machine killed", 0) end
      return table.unpack(result, 1, result.n)
    end
    env.fs = {
      exists = function(path) return m.files[path] ~= nil end,
      delete = function(path) m.files[path] = nil end,
      move = function(from, to)
        if m.files[from] == nil then error("No such file", 0) end
        m.files[to] = m.files[from]
        m.files[from] = nil
      end,
      getCapacity = function() return m.capacity end,
      getSize = function(path) return #(assert(m.files[path], "No such file")) end,
      getFreeSpace = function() return m.capacity - used(m.files) end,
      makeDir = function() end,
      list = function(dir)
        local names = {}
        if opts.directories then
          local prefix = (dir == "/" or dir == "") and "" or dir:gsub("/+$", "") .. "/"
          local found = {}
          for path in pairs(m.files) do
            if path:sub(1, #prefix) == prefix then
              local name = path:sub(#prefix + 1):match("^[^/]+")
              if name and not found[name] then names[#names + 1], found[name] = name, true end
            end
          end
          table.sort(names)
          return names
        end
        if dir ~= "/" and dir ~= "" then return names end
        for name in pairs(m.files) do
          if not name:find("/", 1, true) then names[#names + 1] = name end
        end
        table.sort(names)
        return names
      end,
      open = function(path, mode)
        if mode == "w" then
          m.files[path] = ""
          return {
            write = function(text)
              text = tostring(text)
              local free = m.capacity - used(m.files)
              if #text > free then
                m.files[path] = m.files[path] .. text:sub(1, math.max(0, free))
                error("Out of space", 0)
              end
              m.files[path] = m.files[path] .. text
            end,
            readAll = function() return m.files[path] or "" end,
            close = function() end,
          }
        end
        if m.files[path] == nil then return nil end
        return {
          readAll = function() return m.files[path] end,
          close = function() end,
        }
      end,
    }
    env.os = {
      epoch = function(kind)
        if kind == "ingame" then return 108000000 + (net.time - epochBase) * 72 end
        if kind ~= nil and kind ~= "utc" and kind ~= "local" then error("epoch", 2) end
        return math.floor(net.utc())
      end,
      clock = function() return (net.time - bootAt) / 1000 end,
      getComputerID = function() return m.id end,
      getComputerLabel = function() return "m" .. tostring(m.id) end,
      queueEvent = function(...) m.inbox[#m.inbox + 1] = table.pack(...) end,
      startTimer = function(delay)
        m.timerSeq = m.timerSeq + 1
        m.timers[#m.timers + 1] = { id = m.timerSeq, at = net.time + delay * 1000 }
        return m.timerSeq
      end,
      cancelTimer = function(id)
        local keep = {}
        for i = 1, #m.timers do
          if m.timers[i].id ~= id then keep[#keep + 1] = m.timers[i] end
        end
        m.timers = keep
      end,
      pullEvent = function(filter)
        if opts.guardServer and filter then
          m.waits = m.waits or {}
          m.waits[#m.waits + 1] = "filtered os.pullEvent in " .. (m.context or "server")
        end
        local event = table.pack(coroutine.yield())
        if event[1] == "terminate" then error("Terminated", 0) end
        return table.unpack(event, 1, event.n)
      end,
      pullEventRaw = function()
        return coroutine.yield()
      end,
    }
    env.sleep = function(seconds)
      if opts.guardServer then
        m.waits = m.waits or {}
        m.waits[#m.waits + 1] = "sleep(" .. tostring(seconds) .. ") in " .. (m.context or "server")
      end
      local id = env.os.startTimer(seconds)
      while true do
        local ev, a = env.os.pullEvent()
        if ev == "timer" and a == id then return end
      end
    end
    env.print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
      m.log[#m.log + 1] = table.concat(parts, "\t")
    end
    env.term = {
      clear = function() m.screen = {} end,
      setCursorPos = function(x, y) m.cx, m.cy = x, y end,
      getCursorPos = function() return m.cx, m.cy end,
      getSize = function() return opts.width or 51, opts.height or 19 end,
      isColor = function() return true end,
      setTextColor = function() end,
      setBackgroundColor = function() end,
      write = function(text)
        local y = m.cy or 1
        m.screen[y] = (m.screen[y] or "") .. tostring(text)
      end,
    }
    env.textutils = {
      serialize = function(value) return H.encode(value) end,
      unserialize = function(text)
        return assert(load("return " .. text, "=state", "t", {}))()
      end,
    }
    env.loadfile = function(path, mode, target)
      local text = env.fs.open(path, "r")
      if not text then return nil, "missing " .. tostring(path) end
      local source = text.readAll()
      text.close()
      local fn, err = load(source, "@" .. path, mode or "bt", target or env)
      if not fn then return nil, err end
      return function(...)
        local result = fn(...)
        if path == "lib/ccryptolib/random.lua" then noteRandom(m, result) end
        if opts.guardServer and path:match("^so%-mod%-.+%.lua$") and type(result) == "table" then
          local function guard(fn, label)
            return function(...)
              local old = m.context
              m.context = label
              local values = table.pack(pcall(fn, ...))
              m.context = old
              if not values[1] then error(values[2], 0) end
              return table.unpack(values, 2, values.n)
            end
          end
          if result.tick then result.tick = guard(result.tick, result.name .. ".tick") end
          for _, kind in ipairs({"handlers", "listen"}) do
            for name, fn in pairs(result[kind] or {}) do
              result[kind][name] = guard(fn, result.name .. "." .. kind .. "." .. name)
            end
          end
        end
        return result
      end
    end
    env.dofile = function(path)
      return assert(env.loadfile(path))()
    end
    if opts.modem then m.modem = { isWireless = function() return true end } end
    env.peripheral = {
      hasType = function(side, kind)
        if kind ~= "inventory" or not m.pos then return false end
        local p = m.pos
        local dx, dy, dz = 0, 0, 0
        if side == "top" then dy = 1
        elseif side == "bottom" then dy = -1
        elseif side == "front" then
          dx = ({ [0]=0, 1, 0, -1 })[m.heading]
          dz = ({ [0]=-1, 0, 1, 0 })[m.heading]
        else return false end
        local block = net.world[(p.x+dx) .. "," .. (p.y+dy) .. "," .. (p.z+dz)]
        return type(block) == "table" and type(block.inv) == "table"
      end,
      find = function(kind)
        if kind == "modem" and m.modem then return m.modem end
        if kind == "monitor" and opts.monitor then return env.term end
      end,
      getName = function(dev)
        if dev == m.modem then return "back" end
        error("unknown peripheral", 0)
      end,
    }
    env.rednet = {
      open = function(side) m.side = side end,
      close = function() m.side = nil end,
      isOpen = function() return m.side ~= nil end,
      host = function(protocol, hostname)
        net.hosts[protocol] = net.hosts[protocol] or {}
        net.hosts[protocol][hostname] = m.id
      end,
      unhost = function(protocol, hostname)
        if net.hosts[protocol] then net.hosts[protocol][hostname] = nil end
      end,
      lookup = function(protocol, hostname)
        if opts.guardServer then
          m.waits = m.waits or {}
          m.waits[#m.waits + 1] = "rednet.lookup in " .. (m.context or "server")
        end
        local bucket = net.hosts[protocol]
        if not bucket then return nil end
        if hostname then return bucket[hostname] end
        local ids = {}
        for _, id in pairs(bucket) do ids[#ids + 1] = id end
        table.sort(ids)
        return table.unpack(ids)
      end,
      receive = function(protocol, timeout)
        if opts.guardServer then
          m.waits = m.waits or {}
          m.waits[#m.waits + 1] = "rednet.receive in " .. (m.context or "server")
        end
        local timer = timeout and env.os.startTimer(timeout)
        while true do
          local event, a, b, c = env.os.pullEvent()
          if event == "rednet_message" and (not protocol or c == protocol) then return a, b, c end
          if event == "timer" and a == timer then return nil end
        end
      end,
      send = function(id, payload, protocol)
        m.sent[#m.sent + 1] = { id = id, payload = payload, protocol = protocol }
        local dest = net.machines[id]
        if dest and not dest.killed then
          dest.inbox[#dest.inbox + 1] = table.pack("rednet_message", m.id, payload, protocol)
        end
      end,
      broadcast = function(payload, protocol)
        m.sent[#m.sent + 1] = { id = nil, payload = payload, protocol = protocol }
        for i = 1, #net.order do
          local dest = net.order[i]
          if dest.id ~= m.id and not dest.killed then
            dest.inbox[#dest.inbox + 1] = table.pack("rednet_message", m.id, payload, protocol)
          end
        end
      end,
    }
    if opts.turtle then
      attachTurtle(m, opts, net.world)
      if opts.actionSeconds then
        for _, name in ipairs({ "forward", "back", "up", "down", "turnLeft", "turnRight",
          "dig", "digUp", "digDown", "inspect", "inspectUp", "inspectDown",
          "place", "placeUp", "placeDown", "suck", "suckDown", "drop", "dropDown", "refuel" }) do
          local action = env.turtle[name]
          env.turtle[name] = function(...)
            env.sleep(opts.actionSeconds)
            return action(...)
          end
        end
      end
    end
    net.machines[m.id] = m
    net.order[#net.order + 1] = m
    return m
  end

  return net
end

return H
