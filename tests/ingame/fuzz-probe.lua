local D = dofile("depth-result.lua")
local Craft = dofile("wh2-craft.lua")
local Wizard = dofile("wh2-wizard.lua")
local Fleet = dofile("wh2-fleet.lua")
local Layout = dofile("wh2-layout.lua")
local Ledger = dofile("storage-ledger.lua")
local Ssot = dofile("ssot.lua")
local checks = {}
local seed = 1666
local state = seed

local function rnd()
  state = (state * 1103515245 + 12345) % 2147483648
  return state
end

local function junk()
  return { v = -1, n = rnd(), text = "bad-" .. rnd(), nested = { flag = false } }
end

local function accept(name, fn, value)
  local ok, result = pcall(fn, value)
  D.check(checks, name, ok and not result, ok and tostring(result) or result)
end

local validators = {
  { "craft", function(v) return Craft.valid(v) == true end },
  { "wizard", function(v) return Wizard.valid(v) == true end },
  { "wizard class", function(v) return Wizard.validClass(v) == true end },
  { "fleet", function(v) return Fleet.valid(v) == true end },
  { "layout", function(v) return Layout.valid(v) == true end },
  { "policy", function(v) local parsed = Ledger.parsePolicy(v) return parsed ~= nil end },
  { "section", function(v) local parsed = Ledger.parseSection(v) return parsed ~= nil end },
  { "pose", function(v) return Ssot.pose(v) == true end },
}

for n = 1, 40 do
  local value = junk()
  for _, row in ipairs(validators) do
    accept(row[1] .. " rejects sample " .. n, row[2], value)
  end
  accept("bounded rejects sample " .. n, function(v) return Ssot.bounded(v, 8) == true end, string.rep("x", 40))
end

D.check(checks, "craft accepts an empty record", Craft.valid(nil) == true, "nil craft")
D.check(checks, "wizard accepts an empty record", Wizard.valid(nil) == true, "nil wizard")
D.check(checks, "fleet accepts an empty record", Fleet.valid(nil) == true, "nil fleet")
D.check(checks, "layout accepts an empty record", Layout.valid(nil) == true, "nil layout")
local settings = { v = 1, revision = 0, global = {}, roles = {}, computers = {} }
local settingsOk = Fleet.validSettings(settings)
D.check(checks, "fleet accepts default settings", settingsOk == true, "default settings")
local badSettings, badWhy = pcall(Fleet.validSettings, { v = 9 })
D.check(checks, "fleet rejects a malformed settings record", badSettings and badWhy ~= true, tostring(badWhy))
local policy = Ledger.parsePolicy(Ledger.defaults())
D.check(checks, "ledger accepts the default policy", policy ~= nil and policy.controlReserve == 65536, "policy")
local section = Ledger.parseSection({
  v = 2, key = "map:1", rev = 1,
  hash = string.rep("ab", 32), bytes = 10, observedAt = 1,
})
D.check(checks, "ledger accepts one section", section ~= nil and section.key == "map:1", "section")
D.check(checks, "pose accepts one position", Ssot.pose({
  dim = "minecraft:overworld", x = 1, y = 65, z = 2, h = 0,
}) == true, "pose")
local handle = fs.open("fuzz-seed.txt", "w")
handle.write(tostring(seed))
handle.close()
D.finish(checks)
