-- so-server.lua - entry point. Loads so-mod-*.lua and dispatches "so" messages.

local MIN = 16000000
local cap = fs.getCapacity("/")
if type(cap) ~= "number" or cap < MIN then
  print("so-server: need " .. MIN .. " bytes, this disk has " .. tostring(cap) .. ".")
  print("Set computer_space_limit in computercraft-server.toml to at least " .. MIN .. ", then restart the world.")
  return
end

local S = {}

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

  local builtin = {
    pair = function(msg, reply)
      local code = pair.pending()
      if code then
        local key = pair.derive(code, os.getComputerID(), msg.from)
        local saved, err = pair.remember(msg.from, key)
        if not saved then
          reply("err", { code = "store", text = tostring(err) })
          return
        end
        pair.clear()
      end
      reply("ack", { ok = true })
    end,
    hello = function(msg, reply)
      reply("ack", { ok = true })
    end,
  }

  local function replyTo(msg, t, body)
    local key = pair.key(msg.from)
    if not key then
      print("so-server: no key for " .. tostring(msg.from))
      return
    end
    local out = proto.build(key, t, body, msg.rid)
    rednet.send(msg.from, proto.encode(out), "so")
  end

  local function deliver(msg)
    local sent = false
    local function reply(t, body)
      if sent then return end
      sent = true
      replyTo(msg, t, body)
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
    if type(payload) ~= "string" then
      print("so-server: bad message from " .. tostring(sender))
      return
    end
    local msg = proto.decode(payload)
    if not msg or msg.from ~= sender then
      print("so-server: bad message from " .. tostring(sender))
      return
    end
    local key
    if msg.t == "pair" and pair.pending() then
      key = pair.derive(pair.pending(), os.getComputerID(), msg.from)
    else
      key = pair.key(msg.from)
    end
    if not key or not proto.macOk(key, msg) then
      print("so-server: bad mac from " .. tostring(sender))
      return
    end
    if not proto.fresh(msg) then
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
  pair.invite(term)
  local timer = os.startTimer(1)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      local now = os.epoch("utc")
      for i = 1, #mods do
        local tick = mods[i].tick
        if type(tick) == "function" then
          local ok, err = pcall(tick, now)
          if not ok then print("so-server: tick " .. mods[i].name .. " failed: " .. tostring(err)) end
        end
      end
      timer = os.startTimer(1)
    elseif ev == "rednet_message" and c == "so" then
      dispatch(a, b)
    end
  end
end

S.run()
