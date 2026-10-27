local H = dofile("tests/so/harness.lua")
local F = { root = "so-data/cells/minecraft%3aoverworld/" }
F.path = function(n) return F.root .. (100 + n) .. "_0_0" end
F.seed = function(m, count, first)
  for i = first or 1, count do
    local value = { format = "hex4096", bits = "1" .. string.rep("0", 1023), used = i }
    m.files[F.path(i)] = H.encode({ schema = 1, generation = 2, value = value })
    m.files[F.path(i) .. ".bak"] = H.encode({ schema = 1, generation = 1, value = value })
  end
end
F.setup = function(files, count)
  local net = H.new()
  local m = net.machine({ id = 1, directories = true })
  m.install({ "so-store.lua", "so-mod-cells.lua", "so-plan.lua", "so-mine-plan.lua", "so-mod-mine.lua",
    "so-lumber-plan.lua", "so-mod-lumber.lua", "so-mod-lease.lua" })
  m.files["so-server.cfg"]=H.encode({protectedAreas=false,alternateAxisOrders=false,storageDeliveries=false,workerPark=false})
  for path, bytes in pairs(files or {}) do m.files[path] = bytes end
  if count then F.seed(m, count) end
  m.env.SO = { now = function() return m.env.os.epoch("utc") end, mods = {}, store = m.env.dofile("so-store.lua"), breathe = function() end,
    pair = { key = function() return "key" end }, proto = {
      build = function(_, t, body) return { t=t, body=body } end, encode = function(v) return v end,
    } }
  local cells = m.env.dofile("so-mod-cells.lua")
  m.env.SO.mods.cells = cells
  return cells, m, net
end
return F
