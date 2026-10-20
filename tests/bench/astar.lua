local P = dofile("probe.lua")
local result = {v = 1, runtime = _HOST, samples = {}, physicalMoves = 0, gpsCalls = 0}
local pose = {dim = "minecraft:overworld", x = 0, y = 64, z = 0, h = 0}
local state = {version = 1, pose = pose, cells = {}}
for x = 0, 63 do
  for z = 0, 63 do state.cells[x .. ",64," .. z] = "minecraft:air" end
end
local f = assert(fs.open("astar.state", "w"))
f.write(textutils.serialize({schema = 1, generation = 1, value = state}, {compact = true}))
f.close()
local Nav = dofile("nav.lua")
for _, budget in ipairs({2048, 4096}) do
  local nav = Nav.open({
    path = "astar.state", pose = pose, maxCells = 4096, maxNodes = budget, batch = 32,
    bounds = {min = pose, max = {dim = pose.dim, x = 63, y = 64, z = 63}},
    observe = function() return pose end,
    client = {resync = function() return true end},
  })
  assert(nav.recover())
  for round = 1, 5 do
    sleep(0)
    local sample = P.measure(function()
      local count, why = nav.homeCost({dim = pose.dim, x = 63, y = 64, z = 63})
      if budget == 2048 then assert(count == false and why == "search budget")
      else assert(count == 126) end
      return {pathMoves = count, reason = why or false}
    end)
    sample.maxNodes, sample.batch, sample.round = budget, 32, round
    result.samples[#result.samples + 1] = sample
    P.save("astar-" .. budget, sample)
  end
end
result.ok = true
for _, row in ipairs(result.samples) do result.ok = result.ok and row.ok and row.belowTimeout end
P.save("astar", result)
return result
