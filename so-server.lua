local MIN = 16000000
local cap = fs.getCapacity("/")
if type(cap) ~= "number" or cap < MIN then
  print("so-server: need " .. MIN .. " bytes, this disk has " .. tostring(cap) .. ".")
  print("Set computer_space_limit in computercraft-server.toml to at least " .. MIN .. ", then restart the world.")
  return
end

local S = { log = {}, output = print }
print = function(...)
  if not term or not term.blit then S.output(...) end
  local parts = {}
  for i = 1,select("#",...) do parts[i]=tostring(select(i,...)) end
  local text = table.concat(parts,"\t")
  for line in (text.."\n"):gmatch("(.-)\n") do
    repeat
      S.log[#S.log+1]=line:sub(1,4096)
      if #S.log > 200 then table.remove(S.log,1) end
      line=line:sub(4097)
    until line == ""
  end
end

S.need = function(name)
  if not fs.exists(name) then
    print("so-server: missing " .. name)
    return nil
  end
  local ok, mod = pcall(dofile, name)
  if not ok then
    print("so-server: " .. name .. " failed: " .. tostring(mod))
    return nil
  end
  return mod
end

S.run = function()
  local proto = S.need("so-proto.lua")
  local store = S.need("so-store.lua")
  local pair = S.need("so-pair.lua")
  if not proto or not store or not pair then return end
  pair.open(proto, store)
  SO = { mods = {}, proto = proto, pair = pair, store = store }
  local mods = {}
  local names = fs.list("/")
  table.sort(names)
  for i = 1, #names do
    local name = names[i]
    if name:match("^so%-mod%-.+%.lua$") then
      local ok, mod = pcall(dofile, name)
      if ok and type(mod) == "table" and type(mod.name) == "string" and type(mod.handlers) == "table" then
        mods[#mods + 1] = mod
        SO.mods[mod.name] = mod
      else
        print("so-server: skip " .. name)
      end
    end
  end

  local sent = {}
  local view = { mode = "normal", log = S.log, id = os.getComputerID(),
    started = os.epoch("utc"), offset = 0 }
  SO.terminal = view
  local memory = 120000
  local misses = 0

  local function showPrompt()
    view.mode, view.offset = "normal", 0
    if term and not term.blit then
      term.clear()
      term.setCursorPos(1, 1)
      term.write("Press P to pair")
      print("Press P to pair")
    end
  end

  local function showCode()
    misses = 0
    view.mode = "code"
    view.code = pair.invite(not term.blit and term or nil)
    view.expires = os.epoch("utc")+300000
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

  local builtin = {
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
      showPrompt()
    end,
    hello = function(msg, reply)
      reply("ack", { ok = true })
    end,
  }

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
      if not ok then print("so-server: handler " .. msg.t .. " failed: " .. tostring(err)) end
    end
    for i = 1, #mods do
      local handler = mods[i].handlers[msg.t]
      if handler then
        found = true
        local ok, err = pcall(handler, msg, reply)
        if not ok then print("so-server: handler " .. msg.t .. " failed: " .. tostring(err)) end
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
    if msg.t == "pair" then
      local code = pair.pending()
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
      if msg.t == "pair" and pair.pending() then
        misses = misses + 1
        if misses >= 5 then
          pair.clear()
          showPrompt()
        end
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

  local modem = peripheral.find("modem")
  if modem then
    rednet.open(peripheral.getName(modem))
    rednet.host("so", "server")
  else
    print("so-server: no modem")
  end
  showPrompt()
  local pairKey = (type(keys) == "table" and keys.p) or 25
  local timer = os.startTimer(1)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      if view.mode == "code" and not pair.pending() then showPrompt() end
      local now = os.epoch("utc")
      for _, by in pairs(sent) do
        for rid, slot in pairs(by) do
          if now - slot.at > memory then by[rid] = nil end
        end
      end
      for i = 1, #mods do
        local tick = mods[i].tick
        if type(tick) == "function" then
          local ok, err = pcall(tick, now)
          if not ok then print("so-server: tick " .. mods[i].name .. " failed: " .. tostring(err)) end
        end
      end
      timer = os.startTimer(1)
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
          if not ok then print("so-server: listen " .. mods[i].name .. " failed: " .. tostring(err)) end
        end
      end
    end
  end
end

local ok, err = pcall(S.run)
print = S.output
if not ok then error(err,0) end
