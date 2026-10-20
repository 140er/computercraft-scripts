local M = {}

function M.present(value)
  if value == nil then return false end
  if type(value) == "string" and value == "" then return false end
  return true
end

function M.choiceValue(choice)
  if type(choice) == "table" then
    if choice.value ~= nil then return choice.value end
    return choice[1]
  end
  return choice
end

function M.resolve(explicit, saved, discovered)
  if M.present(explicit) then return explicit, "config" end
  if M.present(saved) then return saved, "saved" end
  if type(discovered) == "table" and discovered.choices then
    if #discovered.choices == 1 then return M.choiceValue(discovered.choices[1]), "discover" end
    return nil, "ask"
  end
  if M.present(discovered) then return discovered, "discover" end
  return nil, "ask"
end

function M.secret(explicit, saved)
  if type(explicit) == "string" and #explicit >= 16 and #explicit <= 128 then return explicit, "config" end
  if type(saved) == "string" and #saved >= 16 and #saved <= 128 then return saved, "saved" end
  return nil, "enrol"
end

local HIDDEN = {
  secret = true, pairingKey = true, key = true, peerKey = true,
  commandAuth = true, apiKey = true,
}

function M.redact(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return {} end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    if type(k) == "string" and HIDDEN[k] then out[k] = true
    else out[k] = M.redact(v, seen) end
  end
  seen[value] = nil
  return out
end

function M.fill(explicit, saved, discovered, asker, spec)
  if M.present(explicit) then return explicit, "config" end
  if M.present(saved) then return saved, "saved" end
  local found = discovered
  if type(discovered) == "function" then
    local ok, value = pcall(discovered)
    found = ok and value or nil
  end
  local value, source = M.resolve(nil, nil, found)
  if source == "discover" then return value, source end
  if not asker then return nil, "ask" end
  local prompt = {}
  if type(spec) == "table" then
    for k, v in pairs(spec) do prompt[k] = v end
  end
  if type(found) == "table" and found.choices and #found.choices > 1 then
    prompt.kind = "choice"
    prompt.choices = found.choices
  end
  local picked, why = asker(prompt)
  if picked == nil then return nil, why or "ask" end
  return picked, "prompt"
end

function M.takeSecret(explicit, saved, enroler)
  local value, source = M.secret(explicit, saved)
  if source ~= "enrol" then return value, source end
  if not enroler then return nil, "enrol" end
  local claimed = enroler()
  if type(claimed) == "table" and type(claimed.secret) == "string" then
    return claimed.secret, "enrol", claimed.server
  end
  return nil, "enrol"
end

local function openModem(env)
  local p, rednet = env.peripheral, env.rednet
  if not p or type(p.find) ~= "function" or not rednet or type(rednet.open) ~= "function" then return end
  local modem = p.find("modem", function(_, device)
    return device.isWireless and device.isWireless()
  end)
  if not modem then modem = p.find("modem") end
  if modem and p.getName then
    local name = p.getName(modem)
    if name then pcall(rednet.open, name) end
  end
end

function M.lookup(env, protocol, host)
  if type(env) ~= "table" or not env.rednet or type(env.rednet.lookup) ~= "function" then return nil end
  openModem(env)
  local ids = { env.rednet.lookup(protocol, host) }
  local choices = {}
  for i = 1, #ids do
    if type(ids[i]) == "number" then choices[#choices + 1] = ids[i] end
  end
  if #choices == 0 then return nil end
  if #choices == 1 then return choices[1] end
  return { choices = choices }
end

function M.facings()
  return {
    { value = 0, label = "north" }, { value = 1, label = "east" },
    { value = 2, label = "south" }, { value = 3, label = "west" },
  }
end

function M.place(env, asker, title)
  local fix = M.gps(env)
  if fix then return fix, "discover" end
  if not asker then return nil, "ask" end
  local picked = asker({ kind = "coord", title = title or "Setup", question = "Where is this computer?" })
  if type(picked) == "table" and picked.x and picked.y and picked.z then return picked, "prompt" end
  return nil, "ask"
end

function M.gps(env, timeout)
  if type(env) ~= "table" or not env.gps or type(env.gps.locate) ~= "function" then return nil end
  local x, y, z = env.gps.locate(timeout or 2)
  if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
  return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

function M.names(env, kind, filter)
  local p = type(env) == "table" and env.peripheral or nil
  if not p or type(p.getNames) ~= "function" then return nil end
  local choices = {}
  for _, name in ipairs(p.getNames()) do
    local typ = p.getType and p.getType(name)
    if (not kind or typ == kind) and (not filter or filter(name, typ)) then
      choices[#choices + 1] = name
    end
  end
  if #choices == 0 then return nil end
  if #choices == 1 then return choices[1] end
  return { choices = choices }
end

function M.adopt(controllers, paired)
  if type(controllers) ~= "table" then return false end
  local changed = false
  for id, rec in pairs(paired or {}) do
    if controllers[id] == nil and type(rec) == "table" and type(rec.key) == "string"
      and #rec.key >= 16 and #rec.key <= 128 then
      controllers[id] = rec.key
      changed = true
    end
  end
  return changed
end

function M.claim(enrol, rpc, codeText, id, nonce)
  local codeId, code = enrol.parse(codeText)
  if not code or not codeId then return nil, "code" end
  nonce = nonce or string.format("%08x%08x", math.random(0, 2147483647), math.random(0, 2147483647))
  local hello, why = rpc("enrol-hello", { codeId = codeId, nNew = nonce })
  if type(hello) ~= "table" or hello.ok ~= true then return nil, type(hello) == "table" and hello.error or why or "hello" end
  local body = {
    id = id, server = hello.server, codeId = codeId,
    nNew = nonce, nServer = hello.nServer, newPub = "", serverPub = "",
  }
  local done, err = rpc("enrol-claim", {
    codeId = codeId, nNew = nonce, nServer = hello.nServer,
    newPub = "", serverPub = "", proof = enrol.proof(code, body),
  })
  if type(done) ~= "table" or done.ok ~= true then return nil, type(done) == "table" and done.error or err or "claim" end
  return { server = hello.server, secret = enrol.pairingKey(code, body) }
end

function M.rpc(env, serverId)
  return function(op, fields)
    local rednet = env.rednet
    local id = serverId
    if type(id) ~= "number" then
      local found = M.lookup(env, "fleetserver", "server")
      if type(found) ~= "number" then return nil, "server" end
      id = found
    end
    local msg = {
      v = 1, type = "ssot", expect = "ssot_reply", op = op, boot = "plug",
      rid = op, counter = 1, secret = "",
    }
    for k, v in pairs(fields or {}) do msg[k] = v end
    rednet.send(id, msg, "fleetserver")
    local timer = os.startTimer(5)
    while true do
      local ev, a, b, c = os.pullEvent()
      if ev == "rednet_message" and a == id and c == "fleetserver" and type(b) == "table" and b.rid == msg.rid then
        return b
      elseif ev == "timer" and a == timer then
        return nil, "timeout"
      end
    end
  end
end

function M.savedPairing()
  if not (fs and fs.exists and fs.exists("install.cfg") and fs.open and textutils) then return nil end
  local h = fs.open("install.cfg", "r")
  if not h then return nil end
  local body = h.readAll()
  h.close()
  local ok, parsed = pcall(textutils.unserialize, body or "")
  if ok and type(parsed) == "table" and type(parsed.pairingKey) == "string" then return parsed.pairingKey end
end

local function show(io, text)
  io.shown = io.shown or {}
  io.shown[#io.shown + 1] = text
  if io.write then io.write(text) end
end

function M.ask(io, spec)
  if type(io) ~= "table" or type(spec) ~= "table" or spec.kind == "secret" then
    return nil, "secrets are not typed"
  end
  show(io, spec.title or "Setup")
  show(io, spec.question or "")
  local choices = spec.choices or {}
  if spec.kind == "hidden" then
    show(io, "Type it. The screen does not keep it.")
    if type(io.readHidden) ~= "function" then return nil, "secrets are not typed" end
    local text = io.readHidden()
    if type(text) ~= "string" or text == "" then return nil end
    return text
  end
  if spec.kind == "choice" or (#choices > 0 and spec.kind ~= "text" and spec.kind ~= "number" and spec.kind ~= "coord") then
    for i, choice in ipairs(choices) do
      local label = type(choice) == "table" and (choice.label or tostring(M.choiceValue(choice))) or tostring(choice)
      show(io, tostring(i) .. " " .. label)
    end
    show(io, "Tap a row or press its number.")
    while true do
      local ev, a, _, c = io.pull()
      if ev == nil then return nil end
      if ev == "char" and type(a) == "string" and a:match("^[1-9]$") then
        local n = tonumber(a)
        if choices[n] then return M.choiceValue(choices[n]) end
      elseif ev == "mouse_click" or ev == "monitor_touch" then
        local n = c - 2
        if choices[n] then return M.choiceValue(choices[n]) end
      elseif ev == "key" and io.keys and a == io.keys.enter and #choices == 1 then
        return M.choiceValue(choices[1])
      elseif ev == "char" and a == "q" then
        return nil
      end
    end
  end
  if spec.kind == "coord" then
    local function num(label, fallback)
      show(io, label)
      local text = io.read(fallback)
      return tonumber(text)
    end
    local preset = spec.default
    local x = num("X", preset and preset.x)
    local y = num("Y", preset and preset.y)
    local z = num("Z", preset and preset.z)
    if not (x and y and z) then return nil end
    return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
  end
  show(io, spec.hint or "Type an answer and press enter.")
  local text = io.read(spec.default)
  if type(text) ~= "string" or text == "" then return nil end
  if spec.kind == "number" then return tonumber(text) end
  return text
end

function M.termio()
  return {
    write = function(text) print(tostring(text)) end,
    pull = function() return os.pullEvent() end,
    read = function(default)
      return read(nil, nil, nil, default ~= nil and tostring(default) or nil)
    end,
    readHidden = function() return read("*") end,
    keys = keys,
  }
end

function M.load()
  if not (fs and fs.exists and fs.exists("plug.lua")) then return nil end
  local ok, mod = pcall(dofile, "plug.lua")
  if ok and type(mod) == "table" and type(mod.fill) == "function" then return mod end
end

return M
