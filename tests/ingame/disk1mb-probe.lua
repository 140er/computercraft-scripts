local D = dofile("depth-result.lua")
local A = dofile("atomic.lua")
local Ledger = dofile("storage-ledger.lua")
local Peer = dofile("storage-peer.lua")
local Hub = dofile("ssot-hub.lua")
local Policy = dofile("s1_h4c.lua")
local checks = {}

local function check(name, ok, err)
  D.check(checks, name, ok, err)
end

local function read(path)
  if not fs.exists(path) then return nil end
  local handle = fs.open(path, "r")
  local text = handle.readAll()
  handle.close()
  return text
end

local function phase()
  return read("disk-phase") or ""
end

if phase() == "capacity" then
  local expect = tonumber(read("expected-capacity"))
  local got = fs.getCapacity("/")
  check("capacity matches the runner limit", got == expect, "expected " .. tostring(expect) .. " got " .. tostring(got))
  D.finish(checks)
  return
end

local capacity = fs.getCapacity("/")
check("phase one disk is 1000000", capacity == 1000000, tostring(capacity))

local store = A.mount("/"):open("disk.state", function(v)
  return type(v) == "table" and type(v.n) == "number"
end, { class = "bulk", limit = 8192 })
check("state save lands", store:save({ n = 1, map = "chunk" }) == true, "save")
local kept = store.value and store.value.n
local rejected = store:save("nope")
check("failed save keeps the previous state", rejected ~= true and store.value and store.value.n == kept, tostring(rejected))

local function section(key, rev, hash)
  return { v = 2, key = key, rev = rev, hash = hash, bytes = 100, observedAt = 1000 }
end

local hashA = string.rep("ab", 32)
local hashB = string.rep("cd", 32)
local old = section("map:old", 1, hashA)
local fresh = section("map:fresh", 2, hashB)
fresh.observedAt = 500000
local preview = Ledger.preview({ old, fresh }, 500000, 1000, 3, 1, {})
check("forget preview lists the old section", preview and #preview.items == 1 and preview.items[1].key == "map:old", "preview")
local changed = section("map:old", 2, hashB)
local committed = Ledger.commit(preview, { changed, fresh }, {}, preview.createdAt + 1)
local skipped = committed and committed.skipped and committed.skipped[1]
check("a section changed after preview is skipped", committed and #committed.delete == 0
  and skipped and skipped.key == "map:old" and skipped.reason == "mismatch", skipped and skipped.reason)
local decline = Ledger.ledger(Ledger.defaults(), {
  total = 1000000, used = 900000, free = 100000,
}, { choice = "decline" }, {}, 500000)
check("declining the warning does not delete", decline and decline.state == "paused", decline and decline.state)

local api = Peer.server({
  deps = {
    h4b1 = { unknown = function(key) return { key = key, state = "unknown" } end, hash = function() return "" end },
    h4a = { save = function() return true end },
  },
  peerStorage = true, mac = function() return "00" end, allowTestMac = true,
  now = function() return 1000 end,
})
local blob, why = api.read("cell:missing")
check("unreachable cell stays unknown", why == "unknown" and blob and blob.state == "unknown", tostring(why))

local hubBudget = Hub.budget({ profile = "hub" })
local serverBudget = Hub.budget({ profile = "server" })
local reserve = Policy.policy("hub").controlReserve
check("hub profile budget is 300000", hubBudget == 300000, tostring(hubBudget))
check("server profile budget is 900000", serverBudget == 900000, tostring(serverBudget))
check("control reserve is 65536", reserve == 65536, tostring(reserve))
local hubState = {}
Hub.prepare(hubState, { profile = "hub", hubProfile = true }, function() return 1000 end)
local authority = hubState.authority
check("hub profile runs at 1000000 with no server", capacity == 1000000 and Hub.enabled({ hubProfile = true })
  and authority and authority.kind == "hub" and authority.epoch == 1 and authority.frozen == false,
  authority and authority.kind or "no authority")

local code, files, overhead = 0, 0, 0
for _, name in ipairs(fs.list("/")) do
  if not fs.isDir(name) then
    local size = fs.getSize(name)
    files = files + 1
    code = code + size
    if size < 500 then overhead = overhead + (500 - size) end
  end
end
local copyA = fs.exists("disk.state.a") and fs.getSize("disk.state.a") or 0
local copyB = fs.exists("disk.state.b") and fs.getSize("disk.state.b") or 0
local record = {
  capacity = capacity, code = code, files = files, overhead = overhead,
  copyA = copyA, copyB = copyB, scratch = fs.getFreeSpace("/"),
  controlReserve = reserve, hubBudget = hubBudget, serverBudget = serverBudget,
}
local handle = fs.open("disk-budget.json", "w")
handle.write(textutils.serializeJSON(record))
handle.close()
local used = code + overhead + copyA + copyB + reserve
check("recorded bytes fit the 1000000 contract", type(capacity) == "number" and used < capacity,
  "used " .. tostring(used))
D.finish(checks)
