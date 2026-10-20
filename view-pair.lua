-- Pairing a second hub. The request lives on the enrol code record.
-- step is the only transition. commitController is the only writer of controllers.

local ViewPair = {}
local PROTOCOL = "fleetserver"
local ACK_WAIT = 4000
-- Enrol off never answers. Waiting out Enrol.ttl would freeze a second hub at boot.

local Enrol
local function enrol()
  if not Enrol then Enrol = dofile("enrol.lua") end
  return Enrol
end

-- server 0 is views.cfg.example and is still an explicit pair.
function ViewPair.explicit(views)
  if type(views) ~= "table" then return false end
  local server, secret = views.server, views.secret
  if type(server) ~= "number" or server % 1 ~= 0 or server < 0 or server > 2147483647 then return false end
  if type(secret) ~= "string" or #secret < 16 or #secret > 128 then return false end
  return true
end

function ViewPair.hasLocalKey(ssotCfg, computerId)
  if type(ssotCfg) ~= "table" or type(ssotCfg.controllers) ~= "table" or type(computerId) ~= "number" then
    return false
  end
  local key = ssotCfg.controllers[tostring(computerId)]
  return type(key) == "string" and #key >= 16 and #key <= 128
end

function ViewPair.decide(views, facts)
  facts = type(facts) == "table" and facts or {}
  local enabled = type(views) == "table" and views.enabled
  local suppress = ViewPair.explicit(views) or facts.localKey == true
  local ask = not suppress and (enabled == true or facts.ar == true)
  if facts.hubNameFree then
    return { ok = true, hostname = "hub", runView = enabled == true, ask = ask }
  end
  local hostError = facts.hostError
  local inUse = tostring(hostError or ""):find("Hostname in use", 1, true) ~= nil
  if not inUse or enabled == false then
    return { ok = false, error = hostError }
  end
  return {
    ok = true, hostname = "view-" .. tostring(facts.computerId), runView = true, ask = not suppress,
  }
end

function ViewPair.localSecret(views, ssotCfg, computerId)
  if type(views) == "table" and type(views.secret) == "string"
    and #views.secret >= 16 and #views.secret <= 128 then
    return views.secret, views.server
  end
  if ViewPair.hasLocalKey(ssotCfg, computerId) then
    return ssotCfg.controllers[tostring(computerId)]
  end
end

function ViewPair.fillViews(views, serverId, secret, enableView)
  local out = {}
  if type(views) == "table" then
    for key, value in pairs(views) do out[key] = value end
  end
  out.server, out.secret = serverId, secret
  if enableView then out.enabled = true end
  return out
end

function ViewPair.requestPhase(rec, cfg, paired, now)
  if type(rec) ~= "table" then return "absent" end
  local stored = type(cfg) == "table" and type(cfg.controllers) == "table"
    and cfg.controllers[tostring(rec.forId)]
  local key = type(paired) == "table" and paired.key
  local sameCode = type(paired) == "table" and (paired.codeId == nil or paired.codeId == rec.id)
  if type(key) == "string" and stored == key and sameCode and (rec.used or paired.codeId == rec.id) then
    return "committed"
  end
  if rec.burned then return "denied" end
  if type(now) == "number" and type(rec.untilAt) == "number" and now > rec.untilAt then return "expired" end
  if rec.used and type(key) == "string" and stored ~= key and sameCode then return "claimed" end
  if rec.held and not rec.used then return "shown" end
  if not rec.held and not rec.used and not rec.burned and rec.forId ~= nil then return "released" end
  return "absent"
end

local function controllerKey(cfg, computerId)
  if type(cfg) ~= "table" or type(cfg.controllers) ~= "table" then return nil end
  local key = cfg.controllers[tostring(computerId)]
  if type(key) == "string" and #key >= 16 and #key <= 128 then return key end
end

local function controllerCount(cfg)
  local n = 0
  if type(cfg) == "table" and type(cfg.controllers) == "table" then
    for _ in pairs(cfg.controllers) do n = n + 1 end
  end
  return n
end

local function hasRoom(cfg, computerId)
  if controllerKey(cfg, computerId) then return true end
  return controllerCount(cfg) < 32
end

local function commitController(cfg, computerId, key, saveCfg)
  if type(computerId) ~= "number" or computerId % 1 ~= 0 or computerId < 0 or computerId > 2147483647 then
    return false
  end
  if type(key) ~= "string" or #key < 16 or #key > 128 or type(cfg) ~= "table" or type(saveCfg) ~= "function" then
    return false
  end
  if type(cfg.controllers) ~= "table" then cfg.controllers = {} end
  local id = tostring(computerId)
  local prev = cfg.controllers[id]
  if prev == key then return true end
  if prev == nil and controllerCount(cfg) >= 32 then return false end
  cfg.controllers[id] = key
  local ok, saved = pcall(saveCfg)
  if not ok or saved == false then
    if prev == nil then cfg.controllers[id] = nil else cfg.controllers[id] = prev end
    return false
  end
  return true
end

local function issueForView(store, now, issuer, computerId)
  local issued = enrol().issue(store, now, issuer, {
    role = "view", held = true, forId = computerId,
  }, math.random)
  if not issued then return nil end
  for id, rec in pairs(store.codes) do
    if id ~= issued.id and type(rec) == "table" and rec.forId == computerId and not rec.burned then
      rec.burned, rec.used, rec.held, rec.code = true, true, false, nil
    end
  end
  return store.codes[issued.id]
end

local function pairedFor(store, computerId)
  if type(store) ~= "table" or type(store.paired) ~= "table" then return nil end
  return store.paired[tostring(computerId)]
end

local RANK = { shown = 5, released = 4, claimed = 3, committed = 2, expired = 1, denied = 0, absent = 0 }

local function selectRec(store, cfg, computerId, now)
  local best, bestPhase, bestRank, bestAt
  for _, rec in pairs(store.codes or {}) do
    if type(rec) == "table" and rec.forId == computerId then
      local phase = ViewPair.requestPhase(rec, cfg, pairedFor(store, computerId), now)
      local rank = RANK[phase] or 0
      local at = rec.issuedAt or 0
      if not best or rank > bestRank or (rank == bestRank and at > bestAt) then
        best, bestPhase, bestRank, bestAt = rec, phase, rank, at
      end
    end
  end
  return best, bestPhase or "absent"
end

local function delivery(rec)
  if type(rec) ~= "table" or type(rec.code) ~= "string" then return nil end
  return { computerId = rec.forId, codeId = rec.id, code = rec.code }
end

function ViewPair.step(store, cfg, event, now)
  if type(store) ~= "table" or type(event) ~= "table" then return {} end
  store.codes, store.paired = store.codes or {}, store.paired or {}
  cfg = type(cfg) == "table" and cfg or {}
  local computerId = event.computerId
  if event.t == "ask" then
    local paired = pairedFor(store, computerId)
    local stored = controllerKey(cfg, computerId)
    if event.hasLocal and type(paired) == "table" and type(paired.key) == "string" and stored ~= paired.key
      and (event.codeId == nil or event.codeId == paired.codeId) and hasRoom(cfg, computerId) then
      return { key = paired.key, keyId = computerId, done = true }
    end
    if event.hasLocal and stored then return { done = true } end
    if event.hasLocal then return { ack = true } end
    local rec, phase = selectRec(store, cfg, computerId, now)
    if phase == "shown" then return { ack = true } end
    if phase == "released" then
      local row = delivery(rec)
      if row then return { deliver = row } end
    end
    if phase == "claimed" then return { ack = true } end
    local issued = issueForView(store, now, event.issuer or 0, computerId)
    if not issued then return {} end
    return { saveStore = true, ack = true }
  end
  if event.t == "accept" then
    local rec, phase = selectRec(store, cfg, computerId, now)
    if phase == "shown" then
      if not hasRoom(cfg, computerId) then return { full = true } end
      rec.held = false
      return { saveStore = true, deliver = delivery(rec) }
    end
    if phase == "released" then
      local row = delivery(rec)
      if row then return { deliver = row } end
    end
    return {}
  end
  if event.t == "deny" then
    local rec, phase = selectRec(store, cfg, computerId, now)
    if phase == "shown" or phase == "released" then
      rec.burned, rec.used, rec.held, rec.code = true, true, false, nil
      return { saveStore = true, denied = true }
    end
    return {}
  end
  if event.t == "claim" then
    local paired = pairedFor(store, computerId)
    if type(paired) ~= "table" or type(paired.key) ~= "string" then return {} end
    local rec = event.codeId and store.codes[event.codeId] or selectRec(store, cfg, computerId, now)
    if type(rec) ~= "table" or rec.forId ~= computerId or rec.role ~= "view" or rec.held or not rec.used then
      return {}
    end
    if event.role ~= nil and event.role ~= "view" then return {} end
    if paired.codeId ~= nil and paired.codeId ~= rec.id then return {} end
    if controllerKey(cfg, computerId) == paired.key then return { done = true } end
    if not hasRoom(cfg, computerId) then return { full = true } end
    return { key = paired.key, keyId = computerId, done = true }
  end
  return {}
end

local function loadStore(io)
  local store, err = enrol().load(io.fs)
  if not store then return nil, err end
  store.codes, store.paired = store.codes or {}, store.paired or {}
  return store
end

local function saveStore(io, store)
  return enrol().save(io.fs, store)
end

local function sendTo(io, computerId, message)
  if io.rednet and io.rednet.send then io.rednet.send(computerId, message, PROTOCOL) end
end

local function sendAck(io, computerId, rid)
  sendTo(io, computerId, {
    v = 1, type = "ssot_reply", ok = true, pending = true, rid = rid, server = io.computerId,
  })
end

local function sendCode(io, computerId, codeId, code)
  sendTo(io, computerId, {
    v = 1, type = "pair-code", codeId = codeId, code = code, server = io.computerId,
  })
end

local function sendDone(io, computerId)
  sendTo(io, computerId, { v = 1, type = "pair-done", ok = true, server = io.computerId })
end

local function applyStore(io, effect, store)
  if effect.saveStore and not saveStore(io, store) then return false end
  return true
end

local function applyKey(io, effect)
  if not effect.key then return true end
  return commitController(io.cfg, effect.keyId, effect.key, io.save)
end

function ViewPair.rowText(row)
  return "#" .. tostring(row.computerId) .. " " .. tostring(row.code) .. " " .. tostring(row.untilAt)
end

function ViewPair.pending(io, now)
  if type(io) ~= "table" or type(io.cfg) ~= "table" or io.cfg.enrol ~= true then return {} end
  local store = loadStore(io)
  if not store then return {} end
  local rows = {}
  for _, rec in pairs(store.codes) do
    if ViewPair.requestPhase(rec, io.cfg, pairedFor(store, rec.forId), now) == "shown" and rec.code then
      rows[#rows + 1] = { computerId = rec.forId, code = rec.code, untilAt = rec.untilAt }
    end
  end
  table.sort(rows, function(a, b) return tostring(a.computerId) < tostring(b.computerId) end)
  return rows
end

function ViewPair.offer(io, senderId, msg)
  if type(io) ~= "table" or type(io.cfg) ~= "table" or io.cfg.enrol ~= true then return false end
  if type(msg) ~= "table" or msg.op ~= "enrol-issue" or msg.role ~= "view" then return false end
  if msg.secret ~= nil and msg.secret ~= "" then return false end
  if type(senderId) ~= "number" or senderId % 1 ~= 0 or senderId < 0 or senderId > 2147483647 then
    return false
  end
  local store = loadStore(io)
  if not store then return false end
  local effect = ViewPair.step(store, io.cfg, {
    t = "ask", computerId = senderId, hasLocal = msg.hasLocal == true,
    codeId = msg.codeId, issuer = io.computerId,
  }, io.now())
  if not applyStore(io, effect, store) then return false end
  if not applyKey(io, effect) then return true end
  if effect.deliver then sendCode(io, senderId, effect.deliver.codeId, effect.deliver.code)
  elseif effect.ack then sendAck(io, senderId, msg.rid) end
  if effect.done then sendDone(io, senderId) end
  return true
end

function ViewPair.accept(io, computerId)
  local store = loadStore(io)
  if not store then return "No request #" .. tostring(computerId) end
  local effect = ViewPair.step(store, io.cfg, { t = "accept", computerId = computerId }, io.now())
  if effect.saveStore then saveStore(io, store) end
  if effect.deliver then
    sendCode(io, computerId, effect.deliver.codeId, effect.deliver.code)
    if io.log then io.log(computerId, "accept") end
    return "Accepted #" .. tostring(computerId)
  end
  if effect.full then return "Full #" .. tostring(computerId) end
  return "No request #" .. tostring(computerId)
end

function ViewPair.deny(io, computerId)
  local store = loadStore(io)
  if not store then return "No request #" .. tostring(computerId) end
  local effect = ViewPair.step(store, io.cfg, { t = "deny", computerId = computerId }, io.now())
  if effect.saveStore then saveStore(io, store) end
  if effect.denied then
    if io.log then io.log(computerId, "deny") end
    return "Denied #" .. tostring(computerId)
  end
  return "No request #" .. tostring(computerId)
end

function ViewPair.observe(io, senderId, op, result)
  if op ~= "enrol-claim" or type(result) ~= "table" or result.ok ~= true then return end
  if result.role ~= nil and result.role ~= "view" then return end
  local store = loadStore(io)
  if not store then return end
  local effect = ViewPair.step(store, io.cfg, {
    t = "claim", computerId = senderId, codeId = result.codeId, role = result.role or "view",
  }, io.now())
  if effect.saveStore then saveStore(io, store) end
  if effect.key and not applyKey(io, effect) then return end
  if effect.done then sendDone(io, senderId) end
end

local function readTable(fs, name)
  if not fs.exists(name) then return {} end
  local h = fs.open(name, "r")
  if not h then return {} end
  local text = h.readAll()
  h.close()
  local ok, parsed = pcall(textutils.unserialize, text or "")
  if ok and type(parsed) == "table" then return parsed end
  return {}
end

local function writeViews(fs, views)
  local text = textutils.serialize(views)
  local tmp = "views.cfg.tmp"
  local h = fs.open(tmp, "w")
  if not h then return nil end
  h.write(text)
  h.close()
  local back = fs.open(tmp, "r")
  if not back then return nil end
  local got = back.readAll()
  back.close()
  if got ~= text then
    fs.delete(tmp)
    return nil
  end
  if fs.exists("views.cfg") then fs.delete("views.cfg") end
  fs.move(tmp, "views.cfg")
  local loaded = textutils.unserialize(got)
  if type(loaded) ~= "table" or loaded.server ~= views.server or loaded.secret ~= views.secret
    or (views.enabled == true and loaded.enabled ~= true) then
    fs.delete("views.cfg")
    return nil
  end
  return loaded
end

local function lookupId(lookup)
  if type(lookup) == "function" then return lookup() end
  return lookup
end

local function hex8(n)
  return string.format("%08x", math.floor(tonumber(n) or 0) % 4294967296)
end

function ViewPair.client(io)
  local phase, serverId, rid, deadline, code, codeId, nNew, nServer, secret, sawDone, wrote
  local helloRid, claimRid
  local function send(message)
    message.secret = ""
    io.rednet.send(serverId, message, PROTOCOL)
  end
  local function finish()
    if wrote or not secret or not sawDone then return wrote end
    local views = ViewPair.fillViews(readTable(io.fs, "views.cfg"), serverId, secret, io.enableView == true)
    wrote = writeViews(io.fs, views)
    return wrote
  end
  return {
    start = function()
      serverId = lookupId(io.lookup)
      if type(serverId) ~= "number" then return end
      rid = "view-pair-" .. tostring(io.computerId)
      phase = "ack"
      deadline = io.now() + ACK_WAIT
      send({
        v = 1, type = "ssot", op = "enrol-issue", role = "view", expect = "ssot_reply",
        rid = rid, boot = "view-" .. tostring(io.computerId), counter = 1,
      })
    end,
    handle = function(event, id, message, protocol)
      if event == "timer" then
        if (phase == "ack" or phase == "code") and io.now() >= deadline then phase = "stop" end
        return nil
      end
      if event ~= "rednet_message" or phase == nil or phase == "stop" then return nil end
      if id ~= serverId or protocol ~= PROTOCOL or type(message) ~= "table" then return nil end
      if message.key ~= nil or message.secret ~= nil then return nil end
      if message.type == "pair-done" and message.ok == true and message.code == nil then
        sawDone = true
        return finish()
      end
      if (phase == "ack" or phase == "code") and message.type == "pair-code"
        and type(message.code) == "string" and type(message.codeId) == "string" then
        code, codeId = message.code, message.codeId
        if type(message.server) == "number" then serverId = message.server end
        nNew = hex8(io.computerId) .. hex8(io.now())
        helloRid = "view-pair-hello-" .. tostring(io.computerId)
        phase = "hello"
        send({
          v = 1, type = "ssot", op = "enrol-hello", expect = "ssot_reply", rid = helloRid,
          boot = "view-" .. tostring(io.computerId), counter = 2, codeId = codeId, nNew = nNew,
        })
        return nil
      end
      if phase == "ack" and message.type == "ssot_reply" and message.ok == true
        and message.pending == true and message.rid == rid and message.code == nil then
        phase = "code"
        deadline = io.now() + enrol().ttl
        return nil
      end
      if phase == "hello" and message.type == "ssot_reply" and message.ok == true
        and message.rid == helloRid and type(message.nServer) == "string" then
        if type(message.server) == "number" then serverId = message.server end
        nServer = message.nServer
        local claim = {
          id = io.computerId, server = serverId, codeId = codeId, nNew = nNew, nServer = nServer,
          newPub = "", serverPub = "",
        }
        claimRid = "view-pair-claim-" .. tostring(io.computerId)
        phase = "claim"
        send({
          v = 1, type = "ssot", op = "enrol-claim", expect = "ssot_reply", rid = claimRid,
          boot = "view-" .. tostring(io.computerId), counter = 3, codeId = codeId, nNew = nNew,
          nServer = nServer, newPub = "", serverPub = "", proof = enrol().proof(code, claim),
        })
        return nil
      end
      if phase == "claim" and message.type == "ssot_reply" and message.ok == true and message.rid == claimRid then
        secret = enrol().pairingKey(code, {
          id = io.computerId, server = serverId, codeId = codeId, nNew = nNew, nServer = nServer,
          newPub = "", serverPub = "",
        })
        phase = "done"
        return finish()
      end
      return nil
    end,
  }
end

return ViewPair
