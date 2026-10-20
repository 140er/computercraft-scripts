local mocks=dofile("tests/mocks.lua")
local fixture=dofile("tests/nav-fixture.lua")(nil,mocks)
local failures=0
dofile("tests/nav-checks.lua")(function(name,run)
  local ok,err=pcall(run)
  print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ": " .. tostring(err)))
  if not ok then failures=failures+1 end
end,nil,fixture)
assert(failures==0,failures .. " navigation failures")
