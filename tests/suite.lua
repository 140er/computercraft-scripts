-- Keep the canonical append-only runner intact; replace only its test callback.
local index, count, selectorSeen = 1, 1, false
for _, value in ipairs(arg or {}) do
  local i, n = value:match("^%-%-shard=(%d+)/(%d+)$")
  if value:match("^%-%-shard") then
    assert(i and not selectorSeen, "invalid or repeated shard selector")
    index, count, selectorSeen = tonumber(i), tonumber(n), true
  end
end
assert(index >= 1 and index <= count and count <= 64, "invalid shard")
local input = assert(io.open("tests/full.lua", "rb"))
local source = input:read("*a")
input:close()
local keys, known = { "tests/run.lua" }, { ["tests/run.lua"] = true }
for path in source:gmatch('dofile%("([^"]+)"%)') do
  if path ~= "tests/mocks.lua" and path ~= "tests/so/harness.lua" and path ~= "tests/skips.lua" and not known[path] then
    keys[#keys + 1], known[path] = path, true
  end
end
keys[#keys + 1] = "tests/so/so11.lua:B"
local costs = dofile("tests/suite-costs.lua")
table.sort(keys, function(a, b)
  if (costs[a] or 1) == (costs[b] or 1) then return a < b end
  return (costs[a] or 1) > (costs[b] or 1)
end)
local groups, loads = {}, {}
for shard = 1, count do loads[shard] = 0 end
for _, key in ipairs(keys) do
  local best = 1
  for shard = 2, count do if loads[shard] < loads[best] then best = shard end end
  groups[key] = best
  loads[best] = loads[best] + (costs[key] or 1)
end
local function selected(key) return groups[key] == index end
local passed, failed, skipped = 0, 0, {}
local totals = {}
local hostPrint, hostDofile = print, dofile
local function check(name, fn)
  local path = debug.getinfo(fn, "S").source:gsub("^@", "")
  if path == "tests/full.lua" then path = "tests/run.lua" end
  local group = path
  if path == "tests/so/so11.lua" and name:match("^SO11 B") then group = path .. ":B" end
  assert(groups[group], "unassigned test group: " .. path)
  if not selected(group) then return end
  local began = os.clock()
  local ok, result, reason = pcall(fn)
  local elapsed = os.clock() - began
  totals[path] = (totals[path] or 0) + elapsed
  if ok and result == "skip" then
    skipped[#skipped + 1] = name .. ": " .. tostring(reason)

  elseif ok then passed = passed + 1; hostPrint("PASS " .. name)
  else failed = failed + 1; hostPrint("FAIL " .. name .. "\n  " .. tostring(result):sub(1, 1500)) end
  hostPrint(string.format("CHECK-TIME %.6f %s | %s", elapsed, path, name))
end
local env = setmetatable({ __suite_test = check }, { __index = _G })
env.print = function(value, ...)
  if type(value) ~= "string" or not value:match("^%d+ tests passed") then hostPrint(value, ...) end
end
env.dofile = function(path)
  local omit = groups[path] and not selected(path)
  if path == "tests/so/so11.lua" then omit = omit and not selected(path .. ":B") end
  if omit then
    return setmetatable({ run = function() end }, { __call = function() end })
  end
  return hostDofile(path)
end
local marker = "local function equal(actual, expected, message)"
local start = assert(source:find(marker, 1, true), "canonical test callback marker changed")
assert(not source:find(marker, start + #marker, true), "ambiguous test callback marker")
source = source:sub(1, start - 1) .. "test = __suite_test\n" .. source:sub(start)
local ok, err = pcall(assert(load(source, "@tests/full.lua", "t", env)))
if not ok then failed = failed + 1; hostPrint("FAIL suite loader: " .. tostring(err)) end
local names = {}
for path in pairs(totals) do names[#names + 1] = path end
table.sort(names)
for _, path in ipairs(names) do hostPrint(string.format("FILE-TIME %.6f %s", totals[path], path)) end
for _, name in ipairs(skipped) do hostPrint("SKIPPED " .. name) end
hostPrint(string.format("%d tests passed, %d FAILED, %d skipped checks, shard %d/%d", passed, failed, #skipped, index, count))
os.exit(failed > 0 and 1 or 0)
