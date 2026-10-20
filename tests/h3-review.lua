local ok,err=pcall(function()
if not peripheral.isPresent("left") then assert(periphemu.create("left", "modem", 1)) end
local call = peripheral.call
peripheral.call = function(name, method, ...)
  if name == "left" and method == "isWireless" then return true end
  return call(name, method, ...)
end
local drawn=false
local native=term.native()
local screen=setmetatable({}, {__index=native})
screen.write=function(text)
  native.write(text)
  if tostring(text):find("Fleet server #",1,true) then drawn=true end
end
local terminal=setmetatable({native=function() return screen end}, {__index=term})
local env = setmetatable({http=false,term=terminal}, {__index=_ENV})
env._G=env
parallel.waitForAny(function() assert(loadfile("server.lua", "t", env))() end, function()
  local deadline=os.clock()+90
  while not drawn do assert(os.clock()<deadline,"server did not draw its fleet screen") sleep(.1) end
  sleep(2)
  term.screenshot()
  sleep(1)
  os.shutdown()
end)
end)
if not ok then
  local h=assert(fs.open("h3-review-error.txt","w")) h.write(tostring(err)) h.close()
  error(err,0)
end
