-- CraftOS-PC 2.8.3 Windows rejects large integer %d values used by so-proto.
local nativeFormat = string.format
local ok, failure = pcall(nativeFormat, "%d", 1750000000000)
local report = { integerFormatShim = not ok }
if not ok then
  report.nativeFormatError = tostring(failure)
  local function exact(value)
    return type(value) == "number" and value % 1 == 0 and math.abs(value) < 2 ^ 53
  end
  string.format = function(pattern, ...)
    if pattern == "%d" and select("#", ...) == 1 and exact(...) then
      return nativeFormat("%.0f", ...)
    elseif pattern == "%d-%d-%d" and select("#", ...) == 3 then
      local a, b, c = ...
      if exact(a) and exact(b) and exact(c) then return nativeFormat("%.0f-%.0f-%.0f", a, b, c) end
    end
    return nativeFormat(pattern, ...)
  end
end
assert(string.format("%d", 1750000000000) == "1750000000000")
assert(string.format("%d-%d-%d", 2, 1750000000000, 1) == "2-1750000000000-1")
assert(string.format("%02x", 255) == "ff")
return report
