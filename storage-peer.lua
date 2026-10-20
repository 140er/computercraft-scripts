-- Peer cold storage (H4d). peerStorage defaults on. Explicit false stays off.
-- Hosts start M.service beside the SSOT client. This file does not call ssot-client
-- (one call in flight). Store, warehouse, and miner programs own their loops and
-- call M.service once those edits are free to land.

local M = { version = 1, flag = "peerStorage", flagDefault = true, protocol = "fleetpeer" }

local WINDOW_MS = 600000
local FRESH_MS = 30000
local MIN_SCORE = 0.95
local ALPHA = 0.1
local PAGE = 4096
local MIN_FILE = 500
local MAX_BLOB = 65536
local RANK = { store = 1, warehouse = 1, computer = 2, miner = 3 }
local CODE = { miner = 186344, store = 76727, warehouse = 76727, computer = 0 }
local NAV = { miner = 400000, store = 400000, warehouse = 400000, computer = 0 }
local STATES = { hot = true, replicating = true, cold = true, degraded = true, unknown = true }

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function word(s, n)
  return type(s) == "string" and #s > 0 and #s <= n
end

function M.sectionKey(key)
  if not word(key, 180) then return false end
  local frame, rest = key:match("^([^|]+)|(.+)$")
  if not frame or not rest then return false end
  if frame ~= "abs" and not frame:match("^f:[%w:]+$") then return false end
  return rest:match("^([%w_]+:[%w_/.-]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$") ~= nil
end

function M.score(parts)
  if type(parts) ~= "table" then return nil end
  local ping, reply, uptime, power = parts.ping, parts.reply, parts.uptime, parts.power
  if type(ping) ~= "number" or type(reply) ~= "number" or type(uptime) ~= "number" or type(power) ~= "number" then
    return nil
  end
  return 0.4 * ping + 0.4 * reply + 0.1 * uptime + 0.1 * power
end

function M.reserves(role, extra, control)
  local code = CODE[role] or 0
  local nav = NAV[role] or 0
  extra = extra or {}
  local journal = extra.journal or 0
  local staging = extra.staging or 0
  if type(journal) ~= "number" or journal < 0 then journal = 0 end
  if type(staging) ~= "number" or staging < 0 then staging = 0 end
  return code + nav + journal + staging + (control or 65536)
end

function M.quota(role, capacity, extra, control)
  if type(capacity) ~= "number" or capacity ~= capacity or capacity < 0 then return 0 end
  local room = capacity - M.reserves(role, extra, control)
  if room < 0 then return 0 end
  return math.floor(room)
end

local function ewma(prev, sample)
  if prev == nil then return sample end
  return ALPHA * sample + (1 - ALPHA) * prev
end

local function headroom(power)
  if type(power) ~= "table" then return nil end
  if power.fuel == "unlimited" or power.limit == "unlimited" then return 1 end
  if type(power.fuel) ~= "number" or type(power.limit) ~= "number" then return nil end
  if power.fuel ~= power.fuel or power.limit ~= power.limit or power.limit <= 0 or power.fuel < 0 then
    return nil
  end
  local ratio = power.fuel / power.limit
  if ratio < 0 then return 0 end
  if ratio > 1 then return 1 end
  return ratio
end

local function canonical(v, seen)
  local kind = type(v)
  if kind == "string" then return string.format("%q", v) end
  if kind == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return tostring(v)
  end
  if kind == "boolean" then return tostring(v) end
  if kind ~= "table" then return nil end
  seen = seen or {}
  if seen[v] then return nil end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  local parts = {}
  for i = 1, #keys do
    local key = keys[i]
    if type(key) ~= "string" and type(key) ~= "number" then return nil end
    local left, right = canonical(key, seen), canonical(v[key], seen)
    if not left or not right then return nil end
    parts[#parts + 1] = "[" .. left .. "]=" .. right
  end
  seen[v] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.validatePlacement(p)
  if type(p) ~= "table" or p.v ~= 1 or not M.sectionKey(p.key) then return false end
  if not integer(p.rev, 0, 2147483647) or not word(p.hash, 80) or not integer(p.bytes, 0, MAX_BLOB) then
    return false
  end
  if type(p.localCopy) ~= "boolean" or not STATES[p.state] or type(p.holders) ~= "table" then
    return false
  end
  for id, holder in pairs(p.holders) do
    if not integer(id, 0, 2147483647) or type(holder) ~= "table" then return false end
    if not integer(holder.ackAt, 0, 2 ^ 53) or not integer(holder.verifiedAt, 0, 2 ^ 53) then return false end
    if not RANK[holder.role] then return false end
  end
  return true
end

function M.validatePeer(p)
  if type(p) ~= "table" or p.v ~= 1 or not integer(p.id, 0, 2147483647) or not RANK[p.role] then
    return false
  end
  if not integer(p.enrolledAt, 0, 2 ^ 53) or not integer(p.enrolledBy, 0, 2147483647) then return false end
  if not integer(p.quota, 0, 2 ^ 53) or not integer(p.used, 0, 2 ^ 53) then return false end
  if not integer(p.freeReported, 0, 2 ^ 53) or not integer(p.reportedAt, 0, 2 ^ 53) then return false end
  if type(p.window) ~= "table" or not integer(p.window.sent, 0, 1000000) or not integer(p.window.ok, 0, 1000000) then
    return false
  end
  if p.window.ok > p.window.sent then return false end
  if not integer(p.lastReplyAt, 0, 2 ^ 53) or not word(p.boot, 80) or not integer(p.bootChanges, 0, 1000000) then
    return false
  end
  if type(p.power) ~= "table" or type(p.holdsOfflineLease) ~= "boolean" then return false end
  if type(p.score) ~= "number" or p.score < 0 or p.score > 1.000001 or type(p.eligible) ~= "boolean" then
    return false
  end
  if p.why ~= false and not word(p.why, 40) then return false end
  if p.eligible and p.why ~= false then return false end
  return true
end

local function u32(n)
  local a = math.floor(n / 16777216) % 256
  local b = math.floor(n / 65536) % 256
  local c = math.floor(n / 256) % 256
  return string.char(a, b, c, n % 256)
end

local function ru32(s, i)
  if #s < i + 3 then return nil end
  local a, b, c, d = s:byte(i, i + 3)
  return a * 16777216 + b * 65536 + c * 256 + d
end

local function fileCost(n)
  if n < MIN_FILE then return MIN_FILE end
  return n
end

function M.openDisk(fsapi, root, deps)
  root = root or "cold"
  if fsapi.makeDir then fsapi.makeDir(root) end
  local indexPath = root .. "/index"
  local index = { v = 1, batch = 1, batchLen = 0, contentsRev = 0, blobs = {} }
  local pending = {}
  local function readIndex()
    if not fsapi.exists(indexPath) then return end
    local handle = fsapi.open(indexPath, "r")
    if not handle then return end
    local text = handle.readAll()
    handle.close()
    local loader, err = load("return " .. text, "index", "t", {})
    if not loader then return end
    local ok, value = pcall(loader)
    if ok and type(value) == "table" and value.v == 1 and type(value.blobs) == "table" then
      index = value
    end
  end
  readIndex()
  local function saveIndex()
    local text = canonical(index)
    if not text then return false, "index" end
    return deps.h4a.save(fsapi, indexPath, text)
  end
  local disk = {}
  local function used()
    local n = 0
    if fsapi.exists(indexPath) then
      local handle = fsapi.open(indexPath, "r")
      local text = handle and handle.readAll() or ""
      if handle then handle.close() end
      n = n + fileCost(#text)
    end
    local seen = {}
    for _, blob in pairs(index.blobs) do
      local path = blob.path
      if path and not seen[path] then
        seen[path] = true
        local handle = fsapi.open(path, "r")
        local text = handle and handle.readAll() or ""
        if handle then handle.close() end
        n = n + fileCost(#text)
      end
    end
    return n
  end
  function disk.used() return used() end
  function disk.contentsRev() return index.contentsRev end
  function disk.list()
    local out = {}
    for hash, blob in pairs(index.blobs) do out[hash] = blob end
    return out
  end
  function disk.get(hash)
    local blob = index.blobs[hash]
    if not blob then return nil end
    local handle = fsapi.open(blob.path, "r")
    if not handle then return nil end
    local text = handle.readAll()
    handle.close()
    if blob.kind == "file" then return text, blob end
    return text:sub(blob.off + 1, blob.off + blob.len), blob
  end
  function disk.has(hash)
    local blob = index.blobs[hash]
    if not blob then return nil end
    return { size = blob.len, rev = blob.rev, key = blob.key }
  end
  local function room(extra, quota)
    local nextUsed = used() + extra
    if quota and nextUsed > quota then return false, "quota" end
    local free = fsapi.getFreeSpace("/")
    if type(free) == "number" and free < extra then return false, "space" end
    return true
  end
  function disk.put(meta, body, quota)
    if index.blobs[meta.hash] then
      local got = disk.get(meta.hash)
      if got == body then return true, used() end
      return false, "hash clash"
    end
    if #body >= MIN_FILE then
      local path = root .. "/o-" .. meta.hash
      local ok, err = room(fileCost(#body), quota)
      if not ok then return false, err end
      local saved, why = deps.h4a.save(fsapi, path, body)
      if not saved then return false, why end
      index.blobs[meta.hash] = {
        key = meta.key, rev = meta.rev, codec = meta.codec, mac = meta.mac,
        len = #body, kind = "file", path = path,
      }
    else
      local path = root .. "/b-" .. index.batch
      local exists = fsapi.exists(path)
      local previous = ""
      if exists then
        local handle = fsapi.open(path, "r")
        previous = handle.readAll()
        handle.close()
      end
      if index.batchLen + #body > PAGE then
        index.batch = index.batch + 1
        index.batchLen = 0
        path = root .. "/b-" .. index.batch
        exists = false
        previous = ""
      end
      local extra = fileCost(#body)
      if exists then extra = fileCost(#previous + #body) - fileCost(#previous) end
      local ok, err = room(extra, quota)
      if not ok then return false, err end
      local saved, why = deps.h4a.save(fsapi, path, previous .. body)
      if not saved then return false, why end
      index.blobs[meta.hash] = {
        key = meta.key, rev = meta.rev, codec = meta.codec, mac = meta.mac,
        len = #body, kind = "batch", path = path, off = index.batchLen,
      }
      index.batchLen = index.batchLen + #body
    end
    index.contentsRev = index.contentsRev + 1
    pending[meta.hash] = nil
    local saved, why = saveIndex()
    if not saved then return false, why end
    return true, used()
  end
  function disk.drop(hash)
    local blob = index.blobs[hash]
    if not blob then return false, "missing" end
    index.blobs[hash] = nil
    local still = false
    for _, other in pairs(index.blobs) do
      if other.path == blob.path then still = true break end
    end
    if not still and fsapi.exists(blob.path) then fsapi.delete(blob.path) end
    if blob.kind == "batch" and not still then
      index.batchLen = 0
    end
    index.contentsRev = index.contentsRev + 1
    return saveIndex()
  end
  function disk.acceptChunk(meta, offset, bytes, quota)
    if #bytes > PAGE or not integer(offset, 0, MAX_BLOB) or not integer(meta.total, 1, MAX_BLOB) then
      return false, "size"
    end
    if offset + #bytes > meta.total then return false, "size" end
    local slot = pending[meta.hash]
    if offset == 0 or not slot then
      slot = { parts = {}, got = 0, total = meta.total, meta = meta }
      pending[meta.hash] = slot
    end
    if slot.total ~= meta.total or slot.got ~= offset then return false, "order" end
    slot.parts[#slot.parts + 1] = bytes
    slot.got = offset + #bytes
    if slot.got < slot.total then return true, used() end
    local body = table.concat(slot.parts)
    if #body ~= slot.total then return false, "size" end
    if deps.h4b1.hash(body) ~= meta.hash then
      pending[meta.hash] = nil
      return false, "hash"
    end
    return disk.put(meta, body, quota)
  end
  return disk
end

local function loadDeps(cfg)
  if cfg and cfg.deps then return cfg.deps end
  return dofile("lib/stubs/h4d_dep.lua")
end

local function sign(mac, key, op, hash, offset, n, quota)
  if type(mac) ~= "function" or type(key) ~= "string" then return nil end
  return mac(key, table.concat({
    "h4d/chunk/v1", op, hash or "", tostring(offset or 0), tostring(n or 0), tostring(quota or ""),
  }, "\0"))
end

local function storageMessage(blob)
  return table.concat({
    "h4d/storage/v1", blob.key, tostring(blob.rev), blob.codec, tostring(#blob.body), blob.hash,
  }, "\0")
end

function M.peerHandle(disk, cfg, sender, message)
  if type(message) ~= "table" or message.v ~= 1 or type(message.op) ~= "string" then
    return { v = 1, ok = false, error = "reject" }
  end
  local op = message.op
  local function deny(err)
    return { v = 1, ok = false, error = err or "reject" }
  end
  local function authed(extra)
    local expect = sign(cfg.mac, cfg.peerKey, op, message.hash or "", message.offset, extra, message.quota)
    if not expect or message.tmac ~= expect then return false end
    return true
  end
  if op == "storage-ping" then
    if not authed(0) then return deny("mac") end
    if integer(message.quota, 0, 2 ^ 53) then cfg.quota = message.quota end
    local power = cfg.power and cfg.power() or {}
    local cap = cfg.deps.h4a.capacity(cfg.fsapi or cfg.fs, "/")
    return {
      v = 1, ok = true, op = "storage-ping", id = cfg.id, role = cfg.role,
      boot = cfg.boot, power = power, capacity = cap.total, free = cap.free,
      used = disk.used(), quota = cfg.quota, contentsRev = disk.contentsRev(),
      range = cfg.range and cfg.range() or "ok", unlimited = cap.unlimited,
    }
  end
  if op == "cold-has" then
    if type(message.hashes) ~= "table" or #message.hashes > 32 then return deny("reject") end
    if not authed(#message.hashes) then return deny("mac") end
    local present = {}
    for i = 1, #message.hashes do
      local hash = message.hashes[i]
      if type(hash) ~= "string" or #hash > 80 then return deny("reject") end
      local found = disk.has(hash)
      if found then present[hash] = { size = found.size, rev = found.rev } end
    end
    return { v = 1, ok = true, op = "cold-has", present = present, contentsRev = disk.contentsRev() }
  end
  if op == "cold-get" then
    if not word(message.hash, 80) or not integer(message.offset or 0, 0, MAX_BLOB) then return deny("reject") end
    if not integer(message.limit or PAGE, 1, PAGE) then return deny("reject") end
    if not authed(message.offset or 0) then return deny("mac") end
    local body, meta = disk.get(message.hash)
    if not body then return { v = 1, ok = false, error = "unavailable" } end
    local offset = message.offset or 0
    local limit = message.limit or PAGE
    return {
      v = 1, ok = true, op = "cold-get", hash = message.hash, key = meta.key, rev = meta.rev,
      codec = meta.codec, mac = meta.mac, total = #body, offset = offset,
      bytes = body:sub(offset + 1, offset + limit),
    }
  end
  if op == "cold-drop" then
    if not word(message.hash, 80) or not authed(0) then return deny("mac") end
    local ok, err = disk.drop(message.hash)
    if not ok then return deny(err) end
    return { v = 1, ok = true, op = "cold-drop", hash = message.hash, contentsRev = disk.contentsRev() }
  end
  if op == "cold-put" then
    if not M.sectionKey(message.key) or not integer(message.rev, 0, 2147483647) then return deny("reject") end
    if not word(message.hash, 80) or not word(message.mac, 80) or not word(message.codec, 40) then
      return deny("reject")
    end
    if type(message.bytes) ~= "string" or not integer(message.total, 1, MAX_BLOB) then return deny("reject") end
    if not integer(message.offset, 0, MAX_BLOB) or not authed(#message.bytes) then return deny("mac") end
    local ok, usedOrErr = disk.acceptChunk({
      key = message.key, rev = message.rev, hash = message.hash, mac = message.mac,
      codec = message.codec, total = message.total,
    }, message.offset, message.bytes, cfg.quota)
    if not ok then return deny(usedOrErr) end
    return {
      v = 1, ok = true, op = "cold-put", hash = message.hash, rev = message.rev,
      bytes = message.total, used = usedOrErr, partial = message.offset + #message.bytes < message.total,
    }
  end
  return deny("reject")
end

function M.service(cfg)
  local deps = loadDeps(cfg)
  cfg.deps = deps
  local disk = M.openDisk(cfg.fs or fs, cfg.root or "cold", deps)
  cfg.fsapi = cfg.fs or fs
  return function()
    while true do
      local _, sender, message, protocol = os.pullEvent("rednet_message")
      if protocol == M.protocol then
        local reply = M.peerHandle(disk, cfg, sender, message)
        if reply then rednet.send(sender, reply, M.protocol) end
      end
    end
  end
end

function M.server(cfg)
  cfg = cfg or {}
  local deps = loadDeps(cfg)
  local state = cfg.state or { peers = {}, placements = {}, stats = {}, lru = {}, order = {} }
  state.peers, state.placements = state.peers or {}, state.placements or {}
  state.stats, state.lru, state.order = state.stats or {}, state.lru or {}, state.order or {}
  local api = { state = state }
  local enabled = false
  local key, keyExported = nil, false
  local function clock()
    return cfg.now and cfg.now() or 0
  end
  local function stats(id)
    local row = state.stats[id]
    if not row then
      row = { ping = nil, reply = nil, samples = {}, blockedAt = false }
      state.stats[id] = row
    end
    return row
  end
  local function windowOf(row, now)
    local kept, sent, ok = {}, 0, 0
    for i = 1, #row.samples do
      local sample = row.samples[i]
      if now - sample.t <= WINDOW_MS then
        kept[#kept + 1] = sample
        sent = sent + 1
        if sample.ok then ok = ok + 1 end
      end
    end
    row.samples = kept
    return sent, ok
  end
  local function sample(id, now, ok, kind, block)
    local row = stats(id)
    row.samples[#row.samples + 1] = { t = now, ok = ok and true or false, kind = kind }
    if #row.samples > 240 then table.remove(row.samples, 1) end
    if kind ~= "reply" then row.ping = ewma(row.ping, ok and 1 or 0) end
    if kind ~= "ping" then row.reply = ewma(row.reply, ok and 1 or 0) end
    if block then row.blockedAt = now end
    return row
  end
  local function judge(peer, now)
    local row = stats(peer.id)
    local sent, ok = windowOf(row, now)
    peer.window = { sent = sent, ok = ok }
    peer.holdsOfflineLease = deps.b2.holdsOfflineLease(peer.id, cfg.leases) and true or false
    local power = headroom(peer.power)
    local uptime = sent > 0 and (ok / sent) or 0
    local why = false
    if row.ping == nil or row.reply == nil then why = "unreachable" end
    if not why and now - (peer.lastReplyAt or 0) > FRESH_MS then why = "stale" end
    if not why and row.blockedAt and now - row.blockedAt <= WINDOW_MS then why = "range" end
    if not why and (power == nil or power < 0.05) then why = "power" end
    local score = 0
    if row.ping and row.reply and power then
      score = M.score({ ping = row.ping, reply = row.reply, uptime = uptime, power = power }) or 0
    end
    if score < 0 then score = 0 end
    if score > 1 then score = 1 end
    if not why and score < MIN_SCORE then why = "score" end
    if peer.holdsOfflineLease then why = why or "lease" end
    peer.score = score
    peer.why = why
    peer.eligible = why == false
    return peer
  end
  local function stamp(msg, id, op, hash, offset, n)
    msg.v = 1
    msg.op = op
    if hash ~= nil then msg.hash = hash end
    if offset ~= nil then msg.offset = offset end
    msg.tmac = sign(cfg.mac, cfg.peerKeys and cfg.peerKeys[id], op, msg.hash or "", msg.offset or 0, n, msg.quota)
    return msg
  end
  local function rpc(id, msg, kind)
    if type(cfg.transport) ~= "function" then return nil, "no transport" end
    local reply, err = cfg.transport(id, msg)
    local now = clock()
    local peer = state.peers[id]
    if reply == nil then
      if peer then
        sample(id, now, false, kind or "reply", true)
        judge(peer, now)
      end
      return nil, err or "timeout"
    end
    if peer then
      sample(id, now, true, kind or "reply")
      peer.lastReplyAt = now
      if type(reply.free) == "number" then peer.freeReported = math.floor(reply.free) end
      if type(reply.used) == "number" then peer.used = math.floor(reply.used) end
      if type(reply.power) == "table" then peer.power = reply.power end
      peer.reportedAt = now
      if type(reply.boot) == "string" and reply.boot ~= peer.boot then
        peer.boot = reply.boot
        peer.bootChanges = peer.bootChanges + 1
        for _, placement in pairs(state.placements) do
          local holder = placement.holders[id]
          if holder then holder.verifiedAt = 0 end
        end
      end
      if reply.range == "out" or reply.range == "unloaded" then
        stats(id).blockedAt = now
      end
      judge(peer, now)
    end
    if reply.ok == false then return nil, reply.error or "reject" end
    return reply
  end
  function api.exportKey(fsapi, path)
    local secret = cfg.key
    if type(secret) ~= "string" then
      local generated, err = deps.h1.random(32)
      if not generated then return false, err end
      secret = generated
    end
    if #secret < 16 or #secret > 128 then return false, "invalid storage key" end
    local ok, err = deps.h4a.save(fsapi, path, secret)
    if not ok then return false, err end
    local handle = fsapi.open(path, "r")
    if not handle then return false, "export unreadable" end
    local got = handle.readAll()
    handle.close()
    if got ~= secret then return false, "export mismatch" end
    key, keyExported = secret, true
    return true
  end
  function api.enable()
    if cfg.peerStorage ~= nil and cfg.peerStorage ~= true then return false, "peer storage disabled" end
    if not keyExported or type(key) ~= "string" then return false, "storage key not exported" end
    if type(cfg.mac) ~= "function" then return false, "storage mac unavailable" end
    if cfg.macKind ~= "blake3" and cfg.allowTestMac ~= true then
      return false, "storage mac unavailable"
    end
    enabled = true
    return true
  end
  function api.enabled() return enabled end
  local function lruTouch(blobKey)
    for i = 1, #state.order do
      if state.order[i] == blobKey then table.remove(state.order, i) break end
    end
    state.order[#state.order + 1] = blobKey
  end
  local function lruBytes()
    local n = 0
    for _, blob in pairs(state.lru) do n = n + #blob.body end
    return n
  end
  local function remember(blob)
    state.lru[blob.key] = blob
    lruTouch(blob.key)
  end
  local function verifiedNonMiners(placement)
    local n = 0
    for id, holder in pairs(placement.holders) do
      local peer = state.peers[id]
      if peer and peer.role ~= "miner" and holder.role ~= "miner" and peer.eligible
        and not peer.holdsOfflineLease and holder.ackAt > 0 and holder.verifiedAt > 0 then
        n = n + 1
      end
    end
    return n
  end
  local function refresh(placement)
    local copies = verifiedNonMiners(placement)
    local localOk = state.lru[placement.key] ~= nil
    if placement.localCopy and not localOk then placement.localCopy = false end
    if localOk then placement.localCopy = true end
    if not localOk and copies == 0 then
      placement.state = "unknown"
    elseif not localOk and copies >= 2 then
      placement.state = "cold"
    elseif localOk and copies >= 2 then
      placement.state = "replicating"
    elseif localOk and copies == 0 and not next(placement.holders) then
      placement.state = "hot"
    else
      placement.state = "degraded"
    end
    return copies
  end
  function api.enroll(id, role, extra)
    if not enabled then return nil, "peer storage disabled" end
    if not integer(id, 0, 2147483647) or not RANK[role] then return nil, "reject" end
    if not deps.h1.paired(id, cfg.paired) then return nil, "unpaired" end
    local ping = stamp({ boot = "" }, id, "storage-ping", "", 0, 0)
    local reply, err = rpc(id, ping, "ping")
    if not reply then return nil, err or "unreachable" end
    if reply.role ~= role or type(reply.boot) ~= "string" then return nil, "reject" end
    if reply.range == "out" or reply.range == "unloaded" then return nil, "range" end
    local power = headroom(reply.power)
    if power == nil or power < 0.05 then return nil, "power" end
    if type(reply.capacity) ~= "number" or reply.unlimited then return nil, "space" end
    if type(reply.free) ~= "number" or reply.free < 0 then return nil, "space" end
    local now = clock()
    local previous = state.peers[id]
    local peer = previous or {
      v = 1, id = id, role = role, enrolledAt = now, enrolledBy = cfg.serverId or 0,
      bootChanges = 0, window = { sent = 0, ok = 0 },
    }
    peer.role = role
    peer.quota = M.quota(role, reply.capacity, extra or cfg.budgets and cfg.budgets[id], deps.h4a.controlReserve())
    peer.used = math.floor(reply.used or 0)
    peer.freeReported = math.floor(reply.free)
    peer.reportedAt = now
    peer.lastReplyAt = now
    peer.power = reply.power
    peer.boot = reply.boot
    if not previous then peer.bootChanges = 0 end
    state.peers[id] = peer
    sample(id, now, true, "both")
    judge(peer, now)
    if not M.validatePeer(peer) then
      state.peers[id] = previous
      return nil, "reject"
    end
    return peer
  end
  local function seal(bodyMeta)
    local mac = cfg.mac(key, storageMessage(bodyMeta))
    if type(mac) ~= "string" then return nil, "storage mac failed" end
    bodyMeta.mac = mac
    return bodyMeta
  end
  function api.offer(section)
    if not enabled then return nil, "peer storage disabled" end
    local encoded, err = deps.h4b1.encode(section)
    if not encoded then return nil, err end
    local blob, macErr = seal(encoded)
    if not blob then return nil, macErr end
    remember(blob)
    local placement = state.placements[blob.key]
    if not placement or placement.rev ~= blob.rev or placement.hash ~= blob.hash then
      placement = {
        v = 1, key = blob.key, rev = blob.rev, hash = blob.hash, bytes = #blob.body,
        holders = {}, localCopy = true, state = "hot",
      }
      state.placements[blob.key] = placement
    else
      placement.bytes = #blob.body
      placement.localCopy = true
    end
    refresh(placement)
    return placement
  end
  local function goodLocal(placement)
    local blob = state.lru[placement.key]
    if not blob then return nil end
    local expect = cfg.mac(key, storageMessage(blob))
    if expect ~= blob.mac or deps.h4b1.hash(blob.body) ~= blob.hash then return nil end
    return blob
  end
  local function fetch(placement, id, pin)
    local blob = goodLocal(placement)
    if blob then return blob end
    local offset, parts = 0, {}
    local meta
    while true do
      local msg = stamp({
        hash = placement.hash, offset = offset, limit = PAGE,
      }, id, "cold-get", placement.hash, offset, offset)
      local reply, err = rpc(id, msg, "reply")
      if not reply or reply.hash ~= placement.hash then return nil, err or "unavailable" end
      if type(reply.bytes) ~= "string" then return nil, "reject" end
      parts[#parts + 1] = reply.bytes
      meta = reply
      offset = offset + #reply.bytes
      if offset >= (reply.total or offset) then break end
      if #reply.bytes == 0 then return nil, "unavailable" end
    end
    local body = table.concat(parts)
    if deps.h4b1.hash(body) ~= placement.hash then return nil, "hash" end
    local sealed = {
      key = meta.key, rev = meta.rev, codec = meta.codec, hash = placement.hash, body = body,
    }
    local expect = cfg.mac(key, storageMessage(sealed))
    if expect ~= meta.mac or meta.rev ~= placement.rev or meta.key ~= placement.key then
      return nil, "mac"
    end
    sealed.mac = meta.mac
    if pin ~= false then
      remember(sealed)
      placement.localCopy = true
    end
    return sealed
  end
  local function sendBlob(placement, id, pin)
    local peer = state.peers[id]
    if not peer or not peer.eligible or peer.holdsOfflineLease then return false, "ineligible" end
    if peer.role == "miner" and verifiedNonMiners(placement) < 2 then return false, "miner" end
    if peer.role == "miner" and cfg.minerExtras ~= true then return false, "miner" end
    local blob = goodLocal(placement)
    local err
    if not blob then
      for holderId, holder in pairs(placement.holders) do
        if holder.verifiedAt > 0 then
          blob, err = fetch(placement, holderId, pin)
          if blob then break end
        end
      end
    end
    if not blob then return false, err or "unavailable" end
    local holder = placement.holders[id]
    if holder and holder.verifiedAt > 0 and holder.ackAt > 0 then return true end
    local offset = 0
    while offset < #blob.body do
      local chunk = blob.body:sub(offset + 1, offset + PAGE)
      local msg = stamp({
        key = blob.key, rev = blob.rev, hash = blob.hash, mac = blob.mac, codec = blob.codec,
        total = #blob.body, offset = offset, bytes = chunk,
      }, id, "cold-put", blob.hash, offset, #chunk)
      local reply, putErr = rpc(id, msg, "reply")
      if not reply or reply.hash ~= blob.hash or reply.rev ~= blob.rev then
        return false, putErr or "put failed"
      end
      offset = offset + #chunk
    end
    holder = placement.holders[id] or { ackAt = 0, verifiedAt = 0, role = peer.role }
    holder.ackAt = clock()
    holder.role = peer.role
    placement.holders[id] = holder
    local has = stamp({ hashes = { blob.hash } }, id, "cold-has", blob.hash, 0, 1)
    local seen, hasErr = rpc(id, has, "reply")
    local row = seen and seen.present and seen.present[blob.hash]
    if row and row.size == #blob.body and row.rev == blob.rev then
      holder.verifiedAt = clock()
      return true
    end
    holder.verifiedAt = 0
    return false, hasErr or "unverified"
  end
  local function ranked()
    local list = {}
    for id, peer in pairs(state.peers) do
      list[#list + 1] = peer
    end
    table.sort(list, function(a, b)
      local ra, rb = RANK[a.role] or 9, RANK[b.role] or 9
      if ra ~= rb then return ra < rb end
      if a.freeReported ~= b.freeReported then return a.freeReported > b.freeReported end
      return a.id < b.id
    end)
    return list
  end
  local function holderVerified(placement, id)
    local holder = placement.holders[id]
    local peer = state.peers[id]
    return holder and peer and holder.verifiedAt > 0 and peer.eligible and not peer.holdsOfflineLease
  end
  function api.tick()
    if not enabled then return false, "peer storage disabled" end
    local now = clock()
    for id, peer in pairs(state.peers) do
      peer.holdsOfflineLease = deps.b2.holdsOfflineLease(id, cfg.leases) and true or false
      local ping = stamp({ quota = peer.quota }, id, "storage-ping", "", 0, 0)
      rpc(id, ping, "ping")
      judge(peer, now)
    end
    for _, placement in pairs(state.placements) do
      for id, holder in pairs(placement.holders) do
        local peer = state.peers[id]
        if peer and holder.ackAt > 0 and holder.verifiedAt == 0 and peer.eligible then
          local has = stamp({ hashes = { placement.hash } }, id, "cold-has", placement.hash, 0, 1)
          local seen = rpc(id, has, "reply")
          local row = seen and seen.present and seen.present[placement.hash]
          if row and row.size == placement.bytes and row.rev == placement.rev then
            holder.verifiedAt = clock()
          end
        end
        if peer and peer.holdsOfflineLease and holder.ackAt > 0 and verifiedNonMiners(placement) >= 2 then
          local drop = stamp({ hash = placement.hash }, id, "cold-drop", placement.hash, 0, 0)
          if rpc(id, drop, "reply") then placement.holders[id] = nil end
        end
      end
      local copies = refresh(placement)
      local repair = copies < 2
      for id, holder in pairs(placement.holders) do
        local peer = state.peers[id]
        if holder.verifiedAt > 0 and peer and (not peer.eligible or peer.score < MIN_SCORE) then
          repair = true
        end
      end
      if repair then
        if not goodLocal(placement) then
          for id, holder in pairs(placement.holders) do
            if holder.verifiedAt > 0 and fetch(placement, id, true) then break end
          end
        end
        if goodLocal(placement) then placement.localCopy = true end
        for _, peer in ipairs(ranked()) do
          local copiesNow = verifiedNonMiners(placement)
          local already = holderVerified(placement, peer.id)
          if peer.role == "miner" then
            if cfg.minerExtras == true and copiesNow >= 2 and not already then
              sendBlob(placement, peer.id)
            end
          elseif copiesNow < 2 and not already then
            sendBlob(placement, peer.id)
          end
        end
        refresh(placement)
      end
    end
    local budget = cfg.lruBudget
    if budget == nil then budget = 65536 end
    local guard = 0
    while lruBytes() > budget and guard < 64 do
      guard = guard + 1
      local dropped = false
      for i = 1, #state.order do
        local blobKey = state.order[i]
        local placement = state.placements[blobKey]
        if placement and verifiedNonMiners(placement) >= 2 then
          state.lru[blobKey] = nil
          table.remove(state.order, i)
          placement.localCopy = false
          refresh(placement)
          dropped = true
          break
        end
      end
      if not dropped then break end
    end
    for _, placement in pairs(state.placements) do
      if verifiedNonMiners(placement) >= 2 then
        local tight, roomy, tightFree = nil, nil, nil
        for id, holder in pairs(placement.holders) do
          local peer = state.peers[id]
          if peer and holder.verifiedAt > 0 and peer.eligible and peer.role ~= "miner" then
            if not tight or peer.freeReported < tightFree then
              tight, tightFree = peer, peer.freeReported
            end
          end
        end
        for _, peer in ipairs(ranked()) do
          if peer.eligible and peer.role ~= "miner" and not placement.holders[peer.id] then
            roomy = peer
            break
          end
        end
        if tight and roomy and roomy.freeReported >= tightFree + math.max(4096, placement.bytes * 4) then
          if sendBlob(placement, roomy.id, false) and holderVerified(placement, roomy.id) then
            local drop = stamp({ hash = placement.hash }, tight.id, "cold-drop", placement.hash, 0, 0)
            if rpc(tight.id, drop, "reply") then placement.holders[tight.id] = nil end
          end
        end
        break
      end
    end
    for _, placement in pairs(state.placements) do refresh(placement) end
    return true
  end
  function api.read(sectionKey)
    local placement = state.placements[sectionKey]
    if not placement then return deps.h4b1.unknown(sectionKey), "unknown" end
    if state.lru[sectionKey] then
      local blob = state.lru[sectionKey]
      local expect = cfg.mac(key, storageMessage(blob))
      if expect == blob.mac and deps.h4b1.hash(blob.body) == blob.hash then return blob end
    end
    for id, holder in pairs(placement.holders) do
      if holder.verifiedAt > 0 then
        local blob = fetch(placement, id)
        if blob then return blob end
      end
    end
    placement.localCopy = state.lru[sectionKey] ~= nil
    if not placement.localCopy then placement.state = "unknown" end
    return deps.h4b1.unknown(sectionKey), "unknown"
  end
  function api.save(fsapi, path)
    local text = canonical({ v = 1, peers = state.peers, placements = state.placements })
    if not text then return false, "state" end
    if key and text:find(key, 1, true) then return false, "key leaked" end
    return deps.h4a.save(fsapi, path, text)
  end
  function api.verified(sectionKey)
    local placement = state.placements[sectionKey]
    if not placement then return 0 end
    return verifiedNonMiners(placement)
  end
  return api
end

return M
