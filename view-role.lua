local adapter = dofile("role-adapter.lua")
local _, message = adapter.view(({ ... })[1] or "View")
print(message)
return false
