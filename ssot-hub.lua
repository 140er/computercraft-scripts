-- S1: SSOT hub profile, authority record, and handover.
-- One module, two profiles. hubProfile defaults off in ssot.lua, which loads this file only then.
-- Pairing keys stay in cfg.keys (ssot.keys on disk). They ride the handover pages and are not map cells.
local T1 = dofile("s1_t1.lua")
local Ledger = dofile("s1_h4c.lua")
local I1 = dofile("s1_i1.lua")
local B1 = dofile("s1_b1.lua")
local A = dofile("atomic.lua")
local M = { version = 1 }

local OPS = {
  ["hub-freeze"] = true, ["hub-export"] = true, ["hub-import"] = true, ["hub-take"] = true,
  ["hub-adopt"] = true, ["hub-put"] = true, ["hub-claim"] = true, ["hub-reissue"] = true,
  ["hub-mint"] = true, ["hub-ledger"] = true, ["authority"] = true,
}
local KINDS = { "plan", "fixture", "bot", "pose", "move", "lease", "code", "pairing" }
local FIELDS = { plan = "plans", fixture = "fixtures", bot = "bots", pose = "poses",
  move = "moves", lease = "leases", code = "codes" }
local PHASES = { idle = true, frozen = true, importing = true, taken = true, client = true }
local ALPH = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function canonical(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local keys, parts = {}, {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. canonical(k) .. "]=" .. canonical(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function digest(text)
  local n = 5381
  for i = 1, #text do n = (n * 33 + text:byte(i)) % 4294967296 end
  return string.format("%08x", n)
end

local function sortedKeys(map)
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  return keys
end

local function keyOf(kind, id)
  return kind .. ":" .. tostring(id)
end

function M.enabled(cfg)
  return type(cfg) == "table" and cfg.hubProfile == true
end

function M.owns(op)
  return OPS[op] == true
end

function M.budget(cfg)
  if type(cfg) == "table" and integer(cfg.budget, 1, 900000) then return cfg.budget end
  local profile = type(cfg) == "table" and cfg.profile == "hub" and "hub" or "server"
  return Ledger.policy(profile).budget
end

local function authorityOk(a)
  return type(a) == "table" and a.v == 1 and integer(a.holder, 0, 2147483647)
    and integer(a.epoch, 0, 2147483647) and integer(a.since, 0, 9007199254740991)
    and (a.kind == "hub" or a.kind == "server") and type(a.frozen) == "boolean"
end

function M.validKeys(v)
  if type(v) ~= "table" or v.v ~= 1 or type(v.keys) ~= "table" then return false end
  local n = 0
  for id, rec in pairs(v.keys) do
    n = n + 1
    if n > 32 or type(id) ~= "string" or #id == 0 or #id > 80 or type(rec) ~= "table" then return false end
    if type(rec.key) ~= "string" or #rec.key < 16 or #rec.key > 128 then return false end
  end
  return true
end

local function mapOk(map, limit, check)
  if type(map) ~= "table" then return false end
  local n = 0
  for id, rec in pairs(map) do
    n = n + 1
    if n > limit then return false end
    if type(id) ~= "string" and type(id) ~= "number" then return false end
    if check and not check(rec) then return false end
  end
  return true
end

function M.valid(s)
  if type(s) ~= "table" then return false end
  if s.authority ~= nil and not authorityOk(s.authority) then return false end
  if s.handover ~= nil then
    local h = s.handover
    if type(h) ~= "table" or h.v ~= 1 or not PHASES[h.phase] then return false end
    if h.imported ~= nil and type(h.imported) ~= "table" then return false end
    if h.reissue ~= nil and type(h.reissue) ~= "table" then return false end
    if h.manifest ~= nil and type(h.manifest) ~= "table" then return false end
  end
  if s.plans ~= nil and not mapOk(s.plans, 1024, T1.plan) then return false end
  if s.fixtures ~= nil and not mapOk(s.fixtures, 1024, T1.fixture) then return false end
  if s.bots ~= nil and not mapOk(s.bots, 1024, T1.bot) then return false end
  if s.leases ~= nil and not mapOk(s.leases, 1024, B1.lease) then return false end
  if s.codes ~= nil and not mapOk(s.codes, 1024, I1.code) then return false end
  if s.idCounter ~= nil and not integer(s.idCounter, 0, 2147483647) then return false end
  if s.reissued ~= nil and type(s.reissued) ~= "table" then return false end
  if s.handover ~= nil and s.handover.records ~= nil and type(s.handover.records) ~= "table" then return false end
  return true
end

function M.prepare(s, cfg, clock)
  if cfg.profile ~= "hub" and cfg.profile ~= "server" then cfg.profile = "server" end
  local holder = cfg.holder
  if type(holder) ~= "number" and type(os) == "table" and type(os.getComputerID) == "function" then
    holder = os.getComputerID()
  end
  if not integer(holder, 0, 2147483647) then holder = 0 end
  cfg.holder = holder
  if type(cfg.keys) ~= "table" then cfg.keys = {} end
  if type(cfg.saveKeys) ~= "function" then cfg.saveKeys = function() return true end end
  s.plans, s.fixtures, s.bots = s.plans or {}, s.fixtures or {}, s.bots or {}
  s.leases, s.codes = s.leases or {}, s.codes or {}
  s.idCounter = s.idCounter or 0
  s.reissued = s.reissued or {}
  if type(s.handover) ~= "table" then
    s.handover = { v = 1, phase = "idle", imported = {}, reissue = {} }
  end
  s.handover.imported = s.handover.imported or {}
  s.handover.reissue = s.handover.reissue or {}
  if s.authority == nil then
    local hub = cfg.profile == "hub"
    local epoch = 1
    if not hub and cfg.joining == true then epoch = 0 end
    s.authority = {
      v = 1, holder = holder, epoch = epoch, since = clock(),
      kind = hub and "hub" or "server", frozen = false,
    }
  end
end

local function canIssue(s, cfg)
  local a = s.authority
  if not authorityOk(a) or a.frozen or a.holder ~= cfg.holder or a.epoch < 1 then return false end
  local phase = s.handover and s.handover.phase or "idle"
  if phase == "importing" or phase == "frozen" or phase == "client" then return false end
  return true
end

local function deny(s)
  if s.authority and s.authority.frozen then return { ok = false, error = "frozen" } end
  return { ok = false, error = "not authority" }
end

local function sizeOf(value)
  local ok, text = pcall(textutils.serialize, value)
  if not ok then return nil end
  return #text
end

local function overBudget(s, cfg)
  local n = sizeOf(s)
  if not n then return true end
  return n > M.budget(cfg)
end

local function mintId(s, cfg)
  s.idCounter = s.idCounter + 1
  return string.format("p:%d:%d", cfg.holder, s.idCounter)
end

local function mintCode(seed)
  local n = seed % 2147483647
  local out = {}
  for i = 1, 10 do
    n = (n * 48271 + i) % 2147483647
    local idx = (n % 32) + 1
    out[i] = ALPH:sub(idx, idx)
  end
  return table.concat(out)
end

local function collect(s, cfg)
  local records = {}
  for _, kind in ipairs(KINDS) do
    local map = kind == "pairing" and cfg.keys or s[FIELDS[kind]]
    for _, id in ipairs(sortedKeys(map or {})) do
      records[#records + 1] = { kind = kind, id = tostring(id), body = A.copy(map[id]) }
    end
  end
  return records
end

local function manifestFrom(s, cfg, records)
  local ids = {}
  for i, rec in ipairs(records) do ids[i] = keyOf(rec.kind, rec.id) end
  local reissue = A.copy(s.handover.reissue or {})
  return {
    v = 1, hash = digest(canonical({ records = records, reissue = reissue })),
    ids = ids, count = #records, reissue = reissue, authority = A.copy(s.authority),
  }
end

-- Pairing bodies stay in cfg.keys. The frozen snapshot keeps every other record.
local function withoutKeys(records)
  local stored = {}
  for _, rec in ipairs(records) do
    if rec.kind ~= "pairing" then stored[#stored + 1] = rec end
  end
  return stored
end

local function withKeys(stored, cfg)
  local records = {}
  for i, rec in ipairs(stored or {}) do records[i] = rec end
  for _, id in ipairs(sortedKeys(cfg.keys or {})) do
    records[#records + 1] = { kind = "pairing", id = tostring(id), body = A.copy(cfg.keys[id]) }
  end
  return records
end

local function pageCap(cfg)
  if integer(cfg.pageRecords, 1, 64) then return cfg.pageRecords end
  return 16
end

local function slice(records, cursor, cfg, pageBytes)
  if not integer(cursor, 0, #records) then return nil, "bad cursor" end
  local budget = (pageBytes or 8192) - 700
  if budget < 240 then budget = 240 end
  local cap = pageCap(cfg)
  local out, i = {}, cursor
  while i < #records and #out < cap do
    local trial = {}
    for n, rec in ipairs(out) do trial[n] = rec end
    trial[#trial + 1] = records[i + 1]
    local n = sizeOf(trial)
    if not n or n > budget then
      if #out == 0 then return nil, "page budget too small" end
      break
    end
    out, i = trial, i + 1
  end
  return out, i
end

local function sameBody(a, b)
  return canonical(a) == canonical(b)
end

local function dataCount(s, cfg)
  local n = 0
  for _, field in pairs(FIELDS) do
    for _ in pairs(s[field] or {}) do n = n + 1 end
  end
  for _ in pairs(cfg.keys or {}) do n = n + 1 end
  return n
end

local function lookup(s, cfg, kind, id)
  if kind == "pairing" then return cfg.keys, id end
  local field = FIELDS[kind]
  if not field then return nil end
  if kind == "pose" or kind == "move" then
    local n = tonumber(id)
    if not integer(n, 0, 2147483647) then return nil end
    return s[field], n
  end
  return s[field], id
end

local function acceptBody(kind, id, body, poseOk)
  if type(body) ~= "table" then return false end
  if kind == "plan" then return T1.plan(body) and body.id == id end
  if kind == "fixture" then return T1.fixture(body) and body.id == id end
  if kind == "bot" then return T1.bot(body) and body.id == id end
  if kind == "code" then return I1.code(body) and body.code == id end
  if kind == "lease" then return B1.lease(body) and body.id == id end
  if kind == "pairing" then
    return body.id == id and type(body.key) == "string" and #body.key >= 16 and #body.key <= 128
      and integer(body.computer, 0, 2147483647) and body.v == 1
  end
  if kind == "pose" then return poseOk(body) and type(body.boot) == "string" and #body.boot > 0 and #body.boot <= 80 end
  if kind == "move" then return poseOk(body.from) and poseOk(body.to) end
  return false
end

local function wipeKeys(keys, snap)
  for k in pairs(keys) do keys[k] = nil end
  for k, v in pairs(snap) do keys[k] = v end
end

local function applyPage(s, cfg, records, manifest, poseOk)
  local idSet = {}
  for _, id in ipairs(manifest.ids or {}) do idSet[id] = true end
  local snap = A.copy({
    plans = s.plans, fixtures = s.fixtures, bots = s.bots, poses = s.poses,
    moves = s.moves, leases = s.leases, codes = s.codes, imported = s.handover.imported,
  })
  local keySnap = A.copy(cfg.keys)
  for _, rec in ipairs(records) do
    if type(rec) ~= "table" or type(rec.kind) ~= "string" or rec.id == nil then
      return false, "bad record", snap, keySnap
    end
    local id = keyOf(rec.kind, rec.id)
    if not idSet[id] then return false, "foreign id", snap, keySnap end
    local body = A.copy(rec.body)
    if not acceptBody(rec.kind, rec.id, body, poseOk) then return false, "bad record", snap, keySnap end
    local map, storedId = lookup(s, cfg, rec.kind, rec.id)
    if not map then return false, "bad record", snap, keySnap end
    local current = map[storedId]
    if current == nil then
      map[storedId] = body
    elseif not sameBody(current, body) then
      return false, "id conflict", snap, keySnap
    end
    s.handover.imported[id] = true
  end
  return true, nil, snap, keySnap
end

local function restore(s, cfg, snap, keySnap)
  s.plans, s.fixtures, s.bots = snap.plans, snap.fixtures, snap.bots
  s.poses, s.moves, s.leases, s.codes = snap.poses, snap.moves, snap.leases, snap.codes
  s.handover.imported = snap.imported
  wipeKeys(cfg.keys, keySnap)
end

local function manifestOk(m)
  return type(m) == "table" and m.v == 1 and type(m.hash) == "string" and #m.hash == 8
    and type(m.ids) == "table" and type(m.reissue) == "table" and integer(m.count, 0, 8192)
    and authorityOk(m.authority) and m.authority.frozen == true and m.authority.kind == "hub"
    and #m.ids == m.count
end

local function putRecord(s, cfg, kind, body, poseOk)
  if kind == "code" then
    if type(body.code) ~= "string" then
      if type(body.id) == "string" then body.code = body.id else return nil, "bad record" end
    end
    body.id = body.code
  elseif kind == "plan" or kind == "fixture" or kind == "bot" or kind == "lease" then
    if type(body.id) ~= "string" or body.id == "" then body.id = mintId(s, cfg) end
  end
  local storedId = kind == "code" and body.code or body.id
  if not acceptBody(kind, storedId, body, poseOk) then return nil, "bad record" end
  if kind == "pairing" then
    local current = cfg.keys[storedId]
    if current ~= nil and not sameBody(current, body) then return nil, "id conflict" end
    if current == nil then
      cfg.keys[storedId] = A.copy(body)
      if sizeOf(cfg.keys) == nil or sizeOf(cfg.keys) > 65536 then
        cfg.keys[storedId] = nil
        return nil, "capacity"
      end
      local ok = cfg.saveKeys()
      if ok == false then
        cfg.keys[storedId] = nil
        return nil, "key store"
      end
    end
    return storedId
  end
  local map = s[FIELDS[kind]]
  if map[storedId] ~= nil and not sameBody(map[storedId], body) then return nil, "id conflict" end
  local previous = map[storedId]
  map[storedId] = A.copy(body)
  if overBudget(s, cfg) then
    map[storedId] = previous
    return nil, "capacity"
  end
  return storedId
end

function M.run(s, cfg, clock, id, m, pageBytes, poseOk)
  local op = m.op
  if op == "authority" or op == "hub-ledger" then
    local profile = cfg.profile == "hub" and "hub" or "server"
    local policy = Ledger.policy(profile)
    if integer(cfg.budget, 1, 900000) then policy.budget = cfg.budget end
    local used = sizeOf(s) or policy.budget
    local ledger = Ledger.ledger(used, policy)
    if op == "hub-ledger" then
      return { ok = true, policy = policy, ledger = ledger, canIssue = canIssue(s, cfg) }
    end
    return { ok = true, authority = A.copy(s.authority), phase = s.handover.phase, canIssue = canIssue(s, cfg) }
  end
  if op == "hub-mint" then
    if not canIssue(s, cfg) then return deny(s) end
    return { ok = true, id = mintId(s, cfg) }
  end
  if op == "hub-put" then
    if not canIssue(s, cfg) then return deny(s) end
    if m.kind ~= "plan" and m.kind ~= "fixture" and m.kind ~= "bot"
      and m.kind ~= "lease" and m.kind ~= "code" and m.kind ~= "pairing" then
      return { ok = false, error = "bad record" }
    end
    if type(m.body) ~= "table" then return { ok = false, error = "bad record" } end
    local body = A.copy(m.body)
    local stored, err = putRecord(s, cfg, m.kind, body, poseOk)
    if not stored then return { ok = false, error = err } end
    return { ok = true, id = stored }
  end
  if op == "hub-claim" then
    if not canIssue(s, cfg) then return deny(s) end
    if not I1.proof(m.proof) then return { ok = false, error = "bad proof" } end
    if type(m.code) ~= "string" then return { ok = false, error = "unknown code" } end
    local code = s.codes[m.code]
    if type(code) ~= "table" then return { ok = false, error = "unknown code" } end
    if code.invalidated == true then return { ok = false, error = "invalidated" } end
    if code.used == true then return { ok = false, error = "used" } end
    if code.untilAt <= clock() then return { ok = false, error = "expired" } end
    code.used = true
    return { ok = true, code = m.code }
  end
  if op == "hub-freeze" then
    if cfg.profile ~= "hub" or s.authority.kind ~= "hub" or s.authority.holder ~= cfg.holder then
      return { ok = false, error = "hub profile required" }
    end
    if s.handover.phase == "client" then return { ok = false, error = "not authority" } end
    if s.handover.phase == "frozen" and s.authority.frozen and type(s.handover.manifest) == "table" then
      if s.handover.external ~= true and type(s.handover.records) ~= "table" then
        local records = collect(s, cfg)
        if manifestFrom(s, cfg, records).hash ~= s.handover.manifest.hash then
          return { ok = false, error = "snapshot changed" }
        end
        s.handover.records = withoutKeys(records)
        if overBudget(s, cfg) then s.handover.records, s.handover.external = nil, true end
      end
      return { ok = true, hash = s.handover.manifest.hash, count = s.handover.manifest.count }
    end
    local mid = {}
    for codeId, code in pairs(s.codes) do
      if type(code) == "table" and code.claiming == true and code.used ~= true and code.invalidated ~= true then
        mid[#mid + 1] = codeId
      end
    end
    table.sort(mid)
    for _, codeId in ipairs(mid) do
      s.codes[codeId].invalidated = true
      s.handover.reissue[#s.handover.reissue + 1] = codeId
    end
    s.authority.frozen = true
    s.handover.phase = "frozen"
    local records = collect(s, cfg)
    s.handover.manifest = manifestFrom(s, cfg, records)
    s.handover.records = withoutKeys(records)
    if overBudget(s, cfg) then s.handover.records, s.handover.external = nil, true end
    return { ok = true, hash = s.handover.manifest.hash, count = s.handover.manifest.count }
  end
  if op == "hub-export" then
    if cfg.profile ~= "hub" or s.handover.phase ~= "frozen" or not s.authority.frozen then
      return { ok = false, error = "not frozen" }
    end
    local records = s.handover.external and collect(s, cfg) or withKeys(s.handover.records or {}, cfg)
    if manifestFrom(s, cfg, records).hash ~= s.handover.manifest.hash then
      return { ok = false, error = "snapshot changed" }
    end
    local page, nxt = slice(records, m.cursor or 0, cfg, pageBytes)
    if not page then return { ok = false, error = nxt } end
    local copy = {}
    for i, rec in ipairs(page) do copy[i] = A.copy(rec) end
    return {
      ok = true, cursor = m.cursor or 0, next = nxt, done = nxt == #records,
      manifest = A.copy(s.handover.manifest), records = copy,
    }
  end
  if op == "hub-import" then
    if cfg.profile ~= "server" then return { ok = false, error = "server profile required" } end
    if not manifestOk(m.manifest) then return { ok = false, error = "bad manifest" } end
    if type(m.records) ~= "table" then return { ok = false, error = "bad record" } end
    local phase = s.handover.phase
    if phase == "taken" or phase == "importing" then
      if not s.handover.manifest or s.handover.manifest.hash ~= m.manifest.hash then
        return { ok = false, error = "manifest changed" }
      end
    else
      if phase ~= "idle" then return { ok = false, error = "bad manifest" } end
      if cfg.joining ~= true and s.authority.epoch ~= 0 then return { ok = false, error = "not a joining server" } end
      if dataCount(s, cfg) > 0 then return { ok = false, error = "server not empty" } end
    end
    if phase == "taken" then return { ok = true, imported = s.handover.manifest.count } end
    local ok, err, snap, keySnap = applyPage(s, cfg, m.records, m.manifest, poseOk)
    if not ok then
      restore(s, cfg, snap, keySnap)
      return { ok = false, error = err }
    end
    if phase == "idle" then
      s.handover.manifest = A.copy(m.manifest)
      s.handover.reissue = A.copy(m.manifest.reissue or {})
      s.handover.phase = "importing"
    end
    if not cfg.saveKeys() then
      restore(s, cfg, snap, keySnap)
      if phase == "idle" then
        s.handover.manifest, s.handover.phase, s.handover.reissue = nil, "idle", {}
      end
      return { ok = false, error = "key store" }
    end
    return { ok = true, imported = #m.records }
  end
  if op == "hub-take" then
    if cfg.profile ~= "server" then return { ok = false, error = "server profile required" } end
    local manifest = s.handover.manifest
    if not manifestOk(manifest) then return { ok = false, error = "incomplete import" } end
    local records = collect(s, cfg)
    local built = manifestFrom(s, cfg, records)
    if built.hash ~= manifest.hash then return { ok = false, error = "hash mismatch" } end
    local have = {}
    for _, rec in ipairs(records) do have[keyOf(rec.kind, rec.id)] = true end
    for _, id in ipairs(manifest.ids) do
      if not have[id] then return { ok = false, error = "incomplete import" } end
    end
    local expect = manifest.authority.epoch + 1
    local a = s.authority
    if s.handover.phase == "taken" and a.holder == cfg.holder and a.kind == "server"
      and a.frozen == false and a.epoch == expect then
      return { ok = true, authority = A.copy(a) }
    end
    if s.handover.phase ~= "importing" and not (s.handover.phase == "idle" and manifest.count == 0) then
      return { ok = false, error = "incomplete import" }
    end
    s.authority = {
      v = 1, holder = cfg.holder, epoch = expect, since = clock(), kind = "server", frozen = false,
    }
    s.handover.phase = "taken"
    return { ok = true, authority = A.copy(s.authority) }
  end
  if op == "hub-adopt" then
    if cfg.profile ~= "hub" then return { ok = false, error = "hub profile required" } end
    local inc = m.authority
    if not authorityOk(inc) or inc.kind ~= "server" or inc.frozen ~= false then
      return { ok = false, error = "bad authority" }
    end
    if s.handover.phase == "client" and s.authority.holder == inc.holder and s.authority.epoch == inc.epoch then
      return { ok = true, authority = A.copy(s.authority) }
    end
    if s.handover.phase ~= "frozen" or s.authority.frozen ~= true or type(s.handover.manifest) ~= "table" then
      return { ok = false, error = "not frozen" }
    end
    if inc.epoch ~= s.authority.epoch + 1 or inc.holder == cfg.holder then
      return { ok = false, error = "bad epoch" }
    end
    if m.hash ~= s.handover.manifest.hash then return { ok = false, error = "bad manifest" } end
    s.authority = {
      v = 1, holder = inc.holder, epoch = inc.epoch, since = inc.since, kind = "server", frozen = false,
    }
    s.handover.phase = "client"
    s.handover.records = nil
    return { ok = true, authority = A.copy(s.authority) }
  end
  if op == "hub-reissue" then
    if s.handover.phase ~= "taken" or not canIssue(s, cfg) then return deny(s) end
    local created = {}
    local list = s.handover.manifest and s.handover.manifest.reissue or s.handover.reissue or {}
    for _, oldId in ipairs(list) do
      local known = s.reissued[oldId]
      if known then
        created[#created + 1] = known
      else
        local old = s.codes[oldId]
        if type(old) ~= "table" or old.invalidated ~= true then return { ok = false, error = "bad record" } end
        local ttl = old.untilAt - old.issuedAt
        if type(ttl) ~= "number" or ttl < 1000 then ttl = 120000 end
        s.idCounter = s.idCounter + 1
        local code = mintCode(cfg.holder * 100000 + s.idCounter)
        if s.codes[code] then return { ok = false, error = "id conflict" } end
        local now = clock()
        local body = {
          v = 1, code = code, issuer = cfg.holder, issuedAt = now, untilAt = now + ttl,
          role = old.role, used = false, attempts = 0, planBot = old.planBot or false,
          claiming = false, invalidated = false,
        }
        if not I1.code(body) then return { ok = false, error = "bad record" } end
        s.codes[code] = body
        s.reissued[oldId] = code
        created[#created + 1] = code
      end
    end
    return { ok = true, codes = created }
  end
  return { ok = false, error = "unknown operation" }
end

return M
