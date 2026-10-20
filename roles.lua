local M = { v = 1 }

local stack = { "atomic.lua", "ssot.lua", "ssot-client.lua", "nav.lua", "mine-tasks.lua",
  "warehouse-tasks.lua", "warehouse.lua", "store.lua", "update.lua" }
local miner = { "miner.lua", "atomic.lua", "ssot.lua", "ssot-client.lua", "nav.lua", "mine-tasks.lua",
  "mining.lua", "warehouse-tasks.lua", "warehouse.lua", "store.lua", "update.lua" }
local hubProgram = { "hub.lua", "fleetview.lua", "update.lua", "atomic.lua", "shelf.lua", "roles.lua" }
local server = { "server.lua", "fleetview.lua", "atomic.lua", "ssot.lua", "ssot-client.lua", "nav.lua",
  "mine-tasks.lua", "mining.lua", "warehouse-tasks.lua", "warehouse.lua", "store.lua", "update.lua",
  "shelf.lua", "roles.lua" }

local function with(name, extra)
  local out, seen = {}, {}
  local function add(file)
    if not seen[file] then seen[file] = true out[#out + 1] = file end
  end
  add(name)
  for _, file in ipairs(extra) do add(file) end
  return out
end

M.roles = {
  miner = { shelf = "fleet", program = miner },
  hub = { shelf = "fleet", program = hubProgram, serves = { "miner.lua" } },
  server = { shelf = "fleet", program = server },
  store = { shelf = "fleet", program = with("store.lua", stack) },
  sorter = { shelf = "fleet", program = with("sorter.lua", stack) },
  roomsorter = { shelf = "fleet", program = with("roomsorter.lua", stack) },
  roomclient = { shelf = "fleet", program = { "roomsorter.lua", "update.lua" } },
  factory = { shelf = "fleet", program = { "factory.lua", "miner.lua", "update.lua", "atomic.lua" } },
  lumber = { shelf = "yard", program = { "lumber.lua", "atomic.lua", "update.lua" } },
  builder = { shelf = "yard", program = { "builder.lua", "atomic.lua", "update.lua" } },
  lava = { shelf = "yard", program = { "lava.lua", "atomic.lua", "update.lua" } },
  farmer = { shelf = "yard", program = { "farmer.lua", "atomic.lua", "update.lua" } },
  buddy = { shelf = "yard", program = { "buddy.lua", "atomic.lua", "update.lua" } },
  smartmine = { shelf = "yard", program = { "smartmine.lua", "update.lua" } },
  relay = { shelf = "yard", program = { "relay.lua", "update.lua" } },
  gpshost = { shelf = "yard", program = { "gpshost.lua", "atomic.lua", "update.lua" } },
  panel = { shelf = "yard", program = { "panel.lua", "fleetview.lua", "update.lua", "atomic.lua" } },
}
M.tools = { "install.lua", "update.lua", "atomic.lua", "roles.lua", "mirror.lua", "shelf.lua" }
M.shelves = {
  fleet = { "miner", "hub", "server", "store", "sorter", "roomsorter", "roomclient", "factory" },
  yard = { "lumber", "builder", "lava", "farmer", "buddy", "smartmine", "relay", "gpshost", "panel" },
}

local function list(roleName, codeShelf)
  local role = M.roles[roleName]
  if not role then return {} end
  local out, seen = {}, {}
  local function add(name)
    if name and not seen[name] then seen[name] = true out[#out + 1] = name end
  end
  for _, name in ipairs(role.program) do add(name) end
  if not codeShelf then
    for _, name in ipairs(role.serves or {}) do add(name) end
  end
  return out
end

function M.program(roleName)
  local role = M.roles[roleName]
  local out = {}
  if not role then return out end
  for _, name in ipairs(role.program) do out[#out + 1] = name end
  return out
end

function M.resident(roleName, codeShelf)
  return list(roleName, codeShelf)
end

function M.roleShelf(roleName)
  local role = M.roles[roleName]
  return role and role.shelf or nil
end

function M.catalog()
  local order = { "miner.lua", "hub.lua", "relay.lua", "smartmine.lua", "sorter.lua", "roomsorter.lua",
    "lumber.lua", "farmer.lua", "lava.lua", "builder.lua", "buddy.lua", "panel.lua", "factory.lua",
    "gpshost.lua", "server.lua", "install.lua", "update.lua", "fleetview.lua", "atomic.lua", "ssot.lua",
    "ssot-client.lua", "nav.lua", "mine-tasks.lua", "mining.lua", "warehouse-tasks.lua", "warehouse.lua",
    "store.lua", "roles.lua", "mirror.lua", "shelf.lua" }
  local have = {}
  for _, name in ipairs(order) do have[name] = true end
  for _, role in pairs(M.roles) do
    for _, name in ipairs(role.program) do have[name] = have[name] or false end
    for _, name in ipairs(role.serves or {}) do have[name] = have[name] or false end
  end
  for _, name in ipairs(M.tools) do have[name] = have[name] or false end
  for name, listed in pairs(have) do
    if listed == false then order[#order + 1] = name end
  end
  return order
end

function M.union(shelfName, sizeOf)
  local files, bytes, largest, largestName = {}, 0, 0, nil
  local function add(name)
    if files[name] then return end
    files[name] = true
    local n = sizeOf(name) or 0
    bytes = bytes + n
    if n > largest then largest, largestName = n, name end
  end
  for _, roleName in ipairs(M.shelves[shelfName] or {}) do
    local role = M.roles[roleName]
    for _, name in ipairs(role.program) do add(name) end
    for _, name in ipairs(role.serves or {}) do add(name) end
  end
  for _, name in ipairs(M.tools) do add(name) end
  return { files = files, bytes = bytes, largest = largest, largestName = largestName }
end

function M.fit(shelfName, sizeOf, capacity)
  local union = M.union(shelfName, sizeOf)
  local need = union.bytes + union.largest
  if capacity == nil or capacity == "unlimited" then return true, need, capacity end
  return type(capacity) == "number" and capacity >= need, need, capacity
end

function M.diskSize(root)
  return function(name)
    local path = root == "/" and name or (root .. "/" .. name)
    if not fs.exists(path) then return 0 end
    local h = fs.open(path, "r")
    if not h then return 0 end
    local n = #(h.readAll() or "")
    h.close()
    return n
  end
end

return M
