local M = {}

local function plain(raw)
  if type(raw) ~= "table" then return nil end
  if (raw.v == 1 or raw.schema == 1) and type(raw.value) == "table" and raw.enabled == nil then return raw.value end
  return raw
end

local function named(dim)
  return type(dim) == "string" and #dim > 0 and #dim <= 80 and dim:match("^[%w_]+:[%w_/.-]+$") ~= nil
end

local function whole(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function secretOk(value)
  return type(value) == "string" and #value >= 16 and #value <= 128
end

local function point(home)
  if type(home) ~= "table" or not whole(home.x, -30000000, 30000000) then return nil end
  if not whole(home.y, -2048, 2048) or not whole(home.z, -30000000, 30000000) then return nil end
  return { x = home.x, y = home.y, z = home.z }
end

local function heading(h)
  return whole(h, 0, 3) and h or nil
end

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local function loadPlug()
  if not (fs and fs.exists and fs.exists("plug.lua")) then return nil end
  local ok, mod = pcall(dofile, "plug.lua")
  if ok and type(mod) == "table" then return mod end
end

local function world(host)
  return { peripheral = host.peripheral or peripheral, rednet = host.rednet or rednet, gps = host.gps or gps }
end

local function readFile(host, path)
  if type(host.read) == "function" then return plain(host.read(path)) end
  if not (fs and fs.exists and fs.exists(path) and fs.open and textutils) then return nil end
  local handle = fs.open(path, "r")
  if not handle then return nil end
  local body = handle.readAll()
  handle.close()
  local ok, parsed = pcall(textutils.unserialize, body or "")
  if ok then return plain(parsed) end
end

local function writeFile(host, path, value)
  if type(host.write) == "function" then return host.write(path, value) end
  if not (fs and fs.open and textutils) then return false end
  local handle = fs.open(path, "w")
  if not handle then return false end
  handle.write(textutils.serialize(value))
  handle.close()
  return true
end

local function askOnce(host)
  local used = false
  return function(spec)
    if used or type(host.ask) ~= "function" then return nil end
    used = true
    return host.ask(spec)
  end
end

local function clientReady(cfg)
  return type(cfg) == "table" and cfg.enabled == true and whole(cfg.server, 0, 2147483647)
    and named(cfg.dimension) and secretOk(cfg.secret)
end

function M.client(host)
  host = type(host) == "table" and host or {}
  local existing = readFile(host, "wh2.cfg")
  if type(existing) == "table" and existing.enabled == false then return existing end
  if clientReady(existing) then return existing end
  local plug = host.plug or loadPlug()
  if type(plug) ~= "table" or type(plug.secret) ~= "function" or type(plug.fill) ~= "function" then return existing end
  local cfg = {}
  if type(existing) == "table" then
    for key, value in pairs(existing) do cfg[key] = value end
  end
  local once = askOnce(host)
  local saved = type(plug.savedPairing) == "function" and plug.savedPairing() or nil
  local secret = plug.secret(cfg.secret, saved)
  local progress = false
  if secretOk(secret) and cfg.secret ~= secret then cfg.secret, progress = secret, true end
  if not secretOk(cfg.secret) then return existing end
  if not whole(cfg.server, 0, 2147483647) then
    local server = plug.fill(nil, nil, function()
      if type(plug.lookup) ~= "function" then return nil end
      return plug.lookup(world(host), "fleetserver", "server")
    end, once, { title = "Fleet", kind = "number", question = "Fleet server id" })
    if not whole(server, 0, 2147483647) then
      if progress then writeFile(host, "wh2.cfg", cfg) return cfg end
      return existing
    end
    cfg.server, progress = server, true
  end
  if not named(cfg.dimension) then
    local dim = once({ title = "Fleet", kind = "text", question = "Dimension", default = "minecraft:overworld" })
    if not named(dim) then
      if progress then writeFile(host, "wh2.cfg", cfg) return cfg end
      return existing
    end
    cfg.dimension = dim
  end
  cfg.enabled = true
  if not clientReady(cfg) then return existing end
  writeFile(host, "wh2.cfg", cfg)
  return cfg
end

local function reachOf()
  local ok, fleet = pcall(dofile, "wh2-fleet.lua")
  local reach = ok and type(fleet) == "table" and fleet.registry and fleet.registry.reach and fleet.registry.reach.default
  if whole(reach, 1, 4096) then return reach end
  return 96
end

local function box(dim, home, reach)
  return {
    min = { dim = dim, x = clamp(home.x - reach, -30000000, 30000000), y = clamp(home.y - reach, -2048, 2048), z = clamp(home.z - reach, -30000000, 30000000) },
    max = { dim = dim, x = clamp(home.x + reach, -30000000, 30000000), y = clamp(home.y + reach, -2048, 2048), z = clamp(home.z + reach, -30000000, 30000000) },
  }
end

local function minerOff(cfg)
  if cfg.wh2 == false then return true end
  if type(cfg.wh2) == "table" and cfg.wh2.enabled == false then return true end
  if type(cfg.ssot) == "table" and cfg.ssot.enabled == false then return true end
  if type(cfg.nav) == "table" and cfg.nav.enabled == false then return true end
end

local function minerReady(cfg)
  return type(cfg.ssot) == "table" and cfg.ssot.enabled == true and whole(cfg.ssot.server, 0, 2147483647)
    and secretOk(cfg.ssot.secret) and named(cfg.ssot.dimension)
    and type(cfg.nav) == "table" and cfg.nav.enabled == true and type(cfg.nav.bounds) == "table"
    and type(cfg.nav.traffic) == "boolean"
    and type(cfg.mining) == "table" and type(cfg.mining.home) == "table" and named(cfg.mining.home.dim)
    and heading(cfg.mining.home.h) ~= nil
end

function M.miner(cfg, plug, ask, save)
  if type(cfg) ~= "table" or minerOff(cfg) or minerReady(cfg) then return cfg end
  if type(plug) ~= "table" then plug = loadPlug() end
  if type(plug) ~= "table" or type(plug.secret) ~= "function" or type(plug.fill) ~= "function" then return cfg end
  local host = { plug = plug, ask = ask, peripheral = peripheral, rednet = rednet, gps = gps }
  local once = askOnce(host)
  local ssot = {}
  if type(cfg.ssot) == "table" then
    for key, value in pairs(cfg.ssot) do ssot[key] = value end
  end
  local progress = false
  local function stop()
    if progress then
      cfg.ssot = ssot
      if type(save) == "function" then save(cfg) end
    end
    return cfg
  end
  local saved = type(plug.savedPairing) == "function" and plug.savedPairing() or nil
  local secret = plug.secret(ssot.secret, saved)
  if not secretOk(secret) then return cfg end
  if ssot.secret ~= secret then ssot.secret, progress = secret, true end
  if not whole(ssot.server, 0, 2147483647) then
    local server = plug.fill(nil, nil, function()
      if type(plug.lookup) ~= "function" then return nil end
      return plug.lookup(world(host), "fleetserver", "server")
    end, once, { title = "Miner", kind = "number", question = "Fleet server id" })
    if not whole(server, 0, 2147483647) then return stop() end
    ssot.server, progress = server, true
  end
  if not named(ssot.dimension) then
    local dim = once({ title = "Miner", kind = "text", question = "Dimension", default = "minecraft:overworld" })
    if not named(dim) then return stop() end
    ssot.dimension, progress = dim, true
  end
  local home = point(cfg.home)
  if not home and type(plug.gps) == "function" then home = point(plug.gps(world(host))) end
  if not home then
    local picked = once({ title = "Miner", kind = "coord", question = "Where is this turtle?" })
    home = point(picked)
  end
  local face = heading(cfg.facing)
  if face == nil then
    local picked = once({ title = "Miner", kind = "choice", question = "Which way does it face?", choices = type(plug.facings) == "function" and plug.facings() or nil })
    face = heading(picked)
  end
  if not home or face == nil then return stop() end
  local nav = {}
  if type(cfg.nav) == "table" then
    for key, value in pairs(cfg.nav) do nav[key] = value end
  end
  nav.enabled = true
  if type(nav.bounds) ~= "table" then nav.bounds = box(ssot.dimension, home, reachOf()) end
  if nav.traffic == nil then nav.traffic = true end
  local mining = {}
  if type(cfg.mining) == "table" then
    for key, value in pairs(cfg.mining) do mining[key] = value end
  end
  if type(mining.home) ~= "table" then
    mining.home = { dim = ssot.dimension, x = home.x, y = home.y, z = home.z, h = face }
  end
  ssot.enabled = true
  cfg.ssot, cfg.nav, cfg.mining = ssot, nav, mining
  if type(save) == "function" then save(cfg) end
  return cfg
end

return M
