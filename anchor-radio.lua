local M = {}

local GPS_CHANNEL = 65534
local HUB_CHANNEL = 16524
local SERVER_CHANNEL = 16525
local FACING = { north = 0, east = 1, south = 2, west = 3 }

local listening = false
local replyChannel = 0
local book = { cell = false, points = {} }
local memory = false
local storeRef = false

local function integer(n, lo, hi)
  if type(n) == "string" then
    if not n:match("^%-?%d+$") then return nil end
    if #n > 1 and n:sub(1, 1) == "0" then return nil end
    if #n > 2 and n:sub(1, 2) == "-0" then return nil end
    n = tonumber(n)
  end
  if type(n) ~= "number" or n ~= n or n % 1 ~= 0 or n < lo or n > hi then return nil end
  return n
end

local function finite(n)
  return type(n) == "number" and n == n and n >= 0 and n < 1e7
end

local function parseId(text)
  return integer(text, 0, 2147483647)
end

local function parseFacing(value)
  if type(value) == "string" then
    local named = FACING[value:lower()]
    if named ~= nil then return named end
  end
  return integer(value, 0, 3)
end

local function parseSpec(args, dim)
  if type(args) ~= "table" or args[1] ~= "anchor" then return nil, "invalid anchor" end
  local x = integer(args[2], -30000000, 30000000)
  local y = integer(args[3], -2048, 2048)
  local z = integer(args[4], -30000000, 30000000)
  local h = parseFacing(args[5])
  if not x or not y or not z or h == nil then return nil, "invalid anchor" end
  if type(dim) ~= "string" or not dim:match("^[%w_]+:[%w_/.-]+$") then return nil, "invalid anchor" end
  return {
    x = x, y = y, z = z, h = h, dim = dim, src = "typed", frame = "abs", yAbs = true, reference = "command",
  }
end

local function dollarText(id)
  return "$anchor " .. id
end

local function commit(nav, ok, why)
  if ok or why ~= "manual reconciliation required" or type(nav) ~= "table" or type(nav.publish) ~= "function" then
    return ok, why
  end
  return nav.publish()
end

function M.command(nav, args, ctx)
  local spec, err = parseSpec(args, ctx and ctx.dim)
  if not spec then return false, err end
  if type(nav) ~= "table" or type(nav.anchor) ~= "function" then return false, "navigation closed" end
  return commit(nav, nav.anchor(spec))
end

function M.relay(deliver, detector, username, args, dimension)
  local id = parseId(args and args[1])
  if not id or type(deliver) ~= "function" then return false, "invalid anchor" end
  if type(detector) ~= "table" or type(detector.getPlayerPos) ~= "function" then
    return false, "no player position"
  end
  local ok, pos = pcall(detector.getPlayerPos, username)
  if not ok or type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" or type(pos.z) ~= "number" then
    return false, "no player position"
  end
  local player = { x = pos.x, y = pos.y, z = pos.z, dim = pos.dim or pos.dimension or dimension }
  deliver(id, "minearmy", { type = "anchor", target = id, text = dollarText(id), player = player })
  return true, "Anchor sent to " .. id
end

function M.accept(nav, message, from, serverId)
  if type(nav) ~= "table" or type(nav.hear) ~= "function" then return false, "navigation closed" end
  if serverId ~= nil and from ~= serverId then return false, "not from the server" end
  if type(message) ~= "table" then return false, "invalid anchor" end
  if message.target ~= nil and message.target ~= os.getComputerID() then return false, "not this turtle" end
  return commit(nav, nav.hear(message.text, message.player))
end

local function cellKey(pose)
  if type(pose) ~= "table" or pose.conf == "lost" then return false end
  if type(pose.dim) ~= "string" or type(pose.x) ~= "number" or type(pose.y) ~= "number" or type(pose.z) ~= "number" then
    return false
  end
  return pose.dim .. ":" .. pose.x .. ":" .. pose.y .. ":" .. pose.z
end

-- GPS hosts answer on the reply channel with a bare coordinate sequence. Hub and server answers name their type.
local function pointFrom(pose, channel, message, distance)
  if not finite(distance) or type(message) ~= "table" or type(pose) ~= "table" then return nil end
  local x, y, z, key, dim
  if message.type == "hub_here" or message.type == "server_here" then
    x, y, z = message.x, message.y, message.z
    key = message.type == "hub_here" and "hub" or "server"
    dim = message.dim
  elseif channel == replyChannel and message.type == nil and message[1] ~= nil and message[2] ~= nil and message[3] ~= nil then
    x, y, z = message[1], message[2], message[3]
  else
    return nil
  end
  if not integer(x, -30000000, 30000000) or not integer(y, -2048, 2048) or not integer(z, -30000000, 30000000) then
    return nil
  end
  if dim == nil then dim = pose.dim end
  if type(dim) ~= "string" or (pose.dim and dim ~= pose.dim) then return nil end
  if not key then key = "gps:" .. x .. "," .. y .. "," .. z end
  return { key = key, x = x, y = y, z = z, dist = distance, dim = dim, frame = "abs", conf = "certain", loaded = true }
end

function M.onModem(nav, channel, message, distance)
  if not listening or type(nav) ~= "table" or type(nav.pose) ~= "function" then return false end
  local key = cellKey(nav.pose())
  if key ~= book.cell then book.cell, book.points = key, {} end
  local point = pointFrom(nav.pose(), channel, message, distance)
  if point then book.points[point.key] = point end
  return point ~= nil
end

function M.answer(modem, channel, reply, message, pos)
  if channel ~= SERVER_CHANNEL or type(message) ~= "table" or message.type ~= "where_server" then return false end
  if type(pos) ~= "table" or type(pos.dim) ~= "string" or pos.dim == "" then return false end
  if not integer(pos.x, -30000000, 30000000) or not integer(pos.y, -2048, 2048) or not integer(pos.z, -30000000, 30000000) then
    return false
  end
  if type(modem) ~= "table" or type(modem.transmit) ~= "function" or not integer(reply, 0, 65535) then return false end
  modem.transmit(reply, SERVER_CHANNEL, { type = "server_here", x = pos.x, y = pos.y, z = pos.z, dim = pos.dim })
  return true
end

local function ping(modem)
  if type(modem) ~= "table" or type(modem.open) ~= "function" or type(modem.transmit) ~= "function" then return false end
  replyChannel = math.random(10000, 60000)
  modem.open(replyChannel)
  modem.open(GPS_CHANNEL)
  modem.open(HUB_CHANNEL)
  modem.open(SERVER_CHANNEL)
  modem.transmit(GPS_CHANNEL, replyChannel, "PING")
  modem.transmit(HUB_CHANNEL, replyChannel, { type = "where_hub" })
  modem.transmit(SERVER_CHANNEL, replyChannel, { type = "where_server" })
  return true
end

local function radioPoints(pose)
  if cellKey(pose) ~= book.cell then return {} end
  local keys = {}
  for key in pairs(book.points) do keys[#keys + 1] = key end
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    local point = book.points[key]
    out[#out + 1] = {
      x = point.x, y = point.y, z = point.z, dist = point.dist, dim = point.dim,
      frame = "abs", conf = "certain", loaded = true,
    }
  end
  return out
end

local function diskStore()
  if storeRef ~= false then return storeRef end
  storeRef = nil
  if type(fs) ~= "table" or type(fs.exists) ~= "function" then return nil end
  local ok, store = pcall(function()
    return dofile("atomic.lua").store("anchor-radio.state", function(v)
      return type(v) == "table" and v.v == 1 and type(v.dim) == "string" and type(v.at) == "table"
        and type(v.beacons) == "table" and #v.beacons <= 16
    end, 8192)
  end)
  if ok then storeRef = store end
  return storeRef
end

local function savedMemory()
  if memory ~= false then return memory end
  local disk = diskStore()
  memory = disk and type(disk.value) == "table" and disk.value or nil
  return memory
end

local function legDelta(legs, at, pose)
  if type(legs) ~= "table" or type(at) ~= "table" or type(pose) ~= "table" then return nil end
  if pose.conf ~= "suspect" or pose.dim ~= at.dim then return nil end
  if type(at.x) ~= "number" or type(at.y) ~= "number" or type(at.z) ~= "number" then return nil end
  local x, y, z = at.x, at.y, at.z
  local moved = false
  for i = 1, #legs do
    local leg = legs[i]
    local from = type(leg) == "table" and leg.from or nil
    local to = type(leg) == "table" and leg.to or nil
    if type(from) == "table" and type(to) == "table" and from.dim == pose.dim
      and from.x == x and from.y == y and from.z == z
      and integer(to.x, -30000000, 30000000) and integer(to.y, -2048, 2048) and integer(to.z, -30000000, 30000000) then
      x, y, z = to.x, to.y, to.z
      moved = true
    end
  end
  if not moved or x ~= pose.x or y ~= pose.y or z ~= pose.z then return nil end
  local dx, dy, dz = x - at.x, y - at.y, z - at.z
  if (dx == 0 and dy == 0 and dz == 0) or dx % 1 ~= 0 or dy % 1 ~= 0 or dz % 1 ~= 0 then return nil end
  return dx, dy, dz
end

local function withMemory(nav, live)
  if #live < 1 or type(nav.reckoned) ~= "function" then return live end
  local pose = nav.pose()
  if type(pose) ~= "table" or pose.conf ~= "suspect" then return live end
  local saved = savedMemory()
  if type(saved) ~= "table" or saved.dim ~= pose.dim then return live end
  local reckoned = nav.reckoned()
  local dx, dy, dz = legDelta(reckoned and reckoned.legs, saved.at, pose)
  if not dx then return live end
  local seen, out = {}, {}
  for i = 1, #live do
    local point = live[i]
    seen[point.x .. "," .. point.y .. "," .. point.z] = true
    out[i] = point
  end
  for _, beacon in ipairs(saved.beacons) do
    if type(beacon) == "table" and integer(beacon.x, -30000000, 30000000) and integer(beacon.y, -2048, 2048)
      and integer(beacon.z, -30000000, 30000000) and finite(beacon.dist) then
      local x, y, z = beacon.x + dx, beacon.y + dy, beacon.z + dz
      local id = x .. "," .. y .. "," .. z
      if not seen[id] and integer(x, -30000000, 30000000) and integer(y, -2048, 2048) and integer(z, -30000000, 30000000) then
        seen[id] = true
        out[#out + 1] = {
          x = x, y = y, z = z, dist = beacon.dist, dim = pose.dim, frame = "abs", conf = "certain", loaded = true,
        }
      end
    end
  end
  return out
end

local function saveMemory(pose, points)
  if type(pose) ~= "table" or pose.conf ~= "certain" then return end
  local beacons = {}
  for i = 1, #points do
    local point = points[i]
    beacons[#beacons + 1] = { x = point.x, y = point.y, z = point.z, dist = point.dist, dim = point.dim }
  end
  local payload = {
    v = 1, dim = pose.dim, at = { dim = pose.dim, x = pose.x, y = pose.y, z = pose.z }, beacons = beacons,
  }
  local disk = diskStore()
  if disk then
    local ok, saved = pcall(disk.save, payload)
    if not ok or saved == false then return end
  end
  memory = payload
end

function M.boot(nav, opts)
  if type(nav) ~= "table" or type(nav.pose) ~= "function" then return false, "navigation closed" end
  local pose = nav.pose()
  if type(pose) ~= "table" then return false, "no pose" end
  if pose.conf == "certain" then return false, "already certain" end
  if pose.conf ~= "lost" and pose.conf ~= "suspect" then return false, "no pose" end
  if type(opts) ~= "table" or type(opts.modem) ~= "table" then return false, "no modem" end
  book = { cell = cellKey(pose), points = {} }
  listening = true
  local opened = ping(opts.modem)
  local timeout = opts.timeout or 3
  if type(timeout) ~= "number" or timeout < 0 then timeout = 3 end
  if opened and type(sleep) == "function" then pcall(sleep, timeout) end
  listening = false
  if not opened then return false, "no modem" end
  local live = radioPoints(nav.pose())
  local points = withMemory(nav, live)
  if #points < 4 then return false, "weak sample" end
  local ok, why = commit(nav, nav.radio(points))
  if ok then saveMemory(nav.pose(), live) end
  return ok, why
end

return M
