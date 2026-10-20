local mocks = dofile("tests/mocks.lua")
local mock = mocks.new(false)
local env = setmetatable({}, {__index=_G})
env._G = env
for _, name in ipairs({"textutils", "colors", "peripheral", "os"}) do env[name] = mock.env[name] end
env.textutils.serializeJSON = env.textutils.serialize
env.textutils.unserializeJSON = env.textutils.unserialize
env.keys = {enter=28, up=200, down=208, backspace=14, escape=1, tab=15}
local monitor = env.peripheral.find("monitor")
env.term = {current=function() return monitor end}
env.settings = {get=function(_, default) return default end}
local modules = {}
function env.dofile(path) return assert(loadfile(path, "t", env))() end
function env.require(name)
  if not modules[name] then
    local prefix = name:match("^wh2%-wizard%-gate%-") and "tests/" or ""
    modules[name] = env.dofile(prefix .. name .. ".lua")
  end
  return modules[name]
end
local computers, computerId = {}, 5
for _, id in ipairs({5, 6}) do
  local disk = mocks.new(false)
  disk.capacity = 1000000
  disk.env.fs.getCapacity = function() return disk.capacity end
  disk.env.fs.getSize = function(path) return #assert(disk.files[path], path) end
  local open = disk.env.fs.open
  disk.env.fs.open = function(path, mode)
    if mode == "r" and not disk.files[path] then return nil end
    if mode == "a" and not disk.files[path] then disk.files[path] = "" end
    local file = open(path, mode)
    file.writeLine = function(value) file.write(value .. "\n") end
    return file
  end
  computers[id] = disk
end
local function switch(id) computerId, env.fs = id, computers[id].env.fs end
env.os.getComputerID = function() return computerId end
switch(5)
local events = {}
local function evidence(kind, value) events[#events + 1] = {kind=kind, value=value} end

local manifest = {schema=1, roles={server={"ssot-auth.lua"}, client={"ssot-auth.lua", "wh2-client.lua"}},
  authentication={version=2, mac="blake3-keyed", requireMac=true, keyOnWire=false},
  productionBoundaries={}, unboundRuntimeApis={"production dispatcher has no gate export"}}
local disk = computers[5]
disk.files["wh2-wizard-gate-prerequisites.json"] = mocks.encode(manifest)
local binding = env.require("wh2-wizard-gate-bindings")
local report = binding.inspect({role="board"})
assert(report.authenticated == false and #report.missing == 2, "missing auth files did not fail preflight")
local ok, err = pcall(binding.open, {role="board"})
assert(not ok and tostring(err):find("ssot%-auth.lua"), "missing production auth did not stop binding")
disk.files["ssot-auth.lua"], disk.files["wh2-client.lua"] = "return {}", "return {}"
ok, err = pcall(binding.open, {role="board"})
assert(not ok and tostring(err):find("runtime binding unavailable", 1, true), "file presence falsely enabled authentication")
disk.files["ssot-auth.lua"], disk.files["wh2-client.lua"] = nil, nil
disk.files["wizard-config.json"] = mocks.encode({enabled=true, role="board", diskLimit=1000000})
ok, err = pcall(env.require("wh2-wizard-gate-runtime").run)
assert(not ok and tostring(err):find("ssot%-auth.lua"), "runtime did not stop on missing authentication")
local boot = env.textutils.unserializeJSON(assert(disk.files["wizard-boot.json"]))
assert(boot.authenticated == false and boot.capacity == 1000000 and boot.role == "board" and boot.bootCount == 1,
  "failed production launch did not save a truthful native boot observation")
assert(disk.files["wizard-prerequisites.json"] and disk.files["wizard-events.jsonl"], "startup failure lost its evidence")

local module = env.require("wh2-wizard")
local checks = env.require("wh2-wizard-gate-checks")
local state = {}
local context = {config={enabled=true, operators={["5"]=true, ["6"]=true}}, now=1000000, epoch=1}
local client = {call=function(op, body)
  context.now = context.now + 1
  return module.run(state, computerId, {op=op, body=body}, context)
end}
local items = {"superbwarfare:galena_ore", "superbwarfare:silver_ore"}
local physical = {totals={[items[1]]=64, [items[2]]=19}}
checks.report(client, items, evidence, physical, "input:1")
checks.report(client, items, evidence, physical, "input:2")
assert(not pcall(checks.report, client, items, evidence, {totals={}}, "input:1"), "report accepted an unobserved item")
local saved = checks.draft(client, items[1], evidence, monitor)
checks.report(client, items, evidence, physical, "input:2")
checks.draftRetained(client, saved, evidence, monitor)
switch(6)
checks.draftOwner(client, items[1], evidence, monitor)
switch(5)
checks.draftOwner(client, items[1], evidence, monitor)
checks.discard(client, items[1], evidence, monitor)
checks.board(client, items, evidence, monitor)
local retained = checks.retained(client, items, evidence)
checks.retained(client, items, evidence, retained)
checks.fuzz(client, evidence)
checks.concurrent(client, evidence)
assert(module.valid(state.wh2.wizard))
local before = mocks.encode(state)
local accepted = {call=function(op, body)
  if op == "wh2-get" then return client.call(op, body) end
  return {ok=true}
end}
assert(not pcall(checks.fuzz, accepted, evidence), "fuzz check accepted a broken client")
context.config.enabled = false
assert(client.call("wh2-unknown", {wh2=1, item="minecraft:dirt", sampleLocationId=false}).ok == false)
assert(mocks.encode(state) == before, "disabled operation wrote state")
assert(#events >= 10)
print("Wizard scenario self-check passed. In-process assertions only. Gate A and Gate B remain separate.")
return true
