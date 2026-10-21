-- Full ssot, nav, mining, server, and hub state at the caps the validators
-- enforce. Records stay short. The cap that binds is the count, not the
-- field width. 32 hub turtles follow the SSOT pose cap. hub.state has no
-- turtle cap of its own. Mining visited and hazards follow the stack cap
-- of 768. The validator does not give them a smaller number.

local DIR = "tests/fixtures/full-state"
local graph = dofile("tests/f0-graph.lua")

local function serialize(value)
  local seen = {}
  local function one(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" then return tostring(v) end
    if t == "boolean" then return tostring(v) end
    if t ~= "table" then error("unsupported value " .. t) end
    if seen[v] then error("repeated table") end
    seen[v] = true
    local n, max = 0, 0
    for k in pairs(v) do
      if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then n = nil break end
      n = n + 1
      if k > max then max = k end
    end
    local parts = {}
    if n and n == max then
      for i = 1, n do parts[i] = one(v[i]) end
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b)
        if type(a) ~= type(b) then return type(a) < type(b) end
        return a < b
      end)
      for _, k in ipairs(keys) do
        parts[#parts + 1] = "[" .. one(k) .. "]=" .. one(v[k])
      end
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return one(value)
end

local function pose(x, z, h)
  local p = { dim = "minecraft:overworld", x = x, y = 64, z = z or 0, boot = "boot" }
  if h then p.h = h end
  return p
end

local function cells()
  local out = {}
  for i = 1, 4096 do out[i] = 1 end
  return out
end

local function ssotValue()
  local names = {}
  for i = 1, 256 do names[i] = "minecraft:block_" .. i end
  local chunks = {}
  for cx = 0, 7 do
    for cz = 0, 7 do
      chunks["minecraft:overworld|" .. cx .. "|0|" .. cz] = { rev = 1, cells = cells() }
    end
  end
  local poses, clients = {}, {}
  for i = 1, 32 do
    poses[i] = pose(i, 0)
    local order, cache = {}, {}
    for j = 1, 8 do
      local rid = "c" .. i .. "r" .. j
      order[j] = rid
      cache[rid] = { request = "req", result = { type = "ssot_reply" } }
    end
    clients[i] = { counter = 1, cache = cache, order = order }
  end
  return {
    schema = 1, epoch = 0, rev = 1, seq = 0,
    chunks = chunks, names = names, poses = poses, moves = {}, clients = clients,
  }
end

local function navValue()
  local map = {}
  for x = 0, 31 do
    for z = 0, 63 do
      map["minecraft:overworld|" .. x .. "|64|" .. z] = "minecraft:stone"
    end
  end
  local trail = {}
  for i = 1, 64 do trail[i] = { dim = "minecraft:overworld", x = i, y = 64, z = 0, h = i % 4 } end
  return {
    version = 1,
    pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0, h = 0 },
    cells = map,
    trail = trail,
  }
end

local function miningValue()
  local stack, visited, hazards = {}, {}, {}
  for i = 1, 768 do
    local p = { dim = "minecraft:overworld", x = i, y = 64, z = 0, h = i % 4 }
    stack[i] = { pose = p, next = (i - 1) % 7 }
    visited[i .. ",64,0"] = true
    hazards["h" .. i] = { dim = "minecraft:overworld", x = i, y = 64, z = 1 }
  end
  return { version = 1, stack = stack, visited = visited, hazards = hazards, progress = 64, phase = "work" }
end

local function serverValue()
  local bots, log, files = {}, {}, {}
  for i = 1, 32 do
    bots[i] = { kind = "miner", protocol = "minearmy", lastSeen = 1000000, x = i, y = 64, z = 0 }
    files["file" .. i .. ".lua"] = { hash = "00000000", size = 1, fetched = 0, path = "file" .. i .. ".lua" }
  end
  for i = 1, 200 do
    log[i] = { at = 1000000, kind = "start", id = (i % 32) + 1, text = "full" }
  end
  return { schema = 1, bots = bots, log = log, files = files }
end

local function hubValue()
  local overrides, progress, bores = {}, {}, {}
  for i = 1, 32 do
    overrides[i] = "diamond"
    progress["shaft-" .. i] = i
    bores[i] = { x = i, z = 0, every = 4, n = 8 }
  end
  return {
    target = "diamond", overrides = overrides, progress = progress, totals = { diamond = 32 },
    branchLen = 64, branchLen64 = true, mineMinutes = 15, reach = 96, sessionLen = 1800,
    mode = "thorough", recallAll = false, bores = bores, pos = { x = 0, y = 64, z = 0 }, rev = 1,
  }
end

local built = {
  ["ssot.state"] = serialize({ schema = 1, generation = 1, value = ssotValue() }),
  ["nav.state"] = serialize({ schema = 1, generation = 1, value = navValue() }),
  ["mining.state"] = serialize({ v = 1, generation = 1, value = miningValue() }),
  ["server.state"] = serialize(serverValue()),
  ["hub.state"] = serialize(hubValue()),
}

local function host()
  local files = {}
  local env = setmetatable({
    print = function() end,
  }, { __index = _G })
  env.fs = {
    exists = function(path) return files[path] ~= nil end,
    delete = function(path) files[path] = nil end,
    move = function(from, to) files[to], files[from] = files[from], nil end,
    getFreeSpace = function() return "unlimited" end,
    getCapacity = function() return "unlimited" end,
    makeDir = function() end,
    list = function() return {} end,
    open = function(path, mode)
      if mode == "w" or mode == "wb" then files[path] = "" end
      return {
        write = function(text) files[path] = (files[path] or "") .. text end,
        readAll = function() return files[path] or "" end,
        close = function() end,
      }
    end,
  }
  env.textutils = {
    serialize = function(value) return serialize(value) end,
    unserialize = function(text)
      return assert(load("return " .. text, "=state", "t", {}))()
    end,
  }
  env.os = {
    epoch = function() return 1000000 end,
    getComputerID = function() return 1 end,
    queueEvent = function() end,
  }
  function env.dofile(path)
    return assert(loadfile(path, "t", env))()
  end
  return env, files
end

local function loadModule(env, path)
  return assert(loadfile(path, "t", env))()
end

local function outcome(err)
  err = tostring(err)
  if err:find("invalid state", 1, true) or err:find("no valid generation", 1, true) or err:find("invalid", 1, true) then
    return "invalid"
  end
  if err:find("state budget exceeded", 1, true) or err:find("budget", 1, true) then
    return "budget"
  end
  return "error"
end

local function checkSsot(text)
  local env, files = host()
  files["ssot.state"] = text
  local SSOT = loadModule(env, "ssot.lua")
  local ok, err = pcall(function()
    SSOT.open({
      controllers = { ["1"] = "0123456789abcdef" },
      compactSections = false, hubProfile = false, deadTurtles = false,
      leaseV2 = false, planner = false, wh2 = { enabled = false },
    })
  end)
  if ok then return "accepted" end
  return outcome(err), err
end

local function checkNav(text)
  local env, files = host()
  files["nav.state"] = text
  local Nav = loadModule(env, "nav.lua")
  local home = { dim = "minecraft:overworld", x = 0, y = 64, z = 0, h = 0 }
  local ok, err = pcall(function()
    local api = Nav.open({
      path = "nav.state", gpsFree = false, pose = home,
      bounds = { min = { dim = home.dim, x = 0, y = 64, z = 0 }, max = { dim = home.dim, x = 31, y = 64, z = 63 } },
    })
    local got = api.pose()
    assert(got.x == 0 and got.h == 0, "nav pose did not load")
  end)
  if ok then return "accepted" end
  return outcome(err), err
end

local function checkMining(text)
  local env, files = host()
  files["mining.state.a"] = text
  local Mining = loadModule(env, "mining.lua")
  local ok, err = pcall(function()
    local api = Mining.open({
      path = "mining.state",
      nav = {}, client = {},
      home = { dim = "minecraft:overworld", x = 0, y = 64, z = 0, h = 0 },
    })
    local got = api.state()
    assert(got.phase == "work" and #got.stack == 768, "mining state did not load")
  end)
  if ok then return "accepted" end
  return outcome(err), err
end

local function checkServer(text)
  local env = host()
  local value = env.textutils.unserialize(text)
  if type(value) == "table" and value.schema == 1 and type(value.bots) == "table"
    and type(value.log) == "table" and type(value.files) == "table" and #value.log == 200 then
    local n = 0
    for _ in pairs(value.bots) do n = n + 1 end
    if n == 32 then return "accepted" end
  end
  return "invalid", "server.state failed the load predicate"
end

local function checkHub(text)
  local env = host()
  local value = env.textutils.unserialize(text)
  if type(value) == "table" and value.mode == "thorough" and value.branchLen == 64 then
    local n = 0
    for _ in pairs(value.overrides) do n = n + 1 end
    if n == 32 then return "accepted" end
  end
  return "invalid", "hub.state failed the shape check"
end

local checks = {
  ["ssot.state"] = checkSsot,
  ["nav.state"] = checkNav,
  ["mining.state"] = checkMining,
  ["server.state"] = checkServer,
  ["hub.state"] = checkHub,
}

local mode = arg[1] or "check"
local failed = false
local names = {}
for name in pairs(built) do names[#names + 1] = name end
table.sort(names)

if mode == "write" then
  os.execute("mkdir -p " .. DIR)
end

for _, name in ipairs(names) do
  local text = built[name]
  local status, err = checks[name](text)
  local path = DIR .. "/" .. name
  print(string.format("fixture %s bytes=%d open=%s", name, #text, status))
  if err and status ~= "accepted" then print("  " .. tostring(err):gsub("\n", " ")) end
  if status == "invalid" or status == "error" then failed = true end
  if mode == "write" then
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  else
    local got = graph.read(path)
    if got ~= text then
      print("fixture " .. name .. " drifted disk=" .. tostring(got and #got or 0))
      failed = true
    end
  end
end

print("caps ssot chunks=64 cells=4096 names=256 poses=32 clients=32 cache=8")
print("caps nav cells=2048 trail=64")
print("caps mining stack=768 visited=768 hazards=768 progress=64")
print("caps server bots=32 log=200")
print("caps hub turtles=32 reason=ssot pose cap")

if failed then
  print("full-state failed")
  os.exit(1)
end
print("full-state passed")
