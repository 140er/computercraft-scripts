local P = dofile("probe.lua")
local id = os.getComputerID()
local boots = 0
if fs.exists("boots") then
  local h = assert(fs.open("boots", "r"))
  boots = tonumber(h.readAll()) or 0
  h.close()
end
boots = boots + 1
local h = assert(fs.open("boots", "w"))
h.write(tostring(boots))
h.close()
P.save("boot", {ok = true, boots = boots, at = os.epoch("utc"), id = id})
if periphemu and id > 0 then _G.turtle = {getFuelLevel = function() return 1000 end} end
local summary = {v = 1, ok = true, runtime = _HOST, computer = id, boots = boots,
  turtleIsMock = periphemu ~= nil and id > 0, results = {}}
if not fs.exists("results/storage.json") then
  local ok, value = pcall(dofile, "storage.lua")
  summary.results.storage = ok and value.ok or false
  if not ok then P.save("storage-error", {ok = false, error = tostring(value)}) end
end
if id == 0 and not fs.exists("initial-complete") then
  for _, name in ipairs({"crypto", "astar", "randomness"}) do
    local ok, value = pcall(dofile, name .. ".lua")
    summary.results[name] = ok and value.ok or false
    if not ok then P.save(name .. "-error", {ok = false, error = tostring(value)}) end
  end
end
for _, ok in pairs(summary.results) do summary.ok = summary.ok and ok end
P.save("initial", summary)
local done = assert(fs.open("initial-complete", "w"))
done.write("complete")
done.close()
if not periphemu then
  local ok, why = pcall(dofile, "world.lua")
  if not ok then P.save("world-error", {ok = false, error = tostring(why)}) end
end
while true do sleep(1) end
