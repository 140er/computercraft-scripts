local M = {}

local MAX = 9007199254740991

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function effects()
  return {
    { op = "stop_mining" },
    { op = "head_home" },
    { op = "notify", panel = true, glasses = true, chat = true,
      text = "Disk is full. This turtle stopped new mining and is heading home. Nothing was dropped." },
  }
end

function M.open(freeBytes, reserve)
  if freeBytes == "unlimited" then freeBytes = MAX end
  reserve = reserve or 65536
  if not integer(freeBytes, 0, MAX) or not integer(reserve, 0, MAX) then return nil, "bad free space" end
  local budget = freeBytes - reserve
  if budget < 0 then budget = 0 end
  return { v = 1, items = {}, bytes = 0, budget = budget, full = false }
end

function M.read(raw, freeBytes, reserve)
  if type(raw) ~= "table" or raw.v ~= 1 then return nil, "unknown buffer v" end
  if type(raw.items) ~= "table" or (raw.full ~= true and raw.full ~= false) then return nil, "invalid buffer" end
  if not integer(raw.bytes, 0, MAX) or not integer(raw.budget, 0, MAX) then return nil, "invalid buffer" end
  local items, bytes = {}, 0
  for i = 1, #raw.items do
    local obs = raw.items[i]
    if type(obs) ~= "table" or not integer(obs.bytes, 1, MAX) then return nil, "invalid buffer" end
    local copy = {}
    for k, v in pairs(obs) do copy[k] = v end
    items[#items + 1] = copy
    bytes = bytes + obs.bytes
  end
  if bytes ~= raw.bytes then return nil, "invalid buffer" end
  local restored = { v = 1, items = items, bytes = bytes, budget = raw.budget, full = raw.full }
  if freeBytes ~= nil then
    local runtime, err = M.open(freeBytes, reserve)
    if not runtime then return nil, err end
    if runtime.budget < restored.bytes then restored.budget = restored.bytes
    else restored.budget = runtime.budget end
  end
  return restored
end

function M.push(buf, obs)
  if type(obs) ~= "table" or not integer(obs.bytes, 1, MAX) then return nil, "bad observation" end
  if buf.bytes + obs.bytes > buf.budget then
    local fired = {}
    if not buf.full then
      buf.full = true
      fired = effects()
    end
    return false, fired
  end
  local copy = {}
  for k, v in pairs(obs) do copy[k] = v end
  buf.items[#buf.items + 1] = copy
  buf.bytes = buf.bytes + obs.bytes
  return true, {}
end

return M
