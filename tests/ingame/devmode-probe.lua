local D = dofile("depth-result.lua")
local Fleet = dofile("wh2-fleet.lua")
local checks = {}

local function check(name, ok, err)
  D.check(checks, name, ok, err)
end

local function ctx(capacity)
  return {
    now = 10000, epoch = 1, diskCapacity = capacity,
    config = { enabled = true, operators = { ["4"] = true } },
  }
end

local state = {}
local function patch(scope, extra, unset)
  local revision = state.wh2 and state.wh2.fleet and state.wh2.fleet.settings.revision or 0
  local body = {
    scope = scope, role = extra.role, computerId = extra.computerId,
    baseRevision = revision, set = extra.set, unset = unset,
  }
  return Fleet.run(state, 4, { op = "wh2-settings", body = body }, ctx(8000000))
end

local global = patch("global", { set = { autoCharge = true } })
check("global auto-charge is stored", global.ok == true and global.effective.autoCharge == true, global.error)
local role = patch("role", { role = "miner", set = { autoCharge = false, autoDropoff = true } })
check("role override is stored", role.ok == true, role.error)
local computer = patch("computer", { computerId = 17, set = { autoDropoff = false } })
check("computer 17 uses the string key", computer.ok == true
  and state.wh2.fleet.settings.computers["17"] ~= nil
  and state.wh2.fleet.settings.computers[17] == nil, computer.error)
local effective = Fleet.effective(state.wh2.fleet.settings, 17, "miner")
check("computer beats role beats global", effective.autoCharge == false and effective.autoDropoff == false,
  "charge " .. tostring(effective.autoCharge) .. " dropoff " .. tostring(effective.autoDropoff))
local removed = patch("computer", { computerId = 17 }, { "autoDropoff" })
local after = Fleet.effective(state.wh2.fleet.settings, 17, "miner")
check("removing the override restores the role", removed.ok == true and after.autoDropoff == true, removed.error)
local handle = fs.open("devmode-settings.json", "w")
handle.write(textutils.serializeJSON({
  key = "17",
  autoCharge = after.autoCharge,
  autoDropoff = after.autoDropoff,
}))
handle.close()
D.finish(checks)
