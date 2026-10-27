local F = {}

F.defaults = {
  ["alarm"] = true,
  ["alternateAxisOrders"] = true,
  ["arFollowups"] = true,
  ["builderFuelTrips"] = true,
  ["builderMaterialOrders"] = true,
  ["builderSolid"] = true,
  ["displayAck"] = true,
  ["dropsSavedSetup"] = true,
  ["dropsTestQueue"] = true,
  ["enroll"] = true,
  ["jobPoseSetup"] = true,
  ["lumberScan"] = true,
  ["panelUpdates"] = true,
  ["pocketTone"] = true,
  ["protectedAreas"] = true,
  ["remoteDimensions"] = true,
  ["retireLegacyPair"] = false,
  ["roomSink"] = true,
  ["retryInput"] = true,
  ["setupMovement"] = true,
  ["shopSaved"] = true,
  ["soundQuiet"] = false,
  ["state.coalesceHeartbeats"] = true,
  ["storageDeliveries"] = true,
  ["terminalRevoke"] = true,
  ["turtleInventory"] = true,
  ["workerPark"] = true,
  ["workerSettings"] = true,
  ["worldEdits"] = true,
}

function F.read(store)
  local path = "so-server.cfg"
  local exists = type(fs) == "table" and type(fs.exists) == "function" and fs.exists
  if exists and not exists(path) and exists(path .. ".bak") then path = path .. ".bak" end
  local ok, value = pcall(function()
    if store and type(store.read) == "function" then return store.read(path) end
  end)
  if ok and type(value) == "table" then return value end
  if not ok or value ~= nil or exists and exists(path) then
    local disabled = {state={coalesceHeartbeats=false}}
    for name in pairs(F.defaults) do
      if not name:find("%.") then disabled[name] = false end
    end
    return disabled, "so-server.cfg unreadable; flags disabled"
  end
end

function F.get(config, name)
  assert(F.defaults[name] ~= nil, "unknown feature flag: " .. tostring(name))
  local value = config
  for key in name:gmatch("[^.]+") do
    if value == nil then break end
    if type(value) ~= "table" then return false end
    value = value[key]
  end
  if value == nil then return F.defaults[name] end
  return value
end

function F.enabled(config, name)
  return F.get(config, name) == true
end

return F
