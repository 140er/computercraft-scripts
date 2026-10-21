local before = turtle.getItemCount(1)
local dropped = 0
pcall(function() dropped = turtle.drop() end)
local after = turtle.getItemCount(1)
local handle = fs.open("fullchest-result.json", "w")
handle.write(textutils.serializeJSON({ before = before, dropped = dropped, after = after }))
handle.close()
local D = dofile("depth-result.lua")
local checks = {}
D.check(checks, "full chest keeps the stack", after == before and before > 0, "before " .. tostring(before) .. " after " .. tostring(after))
D.finish(checks)
