local arg = { ... }
local Peer = dofile("storage-peer.lua")
local role = arg[1] or "peer"

local function wireless()
  local call = peripheral.call
  peripheral.call = function(name, method, ...)
    if method == "isWireless" then return true end
    return call(name, method, ...)
  end
end

local function mac(key, message)
  local h = 5381
  local data = tostring(key) .. "\0" .. tostring(message)
  for i = 1, #data do h = (h * 33 + data:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

local function peerRole()
  if arg[2] then return arg[2] end
  local handle = fs.open("role.txt", "r")
  if not handle then return "store" end
  local text = handle.readAll()
  handle.close()
  return (text:gsub("%s", ""))
end

wireless()
assert(periphemu.create("left", "modem", 1))
rednet.open("left")
assert(rednet.isOpen("left"), "rednet closed")

if role == "peer" then
  local id = os.getComputerID()
  local kind = peerRole()
  local deps = dofile("lib/stubs/h4d_dep.lua")
  local cfg = {
    id = id, role = kind, peerKey = "peer-key-" .. id, mac = mac,
    boot = "1000:" .. id, deps = deps, fsapi = fs,
    power = function() return { fuel = 18000, limit = 20000 } end,
    range = function() return "ok" end,
  }
  local disk = Peer.openDisk(fs, "cold", deps)
  rednet.broadcast({ v = 1, op = "hello", id = id, role = kind }, "fleetpeer")
  while true do
    local _, sender, message, protocol = os.pullEvent("rednet_message")
    if protocol == "fleetpeer" and type(message) == "table" and message.op == "halt" then
      rednet.close("left")
      while true do sleep(1) end
    end
    if protocol == "fleetpeer" then
      local reply = Peer.peerHandle(disk, cfg, sender, message)
      if reply then rednet.send(sender, reply, "fleetpeer") end
    end
  end
end

local errors, lines = {}, {}
local result = {
  ok = false, booted = true, errors = errors, lines = lines,
  rx = 0, httpOK = 0, httpAttempts = 0, capacity = fs.getCapacity("/"),
  free = fs.getFreeSpace("/"),
}
local function finish()
  local handle = fs.open("sandbox-result.json", "w")
  handle.write(textutils.serializeJSON(result))
  handle.close()
  local trace = fs.open("sandbox-trace.txt", "w")
  trace.write(table.concat(lines, "\n"))
  trace.close()
end
local function trace(text)
  lines[#lines + 1] = text
  local handle = fs.open("sandbox-trace.txt", "w")
  if handle then
    handle.write(table.concat(lines, "\n"))
    handle.close()
  end
end
local function check(cond, message)
  if cond then return end
  errors[#errors + 1] = message
  lines[#lines + 1] = "FAIL " .. message
  finish()
  os.shutdown()
end

check(config.get("standardsMode") == true, "standardsMode disabled")
check(fs.getCapacity("/") == 1000000, "disk is not 1000000")
local driveOk, driveErr = pcall(periphemu.create, "right", "drive")
check(driveOk, "drive create failed: " .. tostring(driveErr))
local inserted, insertErr = pcall(disk.insertDisk, "right", 9)
check(inserted, "floppy insert failed: " .. tostring(insertErr))
sleep(0.2)
local mount = disk.getMountPath("right")
check(type(mount) == "string", "floppy did not mount")

local specs = {
  { id = 1, role = "store" },
  { id = 2, role = "store" },
  { id = 3, role = "computer" },
}
local peers, seen = {}, {}
local function waitHello(id)
  local timer = os.startTimer(12)
  while not seen[id] do
    local event, sender, message, protocol = os.pullEvent()
    if event == "rednet_message" and protocol == "fleetpeer" and type(message) == "table" and message.op == "hello" then
      seen[sender] = true
    elseif event == "timer" and sender == timer then
      check(false, "peer did not boot: " .. id)
    end
  end
  os.cancelTimer(timer)
end
for _, spec in ipairs(specs) do
  local ok, err = pcall(periphemu.create, tostring(spec.id), "computer")
  check(ok, "create " .. spec.id .. " failed: " .. tostring(err))
  peers[#peers + 1] = { id = spec.id, role = spec.role }
  waitHello(spec.id)
  lines[#lines + 1] = "booted " .. spec.id .. " " .. spec.role
end

local function kill(peer)
  rednet.send(peer.id, { v = 1, op = "halt" }, "fleetpeer")
  sleep(0.3)
end

local paired, peerKeys = {}, {}
for _, peer in ipairs(peers) do
  paired[peer.id] = true
  peerKeys[peer.id] = "peer-key-" .. peer.id
end

local function transport(id, message)
  result.rx = result.rx + 1
  trace("rpc " .. id .. " " .. tostring(message.op) .. " #" .. result.rx)
  rednet.send(id, message, "fleetpeer")
  local timer = os.startTimer(2)
  while true do
    local event, sender, payload, protocol = os.pullEvent()
    if event == "rednet_message" and protocol == "fleetpeer" and sender == id then
      if type(payload) ~= "table" or payload.op ~= "hello" then
        os.cancelTimer(timer)
        local op = type(payload) == "table" and (payload.op or payload.error) or type(payload)
        trace("reply " .. id .. " " .. tostring(op))
        return payload
      end
    elseif event == "timer" and sender == timer then
      trace("timeout " .. id .. " " .. tostring(message.op))
      return nil, "timeout"
    end
  end
end

local server = Peer.server({
  peerStorage = true, allowTestMac = true, macKind = "test", mac = mac,
  key = "sandbox-storage-key!!", now = function() return os.epoch("utc") end,
  transport = transport, paired = paired, peerKeys = peerKeys,
  serverId = os.getComputerID(), lruBudget = 0,
})
check(server.exportKey(fs, mount .. "/h4d-storage.key") == true, "floppy export failed")
check(fs.exists(mount .. "/h4d-storage.key"), "floppy key missing")
local enabled, why = server.enable()
check(enabled, why or "enable failed")

local function enrol(peer)
  for _ = 1, 8 do
    local record, err = server.enroll(peer.id, peer.role)
    if record then
      lines[#lines + 1] = "enrolled " .. peer.id .. " quota " .. record.quota
      return record
    end
    lines[#lines + 1] = "enrol retry " .. peer.id .. " " .. tostring(err)
    sleep(0.4)
  end
  check(false, "enrol failed for " .. peer.id)
end

local stores = {}
for _, peer in ipairs(peers) do
  local record = enrol(peer)
  check(record.eligible, "ineligible " .. peer.id .. " " .. tostring(record.why))
  check(record.role == peer.role, "role mismatch for " .. peer.id)
  if peer.role == "store" then stores[#stores + 1] = peer end
end
check(#stores == 2, "expected two store peers")

local KEY = "abs|minecraft:overworld|3|4|-2"
check(server.offer({ key = KEY, rev = 812, payload = "minecraft:stone" }) ~= nil, "offer failed")
check(server.tick(), "tick failed")
local placement = server.state.placements[KEY]
check(server.verified(KEY) == 2, "expected two verified copies, got " .. tostring(server.verified(KEY)))
check(placement and placement.localCopy == false and placement.state == "cold", "section did not go cold")
lines[#lines + 1] = "cold"

local victim, survivor = stores[1], stores[2]
kill(victim)
check(server.tick(), "repair tick failed")
placement = server.state.placements[KEY]
local computer
for _, peer in ipairs(peers) do if peer.role == "computer" then computer = peer end end
check(placement.holders[survivor.id] and placement.holders[survivor.id].verifiedAt > 0, "survivor lost the copy")
check(placement.holders[computer.id] and placement.holders[computer.id].verifiedAt > 0, "computer did not receive the copy")
check(server.verified(KEY) == 2, "re-replication did not restore two copies")
lines[#lines + 1] = "rereplicated"

kill(survivor)
kill(computer)
local body, err = server.read(KEY)
check(type(body) == "table" and body.conf == "unknown" and err == "unknown", "unreachable section was readable")
check(server.state.placements[KEY] ~= nil and server.state.placements[KEY].state == "unknown", "directory dropped the section")
lines[#lines + 1] = "unknown"
result.ok = true
result.cold = true
result.rereplicated = true
result.unknown = true
result.free = fs.getFreeSpace("/")
if #errors == 0 then result.errors = textutils.empty_json_array end
finish()
os.shutdown()
