local mocks = dofile("tests/mocks.lua")
local machine = mocks.new(false)
local env = machine.env
env.dofile = function(path)
  return assert(loadfile(path, "t", env))()
end
machine.files["mapstore.lua"] = "present"
local api = env.dofile("ssot.lua").open({
  controllers = { ["4"] = "test-secret-123456" },
  maxChunks = 8,
})
local pose = { dim = "minecraft:the_nether", x = 512, y = 65, z = 0, h = 0 }
local function call(op, fields, counter)
  local message = fields or {}
  message.v, message.type, message.expect, message.op = 1, "ssot", "ssot_reply", op
  message.rid, message.counter, message.boot = "r" .. counter, counter, "turtle-4"
  message.secret = "test-secret-123456"
  return api.handle(4, message)
end
local reply = call("sync", { pose = pose }, 1)
assert(reply and reply.ok, "sync did not store a pose")
local stone = { dim = pose.dim, x = pose.x, y = pose.y, z = pose.z, name = "minecraft:stone" }
local scan = call("scan", { pose = pose, revision = 0, cells = { stone } }, 2)
assert(scan and scan.ok, "scan did not store a section")
local written = assert(machine.files["ssot.state"], "ssot.lua did not write ssot.state")
local dir = os.getenv("TEMP") .. "/read-ssot-fixture"
os.execute('mkdir "' .. dir .. '" >NUL 2>&1')
for name, bytes in pairs(machine.files) do
  if name == "ssot.state" or name:sub(1, 4) == "map/" then
    local folder = name:match("^(.*)/[^/]+$")
    if folder then os.execute('mkdir "' .. dir .. "/" .. folder .. '" >NUL 2>&1') end
    local handle = assert(io.open(dir .. "/" .. name, "wb"))
    handle:write(bytes)
    handle:close()
  end
end

local function legacy(path)
  local function loadSlot(file)
    local input = io.open(file)
    if not input then return nil end
    local text = input:read("*a")
    input:close()
    if text == "" then return nil end
    local chunk = load("return " .. text, file, "t", {})
    if not chunk then return nil end
    local ok, value = pcall(chunk)
    if ok then return value end
  end
  local best
  for _, slot in ipairs({ "a", "b" }) do
    local value = loadSlot(path .. "/ssot.control." .. slot)
    if type(value) == "table" and value.v == 1 and type(value.generation) == "number"
      and (not best or value.generation > best.generation) then
      best = value
    end
  end
  return best and best.value or nil
end

local old = legacy(dir)
assert(not (old and old.poses and old.poses[4]), "old reader saw ssot.state")
local control, map = dofile("tests/ingame/read-ssot.lua")(dir)
assert(control and control.poses and control.poses[4], "new reader missed poses[4]")
assert(control.poses[4].x == 512 and control.poses[4].dim == "minecraft:the_nether")
local sawStone = false
for _, chunk in pairs(map.chunks or {}) do
  for _, id in pairs(chunk.cells) do
    if map.names[id] == "minecraft:stone" then sawStone = true end
  end
end
assert(sawStone, "new reader missed the stone section")
print("PASS read-ssot sees the pose ssot.lua wrote")
