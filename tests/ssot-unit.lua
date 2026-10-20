local mocks = dofile("tests/mocks.lua")
local env = mocks.new(false).env
env.dofile = function(path) return assert(loadfile(path, "t", env))() end
local S, A = env.dofile("ssot.lua"), env.dofile("atomic.lua")
local checks = assert(loadfile("tests/ssot-checks.lua", "t", env))()
local failed = 0
checks(S, A, function(name, run)
  local ok, err = pcall(run)
  print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ": " .. tostring(err)))
  if not ok then failed = failed + 1 end
end)
env.dofile("tests/ssot-client-checks.lua")(function(name,run)
  local ok,err=pcall(run)
  print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ": " .. tostring(err)))
  if not ok then failed=failed+1 end
end,env.dofile("ssot-client.lua"))
assert(failed == 0, failed .. " SSOT failures")
