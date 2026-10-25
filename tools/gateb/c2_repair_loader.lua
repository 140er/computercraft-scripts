-- Test-only observer. The installed display file and its trust decisions stay intact.
local original = loadfile
return function(path, env)
  if path ~= "/display.lua" then return original(path, env) end
  local h = assert(fs.open(path, "r"))
  local source = h.readAll()
  h.close()
  local hook = [[
local count = 0
local input = C.fixInput
C.fixInput = function(...)
  local result = input(...)
  count = count + 1
  return result
end
GATEB_REPAIR = function()
  local out = { server = C.server, phase = C.phase, step = C.fix and C.fix.step,
    readonly = C.fix and C.fix.view == true, digits = #C.digits, inputs = count,
    peers = {}, stores = {} }
  for _, row in ipairs(C.pair.list()) do
    out.peers[tostring(row.id)] = C.proto.hex(C.proto.sha256(C.pair.key(row.id))):sub(1, 16)
  end
  for _, name in ipairs({ "so-keys", "so-keys.bak", "so-keys.tmp" }) do
    local file = fs.open(name, "r")
    if file then
      local raw = file.readAll()
      file.close()
      out.stores[name] = C.proto.hex(C.proto.sha256(raw)):sub(1, 16)
    else out.stores[name] = false end
  end
  return out
end
C.loop()
]]
  local changed, n = source:gsub("C%.loop%(%)%s*$", function() return hook end)
  assert(n == 1, "C2 repair observer needs the display loop entry")
  return load(changed, "@/display.lua", "t", env)
end
