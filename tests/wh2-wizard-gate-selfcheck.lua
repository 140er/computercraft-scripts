package.path = "./?.lua;./tests/?.lua;" .. package.path
local mock = require("mocks").new(false)
for _, name in ipairs({"textutils", "colors", "peripheral"}) do _G[name] = mock.env[name] end
keys = {enter=28, up=200, down=208, backspace=14, escape=1}
local monitor = peripheral.find("monitor")
term = {current=function() return monitor end}
local module = require("wh2-wizard")
local checks = require("wh2-wizard-gate-checks")
local state = {}
local context = {config={enabled=true, operators={["5"]=true}}, now=1234}
local client = {call=function(op, body) return module.run(state, 5, {op=op, body=body}, context) end}
local events = {}
local function evidence(kind, value) events[#events+1] = {kind=kind, value=value} end
local items = {"superbwarfare:galena_ore", "superbwarfare:silver_ore"}
for _, item in ipairs(items) do
  local first = assert(client.call("wh2-unknown", {wh2=1, item=item, sampleLocationId="input:1"}))
  assert(first.ok)
  local second = client.call("wh2-unknown", {wh2=1, item=item, sampleLocationId="input:2"})
  assert(second.ok and second.revision == first.revision, "duplicate report changed revision")
end
checks.board(client, items, evidence, monitor)
checks.retained(client, items, evidence)
checks.fuzz(client, evidence)
checks.concurrent(client, evidence)
assert(module.valid(state.wh2.wizard))
local before = textutils.serialize(state)
local accepted = {call=function(op, body)
  if op == "wh2-get" then return client.call(op, body) end
  return {ok=true}
end}
assert(not pcall(checks.fuzz, accepted, evidence), "fuzz check accepted a broken client")
context.config.enabled = false
assert(client.call("wh2-unknown", {wh2=1, item="minecraft:dirt", sampleLocationId=false}).ok == false)
assert(textutils.serialize(state) == before, "disabled operation wrote state")
assert(#events >= 5)
print("Wizard scenario self-check passed. In-process adapter only; no runtime gate claim.")
