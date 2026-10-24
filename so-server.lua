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
  SO.health = { started = SO.now(), tickMs = 0 }
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
      local ok, mod = pcall(function()
        return assert(loadfile(name, nil, _ENV))()
      end)
      if ok and type(mod) == "table" and type(mod.name) == "string" and type(mod.handlers) == "table" then
        mods[#mods + 1] = mod
        SO.mods[mod.name] = mod
      else
        S.error("so-server: skip " .. name)
      end
    end
  end

  local sent = {}
  local view = { mode = "normal", log = S.log, id = os.getComputerID(),
    started = SO.now(), offset = 0 }
  SO.terminal = view
  local memory = 120000
  local codeOwner
  -- Envelopes stamped before this start were handled by an earlier run.
  proto.since(os.epoch("utc"))

  local function showHostError()
    if not view.hostError then return end
    term.setCursorPos(1, 3)
    term.write(view.hostError)
  end

  local function showPrompt()
    view.mode, view.offset = "normal", 0
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
    view.code = pair.invite(not term.blit and term or nil)
    view.expires = SO.now()+300000
    if not term.blit then showHostError() end
  end

  SO.pairCode = function(id)
    if not pair.key(id) then return nil end
    if pair.pending() then
      if codeOwner ~= id then return nil end
    else
      showCode()
      codeOwner = id
    end
    return { code = view.code, expires = view.expires }
  end

  SO.forgetDevice = function(id, actor)
    for _, name in ipairs({"mine", "lumber", "build", "drops"}) do
      local mod = SO.mods[name]
      if mod and mod.forget then
        local ok, err = mod.forget(id)
        if not ok then return false, err or "assignment save failed" end
      end
    end
    local previousKey = pair.key(id)
    local ok, err = pair.forget(id)
    if not ok then return false, err end
    sent[id] = nil
    if codeOwner == id then pair.clear(); codeOwner = nil; showPrompt() end
    if SO.mods.lease then SO.mods.lease.forget(id, previousKey) end
    if SO.mods.display then SO.mods.display.forget(id) end
    local state = SO.mods.state
    if state and state.emit then state.emit("pair.forgotten", {id=id, actor=actor, text="Forgot device "..id}) end
    return true
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
      local state = SO.mods.state
      if state and state.emit then state.emit("pair.done", {id=msg.from,at=SO.now()}) end
      showPrompt()
    end,
    hello = function(_msg, reply)
      reply("ack", { ok = true })
    end,
  }

  -- Batch enrollment stays off unless so-server.cfg sets enroll = true.
  local config = type(store.read) == "function" and store.read("so-server.cfg")
  if type(config) == "table" and config.enroll == true then
    SO.enroll = {
      open = pair.enrollOpen,
      view = pair.enrollView,
      close = pair.enrollClose,
      decide = function(id, n, approve)
        local ok, err = pair.enrollDecide(id, n, approve)
        if not ok then return nil, err end
        print("so-server: enroll " .. (approve and "approved " or "denied ") .. tostring(id))
        local state = SO.mods.state
        if approve and state and state.emit then state.emit("pair.done", {id=id,at=SO.now()}) end
        return true
      end,
    }
    builtin.enroll = function(msg, reply)
      -- Network input stays out of the SO.errors ring, so no error() here.
      local ok, t, body, event = pcall(pair.enrollAnswer, msg.from, msg.body)
      if not ok then
        print("so-server: enroll failed for " .. tostring(msg.from))
        t, body, event = "err", { code = "enroll", text = "failed" }, nil
      end
      if event then print("so-server: enroll " .. event .. " " .. tostring(msg.from)) end
      if event == "rejected" then view.rejected = pair.rejected() end
      reply(t, body, pair.envelopeKey())
    end
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

  local function deliver(msg)
    local replied = false
    local function reply(t, body, key)
      if replied then return end
      replied = true
      replyTo(msg, t, body, key)
    end
    local found = false
    local built = builtin[msg.t]
    if built then
      found = true
      local ok, err = pcall(built, msg, reply)
      if not ok then S.error("so-server: handler " .. msg.t .. " failed: " .. tostring(err)) end
    end
    for i = 1, #mods do
      local handler = mods[i].handlers[msg.t]
      if handler then
        found = true
        local ok, err = pcall(handler, msg, reply)
        if not ok then S.error("so-server: handler " .. msg.t .. " failed: " .. tostring(err)) end
      end
    end
    if not found then reply("err", { code = "unknown", text = "unknown type" }) end
  end

  local function dispatch(sender, payload)
    local msg = proto.decode(payload)
    if not msg or msg.from ~= sender then
      print("so-server: bad message from " .. tostring(sender))
      return
    end
    local key
    if msg.t == "pair2" or (msg.t == "enroll" and builtin.enroll) then
      key = pair.envelopeKey()
    elseif msg.t == "pair" then
      local code = pair.pending()
      if code and pair.blocked(msg.from) and not recall(msg) then
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
      if msg.t == "pair" and pair.pending() then reject(msg.from, true) end
      if msg.t == "hello" or msg.t == "beacon" or msg.t == "step.report" then
        rednet.send(sender, { t = "pair.required", from = os.getComputerID() }, "so")
      end
      print("so-server: bad mac from " .. tostring(sender))
      return
    end
    local again, fresh = priorReply(msg)
    if again then
      rednet.send(msg.from, again, "so")
      return
    end
    if not fresh then
      print("so-server: replay from " .. tostring(sender))
      return
    end
    deliver(msg)
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
  -- R opens a one-line "<id> <role>" prompt; display.command applies it.
  local function roleKeyEvent(a)
    if a == keyCode("enter", 28) or a == keyCode("numPadEnter", 156) then
      local display = SO.mods.display
      local ok, text = false, "display module missing"
      if display and type(display.command) == "function" then
        local called, a1, a2 = pcall(display.command, view.input)
        if called then ok, text = a1, a2 else text = "role command failed: " .. tostring(a1) end
      end
      print("role: " .. tostring(text))
      view.notice = text
      if ok then view.input = "" end
    elseif a == keyCode("backspace", 14) then
      view.input = view.input:sub(1, -2)
    elseif a == keyCode("escape", 1) then
      view.mode, view.input, view.notice = "normal", nil, nil
    end
    view.swallow = false
  end
  local function redraw()
    local display = SO.mods.display
    if display and type(display.drawTerminal) == "function" then pcall(display.drawTerminal, SO.now()) end
  end
  local timer, ticked
  local function tick()
    if view.mode == "code" and not pair.pending() then showPrompt() end
    local began, now = os.clock(), SO.now()
    local wall = os.epoch("utc")
    local health = SO.health
    if health.last then health.cadence, health.wallCadence = now-health.last, wall-health.wall end
    health.last, health.wall = now, wall
    for from, by in pairs(sent) do
      for rid, slot in pairs(by) do
        if os.epoch("utc") - slot.at > memory then by[rid] = nil end
      end
      if next(by) == nil then sent[from] = nil end
    end
    proto.prune()
    for i = 1, #mods do
      local fn = mods[i].tick
      if type(fn) == "function" then
        local ok, err = pcall(fn, now)
        if not ok then S.error("so-server: tick " .. mods[i].name .. " failed: " .. tostring(err)) end
      end
    end
    SO.health.tickMs = math.floor((os.clock()-began)*1000+0.5)
    if S.errors then S.errors.flush(now) end
    timer, ticked = os.startTimer(1), os.clock()
  end
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
