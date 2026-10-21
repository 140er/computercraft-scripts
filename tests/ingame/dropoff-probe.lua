local D = dofile("depth-result.lua")
local checks = {}
local before = 0
for slot = 1, 16 do before = before + turtle.getItemCount(slot) end
local handle = fs.open("dropoff-before.json", "w")
handle.write(textutils.serializeJSON({ turtle = before }))
handle.close()
local target = nil
if fs.exists("server-dropoff") then
  handle = fs.open("server-dropoff", "r")
  target = handle.readAll()
  handle.close()
end
local moved = 0
if target and target ~= "" then
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      moved = moved + (turtle.drop() or 0)
    end
  end
end
local after = 0
for slot = 1, 16 do after = after + turtle.getItemCount(slot) end
handle = fs.open("dropoff-after.json", "w")
handle.write(textutils.serializeJSON({
  before = before, after = after, moved = moved, target = target or false,
}))
handle.close()
D.check(checks, "miner delivers with no local drop-off config",
  target ~= nil and after == 0 and before > 0 and moved == before,
  "before " .. before .. " after " .. after .. " target " .. tostring(target))
D.finish(checks)
