local adapter = dofile("role-adapter.lua")
local _, message = adapter.warehouse()
print(message)
return false
