local result = { ok = false, booted = true, errors = {}, lines = {}, rx = 0, httpOK = 0, httpAttempts = 0 }
local function fail(err) result.errors[#result.errors + 1] = tostring(err) end

if gps then
  gps.locate = function() fail("gps.locate was called") end
end

local function deep(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  local seen = {}
  for key, value in pairs(a) do
    seen[key] = true
    if not deep(value, b[key]) then return false end
  end
  for key in pairs(b) do if not seen[key] then return false end end
  return true
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS " .. name)
  else
    fail(name .. ": " .. tostring(err))
    print("FAIL " .. name)
  end
end

local function finish()
  result.free = fs.getFreeSpace("/")
  result.ok = #result.errors == 0
  if #result.lines == 0 then result.lines = textutils.empty_json_array end
  if #result.errors == 0 then result.errors = textutils.empty_json_array end
  local handle = fs.open("sandbox-result.tmp", "w")
  handle.write(textutils.serializeJSON(result))
  handle.close()
  if fs.exists("sandbox-result.json") then fs.delete("sandbox-result.json") end
  fs.move("sandbox-result.tmp", "sandbox-result.json")
  while true do os.pullEvent() end
end

local ok, err = pcall(function()
  assert(config.get("standardsMode") == true, "standardsMode disabled")
  assert(fs.getCapacity("/") == 1000000, "disk is " .. tostring(fs.getCapacity("/")))
  dofile("install-unit.lua")(test, function(actual, expected, message)
    assert(deep(actual, expected), message or "values differ")
  end)
  dofile("i2-touch.lua")(test, function(actual, expected, message)
    assert(deep(actual, expected), message or "values differ")
  end)
  if fs.exists("i2-touch.lua") then fs.delete("i2-touch.lua") end
  if fs.exists("i2-events") then fs.delete("i2-events") end
  local Roles = dofile("install-roles.lua")
  local function drive()
    return {
      exists = function(path) return fs.exists(path) end,
      isDir = function(path) return fs.isDir(path) end,
      list = function(path) return fs.list(path) end,
      open = function(path, mode) return fs.open(path, mode) end,
      delete = function(path)
        if fs.exists(path) and fs.getDrive(path) ~= "hdd" then return end
        fs.delete(path)
      end,
      move = function(from, to) fs.move(from, to) end,
      makeDir = function(path) fs.makeDir(path) end,
    }
  end
  local function readRom(name)
    local handle = fs.open("rom/bundle/" .. name, "r")
    if not handle then return nil end
    local text = handle.readAll()
    handle.close()
    return text
  end
  local function wipe()
    for _, name in ipairs(fs.list("/")) do
      if fs.getDrive(name) == "hdd" and not fs.isDir(name) then
        local kit = name == "install.lua" or name == "update.lua" or name == "install-roles.lua"
          or name == "install-core.lua" or name == "install-keys.lua" or name == "install-shell.lua"
          or name == "install-touch.lua"
          or name == "enrol.lua" or name == "install-unit.lua" or name == "install-driver.lua"
          or name == "startup.lua"
        if not kit then fs.delete(name) end
      end
    end
  end
  for _, role in ipairs(Roles.list()) do
    wipe()
    sleep(0)
    local bodies = {}
    for _, name in ipairs(Roles.files(role.id)) do
      bodies[name] = assert(readRom(name), role.id .. " bundle missing " .. name)
    end
    local installed, why = Roles.apply(drive(), "", role.id, bodies, fs.getFreeSpace("/"))
    assert(installed, role.id .. " fresh " .. tostring(why))
    for _, name in ipairs(role.files) do
      assert(fs.exists(name), role.id .. " did not write " .. name)
    end
    local first = role.files[1]
    local stale = fs.open(first, "w")
    stale.write("-- stale\n")
    stale.close()
    local junk = fs.open("junk.lua", "w")
    junk.write("junk\n")
    junk.close()
    local keep = fs.open("keep.cfg", "w")
    keep.write("keep\n")
    keep.close()
    local upgraded, upgradeErr = Roles.apply(drive(), "", role.id, bodies, fs.getFreeSpace("/"))
    assert(upgraded, role.id .. " upgrade " .. tostring(upgradeErr))
    local restored = fs.open(first, "r")
    local body = restored.readAll()
    restored.close()
    assert(body == bodies[first], role.id .. " upgrade did not restore " .. first)
    assert(not fs.exists("junk.lua"), role.id .. " left junk.lua")
    assert(fs.exists("keep.cfg"), role.id .. " removed keep.cfg")
    local quiet, quietErr = Roles.apply(drive(), "", role.id, bodies, fs.getFreeSpace("/"))
    assert(quiet, role.id .. " reinstall " .. tostring(quietErr))
    assert(#quiet.wrote == 0, role.id .. " reinstall wrote " .. #quiet.wrote)
    result.lines[#result.lines + 1] = role.id
  end
end)
if not ok then fail(err) end
finish()
