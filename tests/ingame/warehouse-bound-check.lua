local handle = assert(io.open("tests/warehouse-runtime.lua", "rb"))
local text = handle:read("*a")
handle:close()
local bound = tonumber(text:match('assert%(ticks<(%d+),"warehouse tick bound"%)'))
local pause = tonumber(text:match('assert%(ticks<%d+,"warehouse tick bound"%)\r?\n%s*local ok,why=w%.tick%(%)\r?\n%s*if not ok then assert%(why=="charging" or why=="bay occupied",why%) end\r?\n%s*sleep%(([%d%.]+)%)'))
local timeout = tonumber(text:match("chargeTimeout=(%d+)"))
assert(bound and pause and timeout, "warehouse loop bound was not found")
local function covers(limit, step, waitMs)
  return limit * step * 1000 >= waitMs
end
assert(not covers(200, 0.05, 60000), "the old 200 tick bound should be shorter than the charge timeout")
assert(covers(bound, pause, timeout), "warehouse tick bound is shorter than chargeTimeout")
print("PASS warehouse tick bound covers chargeTimeout " .. timeout)
