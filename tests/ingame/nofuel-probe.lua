local moved = false
local ok = pcall(function() moved = turtle.forward() end)
local handle = fs.open("nofuel-result.json", "w")
handle.write(textutils.serializeJSON({ moved = moved and true or false, ok = ok and true or false }))
handle.close()
local D = dofile("depth-result.lua")
local checks = {}
D.check(checks, "unfueled turtle stays put", moved ~= true, "turtle.forward moved a turtle with no fuel")
D.finish(checks)
