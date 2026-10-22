local skips = package.loaded["tests.skips"] or {}
package.loaded["tests.skips"] = skips
local M = {}
function M.record(name, reason)
  skips[#skips + 1] = name .. ": " .. reason
  print("SKIP " .. skips[#skips])
  return "skip", reason
end
function M.summary(passed, failed)
  for _, name in ipairs(skips) do print("SKIPPED " .. name) end
  print(string.format("%d tests passed, %d FAILED, %d skipped checks", passed - #skips, failed, #skips))
end
return M
