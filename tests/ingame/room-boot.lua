local function fail(msg)
  local D = dofile("depth-result.lua")
  local checks = {}
  D.check(checks, "roomsorter scan", false, msg)
  D.finish(checks)
  local handle = fs.open("room-failed.txt", "w")
  handle.write(tostring(msg))
  handle.close()
end

local ok, err = pcall(function()
  shell.run("roomsorter.lua", "scan", "3")
end)
if not ok then
  fail(err)
  while true do sleep(5) end
end

local mapEnv = dofile("atomic.lua").read("room.map")
if type(mapEnv) ~= "table" or type(mapEnv.value) ~= "table" or type(mapEnv.value.stations) ~= "table" then
  fail("scan did not save a room map")
  while true do sleep(5) end
end

local cells = {}
for _, station in ipairs(mapEnv.value.stations) do
  local cell = station.floor and station.floor.cell
  if type(cell) == "string" then cells[#cells + 1] = cell end
end
local handle = fs.open("depth-stations.json", "w")
handle.write(textutils.serializeJSON({ stations = cells, count = #cells }))
handle.close()
shell.run("roomsorter.lua")
while true do sleep(5) end
