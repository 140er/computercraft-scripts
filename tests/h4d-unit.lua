local mocks = dofile("tests/mocks.lua")
local deps = dofile("lib/stubs/h4d_dep.lua")
local Peer = dofile("storage-peer.lua")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n  " .. tostring(err))
  end
end
local function equal(actual, expected, message)
  assert(mocks.encode(actual) == mocks.encode(expected), (message or "values differ")
    .. "\nexpected: " .. mocks.encode(expected) .. "\nactual: " .. mocks.encode(actual))
end

local KEY = "abs|minecraft:overworld|3|4|-2"
local KEY2 = "f:17:1792500000000|minecraft:overworld|1|0|-2"
local STORAGE_KEY = "test-storage-key-32b-pad!!"

local function mac(key, message)
  local h = 5381
  local data = tostring(key) .. "\0" .. tostring(message)
  for i = 1, #data do h = (h * 33 + data:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

local function memfs(capacity, freeOf)
  local files = {}
  local api = { files = files }
  function api.makeDir() end
  function api.exists(path) return files[path] ~= nil end
  function api.delete(path) files[path] = nil end
  function api.open(path, mode)
    if mode == "r" then
      if files[path] == nil then return nil end
      local text = files[path]
      return { readAll = function() return text end, close = function() end, write = function() end }
    end
    local parts = {}
    return {
      write = function(chunk) parts[#parts + 1] = chunk end,
      close = function() files[path] = table.concat(parts) end,
      readAll = function() return "" end,
    }
  end
  function api.getCapacity() return capacity or 1000000 end
  function api.getFreeSpace()
    if freeOf then return freeOf() end
    local n = 0
    for _, text in pairs(files) do n = n + math.max(500, #text) end
    return (capacity or 1000000) - n
  end
  return api
end

local function containsKey(value, secret, seen)
  if value == secret then return true end
  local kind = type(value)
  if kind == "string" then return value:find(secret, 1, true) ~= nil end
  if kind ~= "table" then return false end
  seen = seen or {}
  if seen[value] then return false end
  seen[value] = true
  for k, v in pairs(value) do
    if containsKey(k, secret, seen) or containsKey(v, secret, seen) then return true end
  end
  return false
end

local function world(opts)
  opts = opts or {}
  local time = opts.time or 1000000
  local peers, dead, seen = {}, {}, {}
  local failPut = {}
  local function add(id, role, fsopts)
    fsopts = fsopts or {}
    local fsapi = memfs(fsopts.capacity or 1000000, fsopts.freeOf)
    local disk = Peer.openDisk(fsapi, "cold", deps)
    local power = fsopts.power or { fuel = 18000, limit = 20000 }
    local cfg = {
      id = id, role = role, peerKey = "peer-key-" .. id, mac = mac,
      boot = "1000:" .. id, deps = deps, fsapi = fsapi,
      power = function() return power end,
      range = function() return fsopts.range or "ok" end,
    }
    peers[id] = { cfg = cfg, disk = disk, fsapi = fsapi, power = power }
    return peers[id]
  end
  local function transport(id, message)
    seen[#seen + 1] = message
    local peer = peers[id]
    if dead[id] or not peer then return nil, "timeout" end
    if failPut[id] and message.op == "cold-put" then
      return { v = 1, ok = false, error = "quota" }
    end
    return Peer.peerHandle(peer.disk, peer.cfg, 4, message)
  end
  local leases, paired, peerKeys, budgets = {}, {}, {}, {}
  local server = Peer.server({
    deps = deps, peerStorage = true, allowTestMac = true, macKind = "test", mac = mac,
    key = STORAGE_KEY, now = function() return time end, transport = transport,
    paired = paired, peerKeys = peerKeys, leases = leases, budgets = budgets,
    serverId = 4, lruBudget = opts.lruBudget or 0, minerExtras = opts.minerExtras,
  })
  local floppy = memfs()
  return {
    add = add, dead = dead, seen = seen, failPut = failPut, leases = leases,
    paired = paired, peerKeys = peerKeys, budgets = budgets, server = server,
    floppy = floppy, peers = peers,
    advance = function(ms) time = time + ms end,
    now = function() return time end,
  }
end

local function boot(w)
  assert(w.server.exportKey(w.floppy, "disk/h4d-storage.key"))
  assert(w.floppy.files["disk/h4d-storage.key"] == STORAGE_KEY)
  assert(w.server.enable())
end

local function enrol(w, id, role, extra)
  w.paired[id] = true
  w.peerKeys[id] = "peer-key-" .. id
  if extra then w.budgets[id] = extra end
  local peer, err = w.server.enroll(id, role, extra)
  assert(peer, err or "enrol failed")
  return peer
end

test("score is the weighted reachability formula", function()
  local score = Peer.score({ ping = 0.9, reply = 0.8, uptime = 1, power = 0.5 })
  assert(math.abs(score - 0.83) < 1e-9, score)
  assert(Peer.score({ ping = 1 }) == nil)
end)

test("quota leaves code, navigation, journal, staging, and the control reserve", function()
  equal(Peer.quota("miner", 1000000, { journal = 90000, staging = 32768 }, 65536), 225352)
  equal(Peer.quota("store", 1000000, {}, 65536), 457737)
  equal(Peer.quota("computer", 1000000, {}, 65536), 934464)
  equal(Peer.quota("miner", 500000, {}, 65536), 0)
  equal(Peer.quota("miner", "unlimited", {}, 65536), 0)
end)

test("validators reject an unknown version and a bad section key", function()
  assert(Peer.sectionKey(KEY))
  assert(Peer.sectionKey(KEY2))
  assert(not Peer.sectionKey("rel|minecraft:overworld|0|0|0"))
  assert(not Peer.validatePlacement({ v = 2, key = KEY }))
  assert(not Peer.validatePeer({ v = 2, id = 1, role = "store" }))
  local blob = deps.h4b1.encode({ key = KEY, rev = 3, payload = "stone" })
  assert(blob.codec == "h4b1-stub" and blob.hash:sub(1, 5) == "stub-")
  equal(deps.h4b1.unknown(KEY).conf, "unknown")
end)

test("peer storage stays off until the flag, the floppy key, and a mac are present", function()
  local w = world()
  local peer, err = w.server.enroll(1, "store")
  assert(not peer and err == "peer storage disabled")
  local omitted = Peer.server({ deps = deps, mac = mac, macKind = "blake3", key = STORAGE_KEY })
  assert(omitted.exportKey(w.floppy, "disk/h4d-storage.key"))
  local opened, openWhy = omitted.enable()
  assert(opened, openWhy)
  local noFlag = Peer.server({ deps = deps, mac = mac, macKind = "blake3", key = STORAGE_KEY, peerStorage = false })
  assert(noFlag.exportKey(w.floppy, "disk/h4d-storage.key"))
  local ok, why = noFlag.enable()
  assert(not ok and why == "peer storage disabled")
  local noDisk = Peer.server({
    deps = deps, mac = mac, macKind = "blake3", peerStorage = true, key = STORAGE_KEY,
  })
  ok, why = noDisk.enable()
  assert(not ok and why == "storage key not exported")
  local noMac = Peer.server({ deps = deps, peerStorage = true, macKind = "missing", mac = mac, key = STORAGE_KEY })
  assert(noMac.exportKey(memfs(), "disk/h4d-storage.key"))
  ok, why = noMac.enable()
  assert(not ok and why == "storage mac unavailable")
  assert(deps.h1.mac() == nil)
  assert(deps.h1.random() == nil)
end)

test("a failed reachability check stores nothing and a retry is idempotent", function()
  local w = world()
  boot(w)
  w.add(1, "store")
  local peer, err = w.server.enroll(1, "store")
  assert(not peer and err == "unpaired")
  assert(w.server.state.peers[1] == nil)
  w.paired[1] = true
  w.peerKeys[1] = "peer-key-1"
  w.peers[1].power.fuel = nil
  peer, err = w.server.enroll(1, "store")
  assert(not peer and err == "power")
  assert(w.server.state.peers[1] == nil)
  w.peers[1].power.fuel = 0
  peer, err = w.server.enroll(1, "store")
  assert(not peer and err == "power")
  w.peers[1].power.fuel = 18000
  w.dead[1] = true
  peer, err = w.server.enroll(1, "store")
  assert(not peer and err == "timeout")
  assert(w.server.state.peers[1] == nil)
  w.dead[1] = nil
  peer = enrol(w, 1, "store")
  assert(peer.eligible and peer.why == false and peer.v == 1)
  local again = enrol(w, 1, "store")
  assert(again.id == 1 and w.server.state.peers[1] == again)
end)

test("two store peers and one computer re-replicate, then an unreachable section is unknown", function()
  local w = world({ lruBudget = 0 })
  boot(w)
  w.add(21, "store")
  w.add(22, "store")
  w.add(30, "computer")
  enrol(w, 21, "store")
  enrol(w, 22, "store")
  enrol(w, 30, "computer")
  local placement = assert(w.server.offer({ key = KEY, rev = 812, payload = "minecraft:stone" }))
  assert(placement.state == "hot" and placement.localCopy == true)
  assert(w.server.tick())
  assert(w.server.verified(KEY) == 2, "two non-miner copies")
  placement = w.server.state.placements[KEY]
  assert(placement.localCopy == false and placement.state == "cold")
  assert(placement.holders[21].verifiedAt > 0 and placement.holders[22].verifiedAt > 0)
  assert(placement.holders[30] == nil)
  w.dead[21] = true
  assert(w.server.tick())
  assert(w.server.verified(KEY) == 2)
  placement = w.server.state.placements[KEY]
  assert(placement.holders[22].verifiedAt > 0 and placement.holders[30].verifiedAt > 0)
  assert(placement.state == "cold" and placement.localCopy == false)
  assert(w.peers[30].disk.has(placement.hash))
  w.dead[22] = true
  w.dead[30] = true
  local body, err = w.server.read(KEY)
  equal(body.conf, "unknown")
  assert(err == "unknown")
  assert(w.server.state.placements[KEY].state == "unknown")
  assert(w.server.state.placements[KEY].key == KEY)
  local saved = memfs()
  assert(w.server.save(saved, "peers.state"))
  assert(not containsKey(saved.files["peers.state"], STORAGE_KEY))
  assert(not containsKey(w.seen, STORAGE_KEY))
end)

test("one holder cannot drop the local copy", function()
  local w = world({ lruBudget = 0 })
  boot(w)
  w.add(21, "store")
  enrol(w, 21, "store")
  w.server.offer({ key = KEY, rev = 4, payload = "ore" })
  assert(w.server.tick())
  local placement = w.server.state.placements[KEY]
  assert(w.server.verified(KEY) == 1)
  assert(placement.localCopy == true)
  assert(w.server.state.lru[KEY] ~= nil)
  assert(placement.state ~= "cold")
end)

test("a killed peer pins the local copy until a second holder verifies", function()
  local w = world({ lruBudget = 0 })
  boot(w)
  w.add(21, "store")
  w.add(22, "store")
  enrol(w, 21, "store")
  enrol(w, 22, "store")
  w.server.offer({ key = KEY, rev = 5, payload = "deepslate" })
  assert(w.server.tick())
  assert(w.server.state.placements[KEY].state == "cold")
  w.dead[21] = true
  w.failPut[22] = true
  assert(w.server.tick())
  local placement = w.server.state.placements[KEY]
  assert(placement.localCopy == true)
  assert(placement.state ~= "cold")
  assert(w.server.state.lru[KEY] ~= nil)
end)

test("miners hold extras only and hold none during an offline lease", function()
  local w = world({ lruBudget = 0, minerExtras = true })
  boot(w)
  w.add(21, "store")
  w.add(22, "store")
  w.add(17, "miner")
  enrol(w, 21, "store")
  enrol(w, 22, "store")
  enrol(w, 17, "miner", { journal = 90000, staging = 32768 })
  assert(w.server.state.peers[17].quota == 225352)
  w.server.offer({ key = KEY, rev = 6, payload = "gravel" })
  assert(w.server.tick())
  assert(w.server.verified(KEY) == 2)
  assert(w.server.state.placements[KEY].holders[17].verifiedAt > 0)
  assert(w.server.state.placements[KEY].holders[17].role == "miner")
  w.leases[17] = true
  assert(w.server.tick())
  assert(w.server.state.placements[KEY].holders[17] == nil)
  assert(w.server.state.peers[17].holdsOfflineLease == true)
  assert(w.server.state.peers[17].eligible == false)
  assert(w.server.verified(KEY) == 2)
end)

test("a changed boot drops the verified count until the hash matches again", function()
  local w = world({ lruBudget = 65536 })
  boot(w)
  w.add(21, "store")
  w.add(22, "store")
  enrol(w, 21, "store")
  enrol(w, 22, "store")
  w.server.offer({ key = KEY, rev = 7, payload = "andesite" })
  assert(w.server.tick())
  assert(w.server.verified(KEY) == 2)
  local hash = w.server.state.placements[KEY].hash
  w.peers[21].cfg.boot = "2000:21"
  w.peers[21].disk.drop(hash)
  w.failPut[21] = true
  assert(w.server.tick())
  local peer = w.server.state.peers[21]
  assert(peer.boot == "2000:21" and peer.bootChanges == 1)
  assert(w.server.state.placements[KEY].holders[21].verifiedAt == 0)
  assert(w.server.verified(KEY) == 1)
  w.failPut[21] = nil
  w.peers[21].cfg.boot = "2000:21"
  assert(w.server.tick())
  assert(w.server.state.placements[KEY].holders[21].verifiedAt > 0)
  assert(w.server.verified(KEY) == 2)
end)

test("rebalance moves a replica toward the peer with more free space", function()
  local w = world({ lruBudget = 0 })
  boot(w)
  w.add(21, "store", { freeOf = function() return 1000 end })
  w.add(22, "store")
  w.add(30, "computer")
  enrol(w, 21, "store")
  enrol(w, 22, "store")
  enrol(w, 30, "computer")
  w.server.offer({ key = KEY, rev = 8, payload = "tuff" })
  assert(w.server.tick())
  local placement = w.server.state.placements[KEY]
  assert(placement.holders[30] and placement.holders[30].verifiedAt > 0)
  assert(placement.holders[21] == nil)
  assert(placement.localCopy == false and placement.state == "cold")
  assert(w.server.verified(KEY) >= 2)
end)

test("small replicas share a batch file and a bad mac reads as unknown", function()
  local w = world({ lruBudget = 65536 })
  boot(w)
  w.add(21, "store")
  enrol(w, 21, "store")
  w.server.offer({ key = KEY, rev = 1, payload = "a" })
  w.server.offer({ key = KEY2, rev = 1, payload = "b" })
  local third = "abs|minecraft:overworld|0|0|0"
  w.server.offer({ key = third, rev = 1, payload = "c" })
  assert(w.server.tick())
  local paths = {}
  for _, blob in pairs(w.peers[21].disk.list()) do paths[blob.path] = true end
  local n = 0
  for _ in pairs(paths) do n = n + 1 end
  equal(n, 1, "three small blobs share one batch")
  w.server.state.lru[KEY].mac = "deadbeef"
  w.dead[21] = true
  local body, err = w.server.read(KEY)
  equal(body.conf, "unknown")
  assert(err == "unknown")
  assert(w.server.state.placements[KEY] ~= nil)
  local blob = w.peers[21].disk.get(w.server.state.placements[KEY2].hash)
  assert(type(blob) == "string" and blob:find("palette", 1, true) == nil)
end)

test("malformed replica messages are rejected", function()
  local fsapi = memfs()
  local disk = Peer.openDisk(fsapi, "cold", deps)
  local cfg = {
    id = 21, role = "store", peerKey = "peer-key-21", mac = mac, boot = "1000:21",
    deps = deps, fsapi = fsapi, power = function() return { fuel = 1, limit = 1 } end,
  }
  local function reject(message)
    local reply = Peer.peerHandle(disk, cfg, 1, message)
    assert(reply.ok == false, mocks.encode(message))
  end
  reject("nope")
  reject({ v = 2, op = "cold-put" })
  reject({ v = 1, op = "nope" })
  reject({ v = 1, op = "cold-put", key = KEY })
  reject({ v = 1, op = "cold-get" })
  reject({ v = 1, op = "cold-drop" })
  reject({ v = 1, op = "storage-ping" })
  math.randomseed(1)
  local keys = { "v", "op", "key", "hash", "bytes", "offset", "total", "mac", "tmac" }
  for _ = 1, 40 do
    local message = { v = 1, op = "cold-put" }
    for i = 1, 4 do
      local key = keys[math.random(#keys)]
      local roll = math.random(5)
      if roll == 1 then message[key] = math.random(100000)
      elseif roll == 2 then message[key] = "x"
      elseif roll == 3 then message[key] = {}
      elseif roll == 4 then message[key] = false
      else message[key] = nil end
    end
    local ok, reply = pcall(Peer.peerHandle, disk, cfg, 1, message)
    assert(ok, "handler threw")
    assert(type(reply) == "table" and reply.ok == false)
  end
  assert(next(disk.list()) == nil)
end)

print(passed .. " h4d tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then error(failed .. " h4d failures") end
