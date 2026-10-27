local F = dofile("so-flags.lua")
local MIN = 16000000
local cap = fs.getCapacity("/")
if type(cap) ~= "number" or cap < MIN then
  print("so-server: need " .. MIN .. " bytes, this disk has " .. tostring(cap) .. ".")
  print("Set computer_space_limit in computercraft-server.toml to at least " .. MIN .. ", then restart the world.")
  return
end

local S = { log = {}, output = print }
local clockOk, clock = pcall(dofile, "so-ui.lua")
if clockOk then S.ui = clock end
print = function(...)
  if not term or not term.blit then S.output(...) end
  local parts = {}
  for i = 1,select("#",...) do parts[i]=tostring(select(i,...)) end
  local text = table.concat(parts,"\t")
  for line in (text.."\n"):gmatch("(.-)\n") do
    local prefix = S.ui and (S.ui.clock(os.epoch("utc")).hms .. " ") or ""
    local width = 4096 - #prefix
    repeat
      S.log[#S.log+1]=prefix .. line:sub(1,width)
      if #S.log > 200 then table.remove(S.log,1) end
      line=line:sub(width+1)
    until line == ""
  end
end

S.error = function(line, force)
  print(line)
  if S.errors then pcall(S.errors.record, line, force) end
end

S.need = function(name)
  if not fs.exists(name) then
    S.error("so-server: missing " .. name)
    return nil
  end
  local ok, mod = pcall(dofile, name)
  if not ok then
    S.error("so-server: " .. name .. " failed: " .. tostring(mod))
    return nil
  end
  return mod
end

S.run = function()
  local proto = S.need("so-proto.lua")
  local store = S.need("so-store.lua")
  local pair = S.need("so-pair.lua")
  if not proto or not store or not pair then return end
  if not fs.exists("so-server.cfg") then
    for _, path in ipairs({ "so-server.cfg.tmp", "so-server.cfg.bak" }) do
      local saved = fs.exists(path) and store.read(path)
      if type(saved) == "table" then
        fs.move(path, "so-server.cfg")
        break
      end
    end
  end
  local now, clockStatus = store.clock()
  clockStatus = clockStatus or { refused = false }
  SO = { mods = {}, proto = proto, pair = pair, store = store, clock = clockStatus }
  SO.now = function()
    local refused = clockStatus.refused
    local at = now()
    if clockStatus.refused and not refused then
      S.error("so-server: clock checkpoint refused; time frozen: " .. tostring(clockStatus.error))
    end
    return at
  end
  SO.error = S.error
  if fs.exists("so-errors.lua") then
    local errors = S.need("so-errors.lua")
    if errors then
      local opened, log = pcall(errors.open, store, SO.now)
      if opened then S.errors, SO.errors = log, log else S.error("so-errors: " .. tostring(log)) end
    end
  end
  SO.health = { started = SO.now(), tickMs = 0, modules = {} }
  SO.health.refused = { windowMs = 600000, cap = 128, senders = {}, evicted = 0,
    totals = { shape = 0, time = 0, mac = 0, replay = 0, blocked = 0 } }
  local function refused(sender, reason)
    local facts, at = SO.health.refused, SO.now()
    facts.totals[reason] = facts.totals[reason] + 1
    local bucket = math.floor(at / facts.windowMs)
    local row = facts.senders[sender]
    if not row then
      local count, oldest = 0, nil
      for id, candidate in pairs(facts.senders) do
        count = count + 1
        if not oldest or candidate.last < facts.senders[oldest].last then oldest = id end
      end
      if count >= facts.cap then
        facts.senders[oldest], facts.evicted = nil, facts.evicted + 1
      end
    end
    if not row or row.bucket ~= bucket then
      row = { bucket = bucket, shape = 0, time = 0, mac = 0, replay = 0, blocked = 0 }
      facts.senders[sender] = row
    end
    row.last, row[reason] = at, row[reason] + 1
    -- Refused network input never writes to the durable error ring.
  end
  for _, name in ipairs({"ar","build","cells","daily","display","drops","health","lease",
    "lumber","map","mine","panel","shop","state"}) do
    SO.health.modules["so-mod-"..name..".lua"] = {status="absent"}
  end
  pair.open(proto, store, SO.now)
  -- Yield once without losing events. sleep(0) drops every event that is
  -- not its own timer, including the tick timer and rednet messages.
  -- Handlers, listeners and ticks must yield only through this.
  SO.breathe = function()
    os.queueEvent("so-breathe")
    for _ = 1, 256 do
      local packed = table.pack(os.pullEventRaw())
      if packed[1] == "so-breathe" then return end
      os.queueEvent(table.unpack(packed, 1, packed.n))
    end
  end
  local mods = {}
  local names = fs.list("/")
  table.sort(names)
  for i = 1, #names do
    local name = names[i]
    if name:match("^so%-mod%-.+%.lua$") then
      local status = {status="failed"}
      local count = 0
      for _ in pairs(SO.health.modules) do count=count+1 end
      if SO.health.modules[name] or count < 64 then SO.health.modules[name] = status end
      local ok, mod = pcall(function()
        return assert(loadfile(name, nil, _ENV))()
      end)
      if ok and type(mod) == "table" and type(mod.name) == "string" and type(mod.handlers) == "table" then
        mods[#mods + 1] = mod
        SO.mods[mod.name] = mod
        status.status, status.name = "loaded", mod.name
        mod.healthStatus = status
      else
        status.error = (ok and "invalid module" or tostring(mod)):sub(1,160)
        S.error("so-server: skip " .. name .. ": " .. status.error)
      end
    end
  end

  local sent = {}
  local view = { mode = "normal", log = S.log, id = os.getComputerID(),
    started = SO.now(), offset = 0 }
  SO.terminal = view
  local memory = 120000
  local codeOwner, revoke
  -- Envelopes stamped before this start were handled by an earlier run.
  proto.since(os.epoch("utc"))

  local function showHostError()
    if not view.hostError then return end
    term.setCursorPos(1, 3)
    term.write(view.hostError)
  end

  local function showPrompt()
    view.mode, view.offset = "normal", 0
    revoke = nil
    view.codeError = nil
    if term and not term.blit then
      term.clear()
      term.setCursorPos(1, 1)
      term.write("Press P to pair")
      print("Press P to pair")
    end
    if not term.blit then showHostError() end
  end

  local function showCode()
    codeOwner = nil
    view.rejected = nil
    -- A panel can request a code while the operator types a role command.
    if view.mode ~= "role" then view.mode = "code" end
    local code, err = pair.invite(not term.blit and term or nil)
    view.codeError = not code and (err or "random source unavailable") or nil
    view.code = code or view.codeError
    view.expires = SO.now() + (code and 300000 or 0)
    if view.codeError and not term.blit then
      term.clear()
      term.setCursorPos(1, 1)
      term.write(view.codeError)
    end
    if not term.blit then showHostError() end
    return code ~= nil
  end

  SO.pairCode = function(id)
    if not pair.key(id) then return nil end
    if pair.pending() then
      if codeOwner ~= id then return nil end
    else
      if not showCode() then return nil end
      codeOwner = id
    end
    return { code = view.code, expires = view.expires }
  end

  local forgetNames = {"mine", "lumber", "build", "drops", "lease", "display"}
  SO.forgetImpact = function(id)
    local impact = { jobs = 0, scans = 0, jobNames = {} }
    if pair.key(id) then
      for _, name in ipairs({"mine", "lumber", "build"}) do
        local mod = SO.mods[name]
        if mod and type(mod.assigned) == "function" and mod.assigned(id) then
          impact.jobs = impact.jobs + 1
          impact.jobNames[#impact.jobNames + 1] = name
        end
      end
      local drops = SO.mods.drops
      if drops and type(drops.busy) == "function" and drops.busy(id) then impact.scans = 1 end
    end
    impact.text = "parks " .. impact.jobs .. (impact.jobs == 1 and " job" or " jobs")
    if impact.scans > 0 then impact.text = impact.text .. "; holds 1 scan" end
    return impact
  end
  local function finishForget(row)
    local id = row.id
    sent[id] = nil
    if codeOwner == id then pair.clear(); codeOwner = nil; showPrompt() end
    local failure
    for _, name in ipairs(forgetNames) do
      local mod = SO.mods[name]
      if mod and type(mod.forget) == "function" then
        local called, ok, err = pcall(mod.forget, id, name == "lease" and row.key or nil)
        if not called or ok == false or not ok and name ~= "lease" and name ~= "display" then
          failure = failure or (called and (err or "assignment save failed") or tostring(ok))
          if not called then S.error("so-server: forget " .. name .. " failed: " .. tostring(ok)) end
        end
      elseif row.modules[name] then
        failure = failure or ("forget module unavailable: " .. name)
      end
    end
    if failure then return false, failure end
    local called, ok, err = pcall(pair.forgetDone, id)
    if not called then return false, tostring(ok) end
    return ok, err
  end

  local function retryForgets()
    for _, row in ipairs(pair.forgetPending()) do finishForget(row) end
  end

  SO.forgetDevice = function(id, actor)
    local row = { id = id, modules = {} }
    for _, name in ipairs(forgetNames) do
      local mod = SO.mods[name]
      if mod and type(mod.forget) == "function" then row.modules[name] = true end
    end
    local ok, err = pair.forget(id, row.modules)
    if not ok then return false, err end
    for _, pending in ipairs(pair.forgetPending()) do
      if pending.id == id then row = pending break end
    end
    local done, cleanupErr = finishForget(row)
    local state = SO.mods.state
    if state and state.emit then state.emit("pair.forgotten", {id=id, actor=actor, text="Forgot device "..id}) end
    return done, cleanupErr
  end

  local function pairDone(id)
    local state = SO.mods.state
    if state and state.emit then
      state.emit("pair.done", {id=id,at=SO.now()})
      state.emit("pair.forgotten", nil)
    end
  end

  local function recall(msg)
    local by = sent[msg.from]
    local slot = by and by[msg.rid]
    if not slot then return nil end
    if os.epoch("utc") - slot.at > memory then
      by[msg.rid] = nil
      return nil
    end
    return slot.payload
  end

  local function priorReply(msg)
    local again = recall(msg)
    if again then return again end
    return nil, proto.fresh(msg)
  end

  local function reject(id, guess, paired)
    local _, burned = pair.charge(id, guess and "guess" or "reject", paired)
    print("so-server: pair rejected " .. tostring(id))
    view.rejected = pair.rejected()
    if burned then showPrompt() end
  end

  local builtin = {
    pair2 = function(msg, reply)
      local open = pair.envelopeKey()
      if msg.body.tag == nil then
        local body, why = pair.start(msg.from, msg.body)
        if not body then
          if why == "body" or why == "share" then reject(msg.from, false) end
          reply("err", { code = "pair", text = why }, open)
          return
        end
        reply("ack", body, open)
        return
      end
      local machine, body, paired = pair.confirm(msg.from, msg.body)
      if not machine then
        if body == "tag" then reject(msg.from, true, paired) end
        reply("err", { code = "pair", text = body }, open)
        return
      end
      local saved, err = pair.remember(msg.from, machine)
      if not saved then
        reply("err", { code = "store", text = tostring(err) }, open)
        return
      end
      reply("ack", body, open)
      pair.clear()
      pairDone(msg.from)
      showPrompt()
    end,
    pair = function(msg, reply)
      local code = pair.pending()
      if not code then return end
      local hs = pair.derive(code, os.getComputerID(), msg.from)
      local pub = type(msg.body) == "table" and msg.body.pub or nil
      local machine, body = pair.session(pub)
      if not machine then
        reply("err", { code = "pair", text = tostring(body) }, hs)
        return
      end
      local saved, err = pair.remember(msg.from, machine)
      if not saved then
        reply("err", { code = "store", text = tostring(err) }, hs)
        return
      end
      reply("ack", body, hs)
      pair.clear()
      pairDone(msg.from)
      showPrompt()
    end,
    hello = function(_msg, reply)
      reply("ack", { ok = true })
    end,
  }

  local function readConfig()
    local path = fs.exists("so-server.cfg") and "so-server.cfg" or "so-server.cfg.bak"
    local ok, value = pcall(function() return type(store.read) == "function" and store.read(path) or nil end)
    return ok and type(value) == "table" and value or nil
  end
  local config = readConfig()
  local function exposeConfig(value)
    local cfg = store.copy(value or {})
    for name in pairs(F.defaults) do
      if not name:find("%.") then cfg[name] = F.get(value, name) end
    end
    cfg.state = type(cfg.state) == "table" and cfg.state or {}
    cfg.state.coalesceHeartbeats = F.get(value, "state.coalesceHeartbeats")
    SO.health.config = cfg
  end
  exposeConfig(config)
  if fs.exists("so-server.cfg") and not config then
    SO.health.configError = "so-server.cfg unreadable; defaults active"
    view.hostError = SO.health.configError
    S.error("so-server: " .. SO.health.configError)
  end
  local retireLegacyPair = F.enabled(config, "retireLegacyPair")
  print("legacy pair: " .. (retireLegacyPair and "retired" or "kept"))
  if not retireLegacyPair then print("The next server-only release removes legacy pair. " ..
    "Old turtles must run install update before pairing again. " ..
    "Update pockets and wall displays too. Saved pairings keep working. Updated clients use pair2 only.") end
  if retireLegacyPair then builtin.pair = nil end
  local function enrollEnabled()
    return F.enabled(config, "enroll")
  end
  local updates = {}
  local function installedRevision()
    if type(fs.open) ~= "function" then return nil end
    local h = fs.open(".so-revision", "r")
    local value = h and h.readAll():match("^%s*(.-)%s*$")
    if h then h.close() end
    return type(value) == "string" and #value == 40 and not value:find("[^0-9a-f]") and value or nil
  end
  local runningRevision = installedRevision()
  SO.health.revision = runningRevision
  local pos = type(config) == "table" and config.pos
  local function coordinate(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
  if type(pos) == "table" and coordinate(pos.x) and coordinate(pos.y) and coordinate(pos.z)
    and type(gps) == "table" and type(gps.locate) == "function" then
    local ok, x, y, z = pcall(gps.locate, 2)
    if ok and coordinate(x) and coordinate(y) and coordinate(z) then
      SO.health.gpsGap = math.sqrt((x-pos.x)^2+(y-pos.y)^2+(z-pos.z)^2)
      if SO.health.gpsGap > 2 then S.error(string.format("so-server: saved position GPS gap %.1f blocks",SO.health.gpsGap)) end
    end
  end
  local function updateIdle(id)
    local lease = SO.mods.lease
    local row = lease and lease.peek(id)
    if not row or row.open or row.probing or row.uncertain or row.lost then return false end
    for _, name in ipairs({"mine", "lumber", "build", "drops"}) do
      local mod = SO.mods[name]
      if mod and (mod.assigned and mod.assigned(id) or mod.busy and mod.busy(id)) then return false end
    end
    return true
  end
  local function expireUpdate(row)
    if row.untilAt and SO.now() >= row.untilAt and (row.state == "requested" or row.state == "awaiting reboot") then
      row.state, row.text = "unconfirmed", "update timed out"
    end
    if row.key ~= pair.key(row.id) then row.state, row.capable = "unconfirmed", false end
  end
  SO.workerUpdate = function(id)
    local row = updates[id]
    if not row then return nil end
    expireUpdate(row)
    return {revision=row.target, running=row.revision, state=row.state, text=row.text, rid=row.rid}
  end
  SO.updateWorker = function(id)
    local cfg, row, key = readConfig(), updates[id], pair.key(id)
    if not F.enabled(cfg, "panelUpdates") then return nil, "updates disabled" end
    if not row or not key or row.key ~= key or not row.capable then return nil, "update required" end
    if not row.remote then return nil, "updates disabled" end
    expireUpdate(row)
    if row.state == "requested" or row.state == "awaiting reboot" then return nil, "update pending" end
    if not runningRevision or not row.revision or runningRevision == row.revision then return nil, "invalid revision" end
    if SO.now()-row.seen >= 45000 or not updateIdle(id) then return nil, "worker busy" end
    local msg = proto.build(key, "worker.update", {revision=runningRevision})
    local wire = proto.encode(msg)
    if not wire then return nil, "update encode failed" end
    row.rid, row.target, row.untilAt = msg.rid, runningRevision, SO.now()+120000
    row.state, row.text = "requested", nil
    local ok, result = pcall(rednet.send, id, wire, "so")
    if not ok or result == false then row.state, row.text="unconfirmed", "send failed" return nil, "send failed" end
    return msg.rid
  end
  local hello = builtin.hello
  builtin.hello = function(msg, reply)
    hello(msg, reply)
    local body, row = msg.body, updates[msg.from]
    if not row then
      local count, oldest = 0, nil
      for id, candidate in pairs(updates) do
        count = count+1
        expireUpdate(candidate)
        if candidate.state ~= "requested" and candidate.state ~= "awaiting reboot"
          and (not oldest or candidate.seen < updates[oldest].seen) then oldest=id end
      end
      if count >= 128 then if oldest then updates[oldest]=nil else return end end
      row = {id=msg.from}
      updates[msg.from] = row
    elseif row.key ~= pair.key(msg.from) then
      row.rid, row.target, row.untilAt, row.state, row.text = nil, nil, nil, nil, nil
    end
    row.key, row.seen = pair.key(msg.from), SO.now()
    row.capable = (body.role == "turtle" or body.role == "worker")
      and type(body.capabilities) == "table" and body.capabilities.pinnedUpdate == true
    row.remote = body.remoteUpdates == true
    row.revision = type(body.revision) == "string" and #body.revision == 40
      and not body.revision:find("[^0-9a-f]") and body.revision or nil
    expireUpdate(row)
    if row.state == "awaiting reboot" and row.revision == row.target then row.state="complete" end
    if row.capable and row.remote and updateIdle(msg.from) then
      local wire = proto.encode(proto.build(row.key, "worker.status", {job="",reason="",idleRid=msg.rid}))
      if wire then rednet.send(msg.from, wire, "so") end
    end
  end
  local function updateReply(msg)
    local row, body = updates[msg.from], msg.body
    if not row or body.command ~= "worker.update" then return end
    expireUpdate(row)
    if row.state ~= "requested" or row.rid ~= msg.rid or row.key ~= pair.key(msg.from) then return end
    if msg.t == "ack" and body.revision == row.target and body.state == "accepted" then
      row.state = "awaiting reboot"
    elseif msg.t == "err" and body.code == "update" and (body.revision == nil or body.revision == row.target) then
      row.state, row.text = "refused", tostring(body.text or "update refused"):sub(1,128)
    end
  end
  builtin.ack, builtin.err = updateReply, updateReply
  SO.enroll = {
    enabled = enrollEnabled,
    setEnabled = function(enabled)
      if type(enabled) ~= "boolean" then return nil, "boolean required" end
      local current = readConfig()
      if current == nil and (fs.exists("so-server.cfg") or fs.exists("so-server.cfg.bak")) then
        return nil, "bad so-server.cfg"
      end
      if current ~= nil and type(current) ~= "table" then return nil, "bad so-server.cfg" end
      local merged = store.copy(current or {})
      merged.enroll = enabled
      local h
      local ok, err = pcall(function()
        local text = textutils.serialize(merged)
        h = assert(fs.open("so-server.cfg.tmp", "w"), "config open failed")
        h.write(text)
        h.close()
        h = nil
        local checked, bytes = store.read("so-server.cfg.tmp")
        assert(type(checked) == "table" and bytes == text, "config verification failed")
        if fs.exists("so-server.cfg") then
          fs.delete("so-server.cfg.bak")
          fs.move("so-server.cfg", "so-server.cfg.bak")
        end
        fs.move("so-server.cfg.tmp", "so-server.cfg")
      end)
      if h then pcall(h.close) end
      if not ok then return nil, tostring(err) end
      config = merged
      exposeConfig(config)
      if not enabled then pair.enrollClose() end
      return true
    end,
    open = function(owner)
      if not enrollEnabled() then return nil, "off" end
      return pair.enrollOpen(owner)
    end,
    view = pair.enrollView,
    close = pair.enrollClose,
    extend = function(owner)
      if not enrollEnabled() then return nil, "off" end
      return pair.enrollExtend(owner)
    end,
    decide = function(id, n, approve)
      if not enrollEnabled() then return nil, "off" end
      local ok, err = pair.enrollDecide(id, n, approve)
      if not ok then return nil, err end
      print("so-server: enroll " .. (approve and "approved " or "denied ") .. tostring(id))
      if approve then pairDone(id) end
      return true
    end,
  }
  builtin.enroll = function(msg, reply)
    -- Network input stays out of the SO.errors ring, so no error() here.
    local enabled = enrollEnabled()
    local ok, t, body, event = pcall(pair.enrollAnswer, msg.from, msg.body, enabled)
    if not ok then
      print("so-server: enroll failed for " .. tostring(msg.from))
      t, body, event = "err", { code = "enroll", text = "failed" }, nil
    end
    if event then print("so-server: enroll " .. event .. " " .. tostring(msg.from)) end
    if event == "rejected" then view.rejected = pair.rejected() end
    reply(t, body, pair.envelopeKey())
  end

  local function replyTo(msg, t, body, key)
    if not key then key = pair.key(msg.from) end
    if not key then
      print("so-server: no key for " .. tostring(msg.from))
      return
    end
    local out = proto.build(key, t, body, msg.rid)
    local wire = proto.encode(out)
    if not wire then return end
    local by = sent[msg.from]
    if not by then
      by = {}
      sent[msg.from] = by
    end
    local slot = { at = os.epoch("utc"), payload = wire }
    if msg.t == "pair" then slot.hs = key end
    by[msg.rid] = slot
    rednet.send(msg.from, wire, "so")
  end

  local function deliver(msg, key)
    local replied = false
    local function reply(t, body, key)
      if replied then return end
      replied = true
      replyTo(msg, t, body, key)
    end
    local found, failed = false, false
    local built = builtin[msg.t]
    if built then
      found = true
      local ok, err = pcall(built, msg, reply)
      if not ok then
        S.error("so-server: handler " .. msg.t .. " failed: " .. tostring(err))
        failed = true
      end
    end
    for i = 1, #mods do
      local handler = mods[i].handlers[msg.t]
      if handler then
        found = true
        local ok, err = pcall(handler, msg, reply)
        if not ok then
          S.error("so-server: handler " .. msg.t .. " failed: " .. tostring(err))
          failed = true
        end
      end
    end
    if failed then reply("err", { code = "handler" }, key)
    elseif not found then reply("err", { code = "unknown", text = "unknown type" }) end
  end

  local function dispatch(sender, payload)
    local msg, why = proto.decode(payload)
    if not msg or msg.from ~= sender then
      refused(sender, why == "time" and "time" or "shape")
      print("so-server: bad message from " .. tostring(sender))
      return
    end
    -- Drop legacy traffic before key selection and cached replies.
    if msg.t == "pair" and retireLegacyPair then return end
    local key
    if msg.t == "pair2" or msg.t == "enroll" then
      key = pair.envelopeKey()
    elseif msg.t == "pair" then
      local code = pair.pending()
      if code and pair.blocked(msg.from) and not recall(msg) then
        refused(sender, "blocked")
        print("so-server: pair blocked " .. tostring(sender))
        return
      end
      if code then
        key = pair.derive(code, os.getComputerID(), msg.from)
      else
        local by = sent[msg.from]
        local slot = by and by[msg.rid]
        if slot and slot.hs and os.epoch("utc") - slot.at <= memory then key = slot.hs end
      end
    else
      key = pair.key(msg.from)
    end
    if msg.t == "pair" and key and not proto.macOk(key, msg) then
      local by = sent[msg.from]
      local slot = by and by[msg.rid]
      if slot and slot.hs and os.epoch("utc") - slot.at <= memory
        and proto.macOk(slot.hs, msg) then key = slot.hs end
    end
    if not key or not proto.macOk(key, msg) then
      refused(sender, "mac")
      if msg.t == "pair" and pair.pending() then reject(msg.from, true) end
      if msg.t == "hello" or msg.t == "beacon" or msg.t == "step.report" then
        rednet.send(sender, { t = "pair.required", from = os.getComputerID() }, "so")
      end
      print("so-server: bad mac from " .. tostring(sender))
      return
    end
    local again, fresh = priorReply(msg)
    if again then
      if msg.t == "enroll" then deliver(msg, key)
      else rednet.send(msg.from, again, "so") end
      return
    end
    if not fresh then
      refused(sender, "replay")
      print("so-server: replay from " .. tostring(sender))
      return
    end
    deliver(msg, key)
  end

  local function openModems()
    local modems = { peripheral.find("modem") }
    for i = 1, #modems do
      rednet.open(peripheral.getName(modems[i]))
    end
    return #modems
  end

  if openModems() == 0 then S.error("so-server: no modem") end
  local hosted, hostErr = pcall(rednet.host, "so", "server")
  if not hosted then
    local found, other = pcall(rednet.lookup, "so", "server")
    if found and type(other) == "number" then
      view.hostError = "so/server hostname in use by " .. tostring(other)
    else
      view.hostError = "so/server host failed; see log"
    end
    S.error("so-server: " .. view.hostError .. ": " .. tostring(hostErr))
  end
  showPrompt()
  local pairKey = (type(keys) == "table" and keys.p) or 25
  local roleKey = (type(keys) == "table" and keys.r) or 19
  local function keyCode(name, legacy) return (type(keys) == "table" and keys[name]) or legacy end
  local function terminalCommand(text)
    local pending = revoke
    revoke = nil
    local id = text:match("^%s*(%d+)%s+revoke%s*$")
    local confirm = pending and text:match("^%s*(%d+)%s*$")
    if not id and not confirm then return nil end
    local cfg = readConfig()
    if not F.enabled(cfg, "terminalRevoke") then return false, "terminal revoke disabled" end
    if confirm then
      if tonumber(confirm) ~= pending.id then return false, "revoke id mismatch" end
      if SO.now() >= pending.expires or pair.key(pending.id) ~= pending.key then
        return false, "revoke confirmation expired"
      end
      local ok, err = SO.forgetDevice(pending.id, os.getComputerID())
      return ok, ok and ("Forgot device " .. pending.id) or err
    end
    id = tonumber(id)
    local key = pair.key(id)
    if not key then return false, "device not paired" end
    revoke = { id = id, key = key, expires = SO.now() + 15000 }
    return true, "Type " .. id .. " to revoke; " .. SO.forgetImpact(id).text
  end
  -- R opens a one-line "<id> <role>" prompt; display.command applies it.
  local function roleKeyEvent(a)
    if a == keyCode("enter", 28) or a == keyCode("numPadEnter", 156) then
      local display = SO.mods.display
      local ok, text = terminalCommand(view.input)
      if ok == nil and display and type(display.command) == "function" then
        local called, a1, a2 = pcall(display.command, view.input)
        if called then ok, text = a1, a2 else text = "role command failed: " .. tostring(a1) end
      elseif ok == nil then
        ok, text = false, "display module missing"
      end
      print("role: " .. tostring(text))
      view.notice = text
      if ok then view.input = "" end
    elseif a == keyCode("backspace", 14) then
      view.input = view.input:sub(1, -2)
    elseif a == keyCode("escape", 1) then
      view.mode, view.input, view.notice, revoke = "normal", nil, nil, nil
    end
    view.swallow = false
  end
  local function redraw()
    local display = SO.mods.display
    if display and type(display.drawTerminal) == "function" then pcall(display.drawTerminal, SO.now()) end
  end
  local timer, ticked
  local function tick()
    if view.mode == "code" and not view.codeError and not pair.pending() then showPrompt() end
    local began, now = os.clock(), SO.now()
    local wall = os.epoch("utc")
    local health = SO.health
    config = readConfig()
    exposeConfig(config)
    for id, row in pairs(health.refused.senders) do
      if row.bucket ~= math.floor(now / health.refused.windowMs) then health.refused.senders[id] = nil end
    end
    if health.last then health.cadence, health.wallCadence = now-health.last, wall-health.wall end
    health.last, health.wall = now, wall
    for from, by in pairs(sent) do
      for rid, slot in pairs(by) do
        if os.epoch("utc") - slot.at > memory then by[rid] = nil end
      end
      if next(by) == nil then sent[from] = nil end
    end
    proto.prune()
    retryForgets()
    for i = 1, #mods do
      local fn = mods[i].tick
      if type(fn) == "function" then
        local moduleBegan = os.clock()
        local ok, err = pcall(fn, now)
        local status = mods[i].healthStatus
        status.tickMs = math.max(0, math.floor((os.clock() - moduleBegan) * 1000 + 0.5))
        if not status.peakMs or status.tickMs > status.peakMs then
          status.peakMs, status.peakAt = status.tickMs, now
        end
        if not health.slowest or status.peakMs > health.slowest.tickMs then
          health.slowest = { name = mods[i].name, tickMs = status.peakMs, at = status.peakAt }
        end
        if ok then status.lastGood, status.tickError = now, nil
        else
          status.tickError = tostring(err):sub(1,160)
          S.error("so-server: tick " .. mods[i].name .. " failed: " .. tostring(err))
        end
      end
    end
    if health.slowest then health.slowest.age = now - health.slowest.at end
    SO.health.tickMs = math.floor((os.clock()-began)*1000+0.5)
    if S.errors then S.errors.flush(now) end
    timer, ticked = os.startTimer(1), os.clock()
  end
  retryForgets()
  timer, ticked = os.startTimer(1), os.clock()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      tick()
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      openModems()
    elseif ev == "key" and view.mode == "role" then
      roleKeyEvent(a)
      redraw()
    elseif (ev == "char" or ev == "paste") and view.mode == "role" then
      if not (view.swallow and ev == "char" and a:lower() == "r") then
        view.input = (view.input .. a):sub(1, 40)
      end
      view.swallow = false
      redraw()
    elseif ev == "key" and a == roleKey and not b and view.mode ~= "code" then
      revoke = nil
      view.mode, view.offset, view.input, view.notice, view.swallow = "role", 0, "", nil, true
      redraw()
    elseif ev == "key" and a == pairKey and not b then
      showCode()
    elseif ev == "key" and not b then
      if a == ((keys and keys.escape) or 1) then
        if view.mode == "code" then pair.clear() end
        showPrompt()
      elseif a == ((keys and keys.l) or 38) and view.mode ~= "code" then
        view.mode = view.mode == "log" and "normal" or "log"
        view.offset = 0
      elseif view.mode == "log" and a == ((keys and keys.up) or 200) then
        view.offset = math.min(math.max(0,#S.log-1),view.offset+1)
      elseif view.mode == "log" and a == ((keys and keys.down) or 208) then
        view.offset = math.max(0,view.offset-1)
      end
    elseif ev == "monitor_touch" then
      local display = SO.mods.display
      if display and type(display.monitorTouch) == "function" then display.monitorTouch(a,b,c) end
    elseif ev == "rednet_message" and c == "so" then
      dispatch(a, b)
    elseif ev == "rednet_message" then
      for i = 1, #mods do
        local listen = mods[i].listen
        local handler = type(listen) == "table" and listen[c] or nil
        if type(handler) == "function" then
          local ok, err = pcall(handler, a, b)
          if not ok then S.error("so-server: listen " .. mods[i].name .. " failed: " .. tostring(err)) end
        end
      end
    end
    -- A lost tick timer would stop planning for good while messages still
    -- arrive. Use computer ticks so a refused clock cannot stop recovery.
    if os.clock() - ticked > 3 then
      S.error("so-server: no tick for 3 s; rearming the tick timer")
      tick()
    end
  end
end

local ok, err = pcall(S.run)
print = S.output
if not ok then S.error("so-server: stopped: " .. tostring(err), true); error(err,0) end
