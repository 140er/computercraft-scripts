local mocks=dofile("tests/mocks.lua")
local function read(path)
  if arg[1]=="--yielding-read" then coroutine.yield("source-read") end
  if arg[1]=="--baseline" and (path=="server.lua" or path=="chat-control.lua" or path=="ssot.lua") then
    local pipe=assert(io.popen("git show HEAD:"..path,"r"))
    local text=pipe:read("*a")
    assert(pipe:close())
    return text
  end
  local file=assert(io.open(path,"rb"))
  local text=file:read("*a")
  file:close()
  return text
end
if arg[1]=="--baseline" then
  local original=dofile
  dofile=function(path)
    if path=="chat-control.lua" then return assert(load(read(path),"@"..path,"t",_G))() end
    return original(path)
  end
end
local failed=0
local function test(name,fn)
  local ok,err=pcall(fn)
  print((ok and "PASS " or "FAIL ")..name..(ok and "" or "\n  "..tostring(err)))
  if not ok then failed=failed+1 end
end
local function run()
  dofile("tests/auth-review-checks.lua")(test,read,mocks)
  if arg[1]~="--baseline" then
    dofile("tests/chat-checks.lua")(test,read,mocks)
    dofile("tests/recharge-review-checks.lua")(test,read,mocks)
  end
end
if arg[1]=="--yielding-read" then
  local worker=coroutine.create(run)
  repeat assert(coroutine.resume(worker)) until coroutine.status(worker)=="dead"
else
  run()
end
if failed>0 then os.exit(1) end
