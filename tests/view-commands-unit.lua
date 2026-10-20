local mocks=dofile("tests/mocks.lua")
local function read(path)
  local f=assert(io.open(path,"rb"))
  local s=f:read("*a")
  f:close()
  return s
end
local failed=0
dofile("tests/view-command-checks.lua")(function(name,run)
  local ok,why=pcall(run)
  print((ok and "PASS " or "FAIL ")..name)
  if not ok then failed=failed+1 print(why) end
end,read,mocks)
if failed>0 then os.exit(1) end
