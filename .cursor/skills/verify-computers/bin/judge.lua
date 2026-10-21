local result_path, startup_path, bytes_s, expect, extra_path = arg[1], arg[2], arg[3], arg[4], arg[5]
local bytes = tonumber(bytes_s)

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function finish(ok, fields)
  local keys = { "free", "capacity", "returned", "bytes" }
  local parts = { ok and "PASS" or "FAIL" }
  for _, key in ipairs(keys) do
    if fields[key] ~= nil then parts[#parts + 1] = key .. "=" .. tostring(fields[key]) end
  end
  if fields.reason then parts[#parts + 1] = (fields.reason:gsub("%s+$", "")) end
  print(table.concat(parts, " "))
  os.exit(ok and 0 or 1)
end

local text = slurp(result_path)
if not text then finish(false, { bytes = bytes, reason = "no result" }) end
local returned, err = text:match("program returned: (%S+)%s+pcall err: ([^\n]*)")
local capacity, free = text:match("capacity (%S+) free (%S+)")
local fields = {
  returned = returned or "missing",
  capacity = capacity or "missing",
  free = free or "missing",
  bytes = bytes,
}

local function bad(reason)
  fields.reason = reason
  finish(false, fields)
end

if not returned then bad("result missing program line") end
if capacity ~= "1000000" then bad("capacity " .. tostring(capacity)) end
local free_n = tonumber(free)
if not free_n then bad("free space missing") end
if free_n < 0 then bad("free space below 0") end
if not bytes or bytes > 1000000 then bad("role bytes " .. tostring(bytes) .. " over 1000000") end

local startup = slurp(startup_path)
if not startup or not startup:find("shell.run", 1, true) then bad("startup missing") end

local screen = text:match("\n%-%- screen\n(.*)$") or ""
local blob = text .. "\n" .. (extra_path and (slurp(extra_path) or "") or "")
if blob:find("disk full", 1, true) then bad("disk full") end
if screen:find("Too long without yielding", 1, true) then bad("serialize yielded too long") end
if err and err ~= "nil" then bad("err " .. err) end
for line in screen:gmatch("[^\n]+") do
  if line:match("^/?%S+%.lua:%d+:") then bad("crash " .. line) end
end
if screen:find("Type an answer and press enter.", 1, true) then bad("waiting for setup input") end

if expect == "stay" then
  if returned ~= "false" then bad("program exited") end
elseif expect == "order" then
  if not screen:find("ORDER", 1, true) then bad("order screen missing") end
elseif expect == "cache" then
  if returned ~= "false" then bad("server exited") end
  if not blob:find("server-code/", 1, true) then bad("cache stored nothing") end
elseif expect ~= "fit" then
  bad("unknown expect " .. tostring(expect))
end

finish(true, fields)
