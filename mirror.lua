local roles = dofile("roles.lua")
local shelf = dofile("shelf.lua")
local A = dofile("atomic.lua")
local name = ({ ... })[1]
local sizeOf = roles.diskSize("/")
local measured = A.mount("/"):measure()
local fits, need, have = roles.fit(name, sizeOf, measured.capacity)
if not fits then
  print("shelf " .. tostring(name) .. " needs " .. tostring(need) .. " on " .. tostring(have))
  return
end
shelf.host({ name = name, roles = roles, sizeOf = sizeOf })
