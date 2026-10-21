-- 32 fleet state requests arrive during the boot save of a full server.state.
-- The disk is the default 1,000,000 bytes. All 32 replies come back.
-- A busy reply or a missing rid is a lost request.

local mocks = dofile("tests/mocks.lua")
local graph = dofile("tests/f0-graph.lua")

local state = assert(graph.read("tests/fixtures/full-state/server.state"), "server.state fixture missing")
local source = assert(graph.read("server.lua"))
local m = mocks.new(false)
m.capacity = 1000000
m.files["server.state"] = state
m.env.http = nil

local hooked = false
local serialize = m.env.textutils.serialize
m.env.textutils.serialize = function(value, ...)
  local text = serialize(value, ...)
  if not hooked and type(value) == "table" and value.schema == 1 and type(value.bots) == "table" then
    hooked = true
    for i = 1, 32 do
      m.env.os.queueEvent("rednet_message", 1, { type = "state", rid = "h3-" .. i }, "fleetserver")
    end
  end
  return text
end

m.sent = {}
local send = m.env.rednet.send
m.env.rednet.send = function(id, message, protocol)
  send(id, message, protocol)
  m.sent[#m.sent + 1] = message
end

local ok, err = pcall(function() m.start(source) end)
if not ok then
  print("h3 boot failed " .. tostring(err))
  os.exit(1)
end

local got = {}
local busy = 0
for _, message in ipairs(m.sent) do
  if type(message) == "table" and type(message.rid) == "string" and message.rid:match("^h3%-%d+$") then
    if message.type == "state" then got[message.rid] = true
    elseif message.type == "busy" then busy = busy + 1 end
  end
end

local replies, lost = 0, {}
for i = 1, 32 do
  local rid = "h3-" .. i
  if got[rid] then replies = replies + 1 else lost[#lost + 1] = rid end
end

print(string.format(
  "h3 hooked=%s replies=%d busy=%d lost=%d capacity=%d stateBytes=%d",
  tostring(hooked), replies, busy, #lost, m.capacity, #state))
if #lost > 0 then print("  lost " .. table.concat(lost, " ")) end

if not hooked or replies ~= 32 or busy ~= 0 or #lost > 0 then
  print("h3 failed")
  os.exit(1)
end
print("h3 passed")
