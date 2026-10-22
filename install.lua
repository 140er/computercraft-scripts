local ROLES = {
  common = {
    "install.lua", "update.lua", "so-proto.lua", "so-pair.lua", "so-store.lua",
    "lib/ccryptolib/random.lua", "lib/ccryptolib/config.lua",
    "lib/ccryptolib/chacha20.lua", "lib/ccryptolib/blake3.lua",
    "lib/ccryptolib/x25519.lua", "lib/ccryptolib/internal/packing.lua",
    "lib/ccryptolib/internal/util.lua", "lib/ccryptolib/internal/hw.lua",
    "lib/ccryptolib/internal/edwards25519.lua",
    "lib/ccryptolib/internal/curve25519.lua", "lib/ccryptolib/internal/fp.lua",
    "lib/ccryptolib/LICENSE",
  },
  worker = { program = "worker.lua", "worker.lua" },
  display = { program = "display.lua", "display.lua" },
  server = { program = "so-server.lua",
    "so-server.lua", "so-log.lua", "so-plan.lua", "so-mine-plan.lua",
    "so-lumber-plan.lua", "so-ui.lua", "so-mod-ar.lua", "so-mod-cells.lua", "so-mod-display.lua",
    "so-mod-daily.lua", "so-mod-drops.lua", "so-mod-lease.lua", "so-mod-lumber.lua",
    "so-mod-mine.lua", "so-mod-panel.lua", "so-mod-shop.lua", "so-mod-state.lua",
  },
}
local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/server-only/"
local NEW, OLD = "/.so-new", "/.so-old"
local function readFile(path)
  local h = assert(fs.open(path, "r"), "Cannot read " .. path)
  local value = h.readAll()
  h.close()
  return value
end
local function writeFile(path, value)
  fs.makeDir(fs.getDir(path))
  local h = assert(fs.open(path, "w"), "Cannot write " .. path)
  h.write(value)
  h.close()
end
local function move(from, to)
  fs.makeDir(fs.getDir(to))
  fs.move(from, to)
end
local function recover()
  if fs.exists(NEW .. "/committed") then
    fs.delete(OLD)
    fs.delete(NEW)
    return
  end
  if fs.exists(OLD .. "/manifest") then
    local entries = assert(textutils.unserialize(readFile(OLD .. "/manifest")), "Bad install manifest")
    for _, entry in ipairs(entries) do
      local path = entry.path
      if fs.exists(OLD .. "/" .. path) then
        fs.delete("/" .. path)
        move(OLD .. "/" .. path, "/" .. path)
      elseif not entry.existed then
        fs.delete("/" .. path)
      end
    end
  end
  fs.delete(OLD)
  fs.delete(NEW)
end
local function choose()
  if turtle then return "worker" end
  if pocket then return "display" end
  local monitor = peripheral.find("monitor")
  local out = monitor or term
  local options, selected = { "server", "display" }, monitor and 2 or 1
  while true do
    out.clear()
    out.setCursorPos(1, 1)
    out.write("Server-only role (arrows, Enter or touch)")
    for i, role in ipairs(options) do
      out.setCursorPos(1, i + 2)
      out.write((selected == i and "> " or "  ") .. role)
    end
    local ev, a, _, y = os.pullEvent()
    if ev == "key" then
      if a == keys.up or a == keys.down then selected = 3 - selected end
      if a == keys.enter then return options[selected] end
    elseif (ev == "mouse_click" and not monitor) or
      (ev == "monitor_touch" and monitor and a == peripheral.getName(monitor)) then
      if y == 3 or y == 4 then return options[y - 2] end
    end
  end
end
local function position()
  local x, y, z
  if gps and gps.locate then x, y, z = gps.locate(2) end
  while not (x and y and z) do
    print("Server position: x y z")
    local a, b, c = read():match("^%s*(%S+)%s+(%S+)%s+(%S+)%s*$")
    x, y, z = tonumber(a), tonumber(b), tonumber(c)
  end
  print("Dimension [minecraft:overworld]")
  local dim = read()
  if dim == "" then dim = "minecraft:overworld" end
  return textutils.serialize({ pos = { dim = dim, x = x, y = y, z = z } })
end
local function download(path)
  local response, err, failed = http.get(BASE .. path, nil, true)
  local h = response or failed
  if not h then error(path .. ": " .. tostring(err) .. " (not found may mean a private repository)", 0) end
  local code = h.getResponseCode()
  local bytes = h.readAll()
  h.close()
  if code ~= 200 or not bytes or #bytes == 0 then
    error(path .. ": HTTP " .. tostring(code) .. " (not found may mean a private repository)", 0)
  end
  if path:match("%.lua$") then
    local fn, why = load(bytes, "@" .. path, "t", _ENV)
    if not fn then error(path .. ": " .. tostring(why), 0) end
  end
  writeFile(NEW .. "/" .. path, bytes)
end
local function install(role, config)
  local entries = {}
  local function add(path)
    entries[#entries + 1] = { path = path, existed = fs.exists("/" .. path) }
  end
  local current = ""
  local ok, err = pcall(function()
    for _, group in ipairs({ ROLES.common, ROLES[role] }) do
      for _, path in ipairs(group) do
        current = path
        download(path)
        add(path)
      end
    end
    current = "startup.lua"
    writeFile(NEW .. "/startup.lua", 'if shell.run("/install.lua", "recover") then shell.run("/' ..
      ROLES[role].program .. '") end\n')
    add("startup.lua")
    current = ".so-role"
    writeFile(NEW .. "/.so-role", role)
    add(".so-role")
    if config then
      current = "so-server.cfg"
      writeFile(NEW .. "/so-server.cfg", config)
      add("so-server.cfg")
    end
  end)
  if not ok then
    fs.delete(NEW)
    print("Download failed: " .. current .. ": " .. tostring(err))
    return false
  end
  -- The complete manifest precedes every move, so rollback also removes new files.
  writeFile(NEW .. "/manifest", textutils.serialize(entries))
  move(NEW .. "/manifest", OLD .. "/manifest")
  ok, err = pcall(function()
    for _, entry in ipairs(entries) do
      local path = entry.path
      if entry.existed then move("/" .. path, OLD .. "/" .. path) end
      move(NEW .. "/" .. path, "/" .. path)
    end
    writeFile(NEW .. "/committed", "yes")
  end)
  if not ok then
    recover()
    print("Install rolled back: " .. tostring(err))
    return false
  end
  recover()
  return true
end
local function main(command)
  recover()
  if command == "recover" then return end
  if command == "reset" then
    print('Delete this machine\'s files? Type "yes" to confirm.')
    if read() ~= "yes" then return end
    local drive = fs.getDrive("/")
    for _, name in ipairs(fs.list("/")) do
      local path = "/" .. name
      if name ~= "rom" and name ~= "install.lua" and not fs.isReadOnly(path)
        and fs.getDrive(path) == drive then
        local ok, err = pcall(fs.delete, path)
        if not ok then print("Reset could not delete " .. path .. ": " .. tostring(err)) end
      end
    end
    return
  end
  if command and command ~= "update" then error("Use install, install update or install reset", 0) end
  local updating = command == "update"
  local role = updating and fs.exists("/.so-role") and readFile("/.so-role") or nil
  if updating and not ROLES[role] then error("Missing or invalid /.so-role; run install first", 0) end
  role = role or choose()
  if role == "common" or (turtle and role ~= "worker") or
    (pocket and role ~= "display") or (role == "worker" and not turtle) then
    error("Role does not match this machine", 0)
  end
  if role == "server" then
    local cap = fs.getCapacity("/")
    if type(cap) ~= "number" or cap < 16000000 then
      print("so-server: need 16000000 bytes, this disk has " .. tostring(cap) .. ".")
      print("Set computer_space_limit in computercraft-server.toml to at least 16000000, then restart the world.")
      return
    end
  end
  local config
  if role == "server" and not updating then config = position() end
  if not install(role, config) then return end
  print("Installed " .. role .. ". Use install update to update.")
  if not updating then
    if role ~= "server" then print("On the server press P, then type the 6-digit code here") end
    shell.run("/" .. ROLES[role].program)
  end
end
main(...)
