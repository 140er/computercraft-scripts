local W = dofile("/verify/world.lua")
local t, world = W.new({ delay = 0, fuel = 20000 })
_G.turtle = t
gps.locate = function()
  return world.pos.x, world.pos.y, world.pos.z
end
