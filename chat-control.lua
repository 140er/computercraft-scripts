local M = {}
local SSOT = dofile("ssot.lua")
local actions = { hub = true, recharge = true, pro = true, xray = true }
local function uuid(value)
  if type(value) ~= "string" then return nil end
  value = value:lower()
  if value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then return value end
end
local function number(value)
  value = tonumber(value)
  if value and value == value and math.abs(value) <= 30000000 and value % 1 == 0 then return value end
end
local function words(text)
  local out = {}
  for word in text:gmatch("%S+") do out[#out + 1] = word end
  return out
end
function M.new(cfg, callbacks, auth)
  local self, pending, recent, serial = {}, {}, {}, 0
  local now = callbacks.now or function() return os.epoch("utc") end
  local session = tostring(now()) .. "-" .. tostring(math.random(1, 1073741824))
  local function save(key, value)
    local old = cfg[key]
    cfg[key] = value
    local ok, result, err = pcall(callbacks.save or function() return true end)
    if not ok or result == false then
      cfg[key] = old
      return false, tostring(err or result)
    end
    return true, "Saved " .. key
  end
  function self:command(args)
    local verb = args[1]
    if verb == "enable" and (args[2] == "on" or args[2] == "off") then
      pending, recent = {}, {}
      return save("chatEnabled", args[2] == "on")
    elseif verb == "allow" or verb == "deny" then
      local id = uuid(args[2])
      if not id then return false, "Supply a verified UUID and its exact username." end
      if not auth or not callbacks.saveAuth then return false, "Configure the shared SSOT allowlist locally first." end
      local name = args[3]
      if verb == "allow" and (type(name) ~= "string" or #name < 1 or #name > 16 or not name:match("^[%w_]+$")) then
        return false, "Supply the exact Minecraft username after its verified UUID."
      end
      local names, ids = {}, {}
      for _, allowed in ipairs(auth.chatNames or {}) do
        local enrolled=(auth.chatUUIDs or {})[allowed]
        if (type(enrolled)~="string" or enrolled:lower()~=id) and allowed ~= name then
          names[#names + 1], ids[allowed] = allowed, enrolled
        end
      end
      if verb == "allow" then
        if #names >= 32 then return false, "Allowlist limit is 32." end
        names[#names + 1], ids[name] = name, id
      end
      local oldNames, oldIds = auth.chatNames, auth.chatUUIDs
      auth.chatNames, auth.chatUUIDs = names, ids
      local ok, result, err = pcall(callbacks.saveAuth)
      if not ok or result == false then
        auth.chatNames, auth.chatUUIDs = oldNames, oldIds
        return false, tostring(err or result)
      end
      pending[id], recent[id] = nil, nil
      return true, "Saved shared chat authorization."
    elseif verb == "bounds" then
      if #args ~= 8 or not tostring(args[2]):match("^[%w_]+:[%w_/%-%.]+$") then
        return false, "bounds dimension x1 y1 z1 x2 y2 z2"
      end
      local n = {}
      for i = 3, 8 do n[i - 2] = number(args[i]) if not n[i - 2] then return false, "Coordinates must be finite integers." end end
      if n[1] > n[4] or n[2] > n[5] or n[3] > n[6] then return false, "Minimum must not exceed maximum." end
      return save("mineBounds", { dimension = args[2], min = { x = n[1], y = n[2], z = n[3] },
        max = { x = n[4], y = n[5], z = n[6] } })
    elseif verb == "spot" then
      if #args ~= 7 or (args[2] ~= "warehouse" and args[2] ~= "charging")
        or not tostring(args[3]):match("^[%w_%-]+$") or #args[3] > 32
        or not tostring(args[4]):match("^[%w_]+:[%w_/%-%.]+$") then
        return false, "spot warehouse|charging name dimension x y z"
      end
      local x, y, z = number(args[5]), number(args[6]), number(args[7])
      if not x or not y or not z then return false, "Coordinates must be finite integers." end
      local spots = { warehouse = {}, charging = {} }
      for kind, list in pairs(spots) do
        for name, point in pairs((cfg.spots or {})[kind] or {}) do list[name] = point end
      end
      local count = 0
      for _ in pairs(spots[args[2]]) do count = count + 1 end
      if count >= 64 and not spots[args[2]][args[3]] then return false, "Spot limit is 64 per kind." end
      spots[args[2]][args[3]] = { dimension = args[4], x = x, y = y, z = z }
      return save("spots", spots)
    end
    return false, "chat enable on|off; allow UUID name; deny UUID; bounds dimension x1 y1 z1 x2 y2 z2; spot warehouse|charging name dimension x y z"
  end
  function self:event(event, username, message, id, hidden)
    id = uuid(id)
    if event ~= "chat" or cfg.chatEnabled ~= true or not id or not auth or not SSOT.chatAllowed(auth, username, id)
      or type(username) ~= "string" or type(message) ~= "string" or #message > 256 then return false end
    if hidden == true then message = message:gsub("^%$", ""):gsub("^!", "")
    elseif hidden == false and message:sub(1, 1) == "!" then message = message:sub(2)
    else return false end
    local args = words(message)
    local action = table.remove(args, 1)
    local function reply(text)
      if callbacks.reply then pcall(callbacks.reply, username, text, hidden == true) end
    end
    if action == "anchor" then
      if #args ~= 1 then reply("Use $anchor <computer id>") return true, "rejected" end
      local ok, accepted, detail = pcall(callbacks.execute, "anchor", args, id, username)
      if not ok then reply("Command failed.") return true, "unavailable" end
      reply(tostring(detail or (accepted and "Applied." or "Unavailable.")))
      return true, accepted and "accepted" or "unavailable"
    end
    if not actions[action] and action ~= "confirm" then return false end
    local time = now()
    if action == "confirm" then
      local request = pending[id]
      if not request or #args ~= 1 or args[1] ~= request.token or time > request.expires then
        if recent[id] and time - recent[id].time < 2000 then return true, "rate-limited" end
        recent[id] = { message = message, time = time }
        reply("No matching pending confirmation.")
        return true, "rejected"
      end
      pending[id] = nil
      local ok, accepted, detail = pcall(callbacks.execute, request.action, request.args, id)
      if not ok then reply("Command failed.") return true, "failed" end
      reply(tostring(detail or (accepted and "Applied." or "Unavailable.")))
      return true, accepted and "accepted" or "unavailable"
    end
    if recent[id] and time - recent[id].time < 2000 then
      return true, recent[id].message == message and "duplicate" or "rate-limited"
    end
    recent[id] = { message = message, time = time }
    if (#args > 0 and action ~= "pro" and action ~= "xray")
      or #args > 1 or (#args == 1 and args[1] ~= "on" and args[1] ~= "off") then
      reply("Use !" .. action .. ((action == "pro" or action == "xray") and " [on|off]" or ""))
      return true, "rejected"
    end
    serial = serial + 1
    local token = session .. "-" .. serial
    pending[id] = { action = action, args = args, token = token, expires = time + 30000 }
    reply("Confirm " .. action .. " within 30s with " .. (hidden and "$" or "!") .. "confirm " .. token)
    return true, "pending"
  end
  return self
end
return M
