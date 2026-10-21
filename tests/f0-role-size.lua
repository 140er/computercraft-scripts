-- Code on the installer disk, plus the stores that code can open.
-- A file costs max(500, size). A directory costs 500, including the root.
-- Legacy A.store keeps three generations. mount:open keeps two slots.
-- code + copies * limit + reserve must fit in 0.8 * 1,000,000.

local graph = dofile("tests/f0-graph.lua")

local DISK = 1000000
local BUDGET = math.floor(0.8 * DISK)

-- needle is the call that opens the store. The limit literal is checked in
-- mark, so a changed cap fails here instead of using a stale number.
-- copies 1 with reserve marks a reserve, not a generation pair.
local stores = {
  { name = "nav.state", needle = 'dofile("nav.lua").open', mark = { "nav.lua", "valid,400000" }, copies = 3, limit = 400000 },
  { name = "mining.state", needle = 'dofile("mining.lua").open', mark = { "mining.lua", "limit=250000" }, copies = 2, limit = 250000 },
  { name = "warehouse.state", needle = 'dofile("warehouse.lua").open', mark = { "warehouse.lua", "limit=64000" }, copies = 2, limit = 64000 },
  { name = "ssot.state", needle = "SSOT.open", mark = { "ssot.lua", "or 900000" }, copies = 3, limit = 900000 },
  { name = "ssot.keys", needle = "SSOT.open", mark = { "ssot.lua", "validKeys, 65536" }, copies = 3, limit = 65536 },
  { name = "mapstore.reserve", needle = "SSOT.open", mark = { "ssot.lua", "reserve = 65536" }, copies = 1, limit = 65536, reserve = true },
  { name = "ssot.counter", needle = 'dofile("ssot-client.lua").new', mark = { "ssot-client.lua", "limit = 8192" }, copies = 2, limit = 8192 },
  { name = "views.counter", needle = 'store("views.counter"', mark = { "hub.lua", "end,8192)" }, copies = 3, limit = 8192 },
  { name = "roomsorter.bulk", needle = '"bulk", 900000', mark = { "roomsorter.lua", '"bulk", 900000' }, copies = 2, limit = 900000 },
  { name = "roomsorter.control", needle = '"control", 4096', mark = { "roomsorter.lua", '"control", 4096' }, copies = 2, limit = 4096 },
  { name = "warehouse.cfg", needle = 'open("warehouse.cfg"', mark = { "store.lua", "limit=8192" }, copies = 2, limit = 8192 },
  { name = "shelf.cfg", needle = 'open("shelf.cfg"', mark = { "shelf.lua", "limit = 4096" }, copies = 2, limit = 4096 },
  { name = "gpshost.cfg", needle = 'A.mount("/"):open(CFG,', mark = { "gpshost.lua", "limit = 8192" }, copies = 2, limit = 8192 },
  { name = "lease.cache", needle = 'dofile("b1-nav.lua").wrap', mark = { "b1-nav.lua", "end, 65536)" }, copies = 3, limit = 65536 },
  { name = "lease.journal", needle = "Journal.open", mark = { "journal.lua", "cfg.limit or 262144" }, copies = 3, limit = 262144 },
  { name = "role.bulk", needle = '{ class = "bulk", limit = 900000 }', copies = 2, limit = 900000, perFile = true,
    marks = { "lumber.lua", "farmer.lua", "lava.lua", "builder.lua", "buddy.lua", "factory.lua", "sorter.lua" } },
}

local failed = false
for _, store in ipairs(stores) do
  local files = store.marks or { store.mark[1] }
  local needle = store.mark and store.mark[2] or store.needle
  for _, file in ipairs(files) do
    local src = graph.read(file)
    if not src or not src:find(needle, 1, true) then
      print("mark missing " .. file .. " " .. needle)
      failed = true
    end
  end
end

local sourceCache = {}
local function source(path)
  if sourceCache[path] == nil then sourceCache[path] = graph.read(path) or false end
  return sourceCache[path]
end

local function filesWith(order, needle)
  local names = {}
  for _, path in ipairs(order) do
    local src = source(path)
    if src and src:find(needle, 1, true) then names[#names + 1] = path end
  end
  return names
end

local function codeCost(files)
  local dirs = { [""] = true }
  local raw, cost = 0, 0
  local names = {}
  for name in pairs(files) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local text = source(name)
    if not text then
      print("missing shipped file " .. name)
      failed = true
    else
      raw = raw + #text
      cost = cost + math.max(500, #text)
      local slash = name:find("/", 1, true)
      while slash do
        dirs[name:sub(1, slash - 1)] = true
        slash = name:find("/", slash + 1, true)
      end
    end
  end
  local dirCount = 0
  for _ in pairs(dirs) do dirCount = dirCount + 1 end
  return raw, cost + dirCount * 500, dirCount
end

for _, role in ipairs(graph.installRoles()) do
  local order = graph.closure(role.entry)
  local raw, code, dirs = codeCost(role.files)
  local storeCost, reserve, lines = 0, 0, {}
  for _, store in ipairs(stores) do
    local hits = filesWith(order, store.needle)
    local times = store.perFile and #hits or (hits[1] and 1 or 0)
    if times > 0 then
      local bytes = times * store.copies * store.limit
      if store.reserve then reserve = reserve + bytes else storeCost = storeCost + bytes end
      lines[#lines + 1] = "  " .. store.name .. " x" .. times .. " copies=" .. store.copies
        .. " limit=" .. store.limit .. " from=" .. table.concat(hits, ",")
    end
  end
  local total = code + storeCost + reserve
  local status = total <= BUDGET and "PASS" or "FAIL"
  if status == "FAIL" then failed = true end
  print(string.format(
    "size %s %s raw=%d code=%d dirs=%d stores=%d reserve=%d total=%d budget=%d",
    role.id, status, raw, code, dirs, storeCost, reserve, total, BUDGET))
  for _, line in ipairs(lines) do print(line) end
end

if failed then
  print("role-size failed")
  os.exit(1)
end
print("role-size passed")
