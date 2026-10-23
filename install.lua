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
    "so-server.lua", "so-errors.lua", "so-mod-health.lua", "so-log.lua", "so-plan.lua", "so-mine-plan.lua",
    "so-lumber-plan.lua", "so-ui.lua", "so-mod-ar.lua", "so-mod-cells.lua", "so-mod-display.lua",
    "so-mod-build.lua", "so-mod-daily.lua", "so-mod-drops.lua", "so-mod-lease.lua", "so-mod-lumber.lua",
    "so-mod-map.lua", "so-mod-mine.lua", "so-mod-panel.lua", "so-mod-shop.lua", "so-mod-state.lua",
  },
}
local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/"
local NEW, OLD, PREV = "/.so-new", "/.so-old", "/.so-prev"
local BOOT = "/startup/so-install-recover.lua"
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
    if fs.exists(NEW .. "/rollback") then
      fs.delete(PREV)
      fs.delete(OLD)
    elseif fs.exists(NEW .. "/keep") then
      if fs.exists(OLD) then
        fs.delete(PREV)
        move(OLD, PREV)
      end
    else fs.delete(OLD) end
    fs.delete(NEW)
    fs.delete(BOOT)
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
  fs.delete(BOOT)
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
  local function sane(x, y, z)
    return type(x) == "number" and type(y) == "number" and type(z) == "number"
      and x == x and y == y and z == z
      and math.abs(x) <= 30000000 and math.abs(z) <= 30000000
      and y >= -2048 and y <= 2048
      and x % 1 == 0 and y % 1 == 0 and z % 1 == 0
  end
  local dimensions = { [""] = "minecraft:overworld", ["0"] = "minecraft:overworld",
    ["-1"] = "minecraft:the_nether", ["1"] = "minecraft:the_end" }
  for _, dim in ipairs({ "minecraft:overworld", "minecraft:the_nether", "minecraft:the_end" }) do
    dimensions[dim] = dim
  end
  local x, y, z
  if gps and gps.locate then x, y, z = gps.locate(2) end
  while true do
    while not sane(x, y, z) do
      print("Server position: x y z")
      local a, b, c = read():match("^%s*(%S+)%s+(%S+)%s+(%S+)%s*$")
      x, y, z = tonumber(a), tonumber(b), tonumber(c)
    end
    local dim
    repeat
      print("0 minecraft:overworld")
      print("-1 minecraft:the_nether")
      print("1 minecraft:the_end")
      dim = dimensions[read():match("^%s*(.-)%s*$")]
      if not dim then print("Invalid dimension") end
    until dim
    print(x .. " " .. y .. " " .. z)
    print(dim)
    print("Save this? (Enter / n)")
    local answer = read()
    if answer == "" then
      return textutils.serialize({ pos = { dim = dim, x = x, y = y, z = z } })
    end
    x, y, z = nil, nil, nil
  end
end
local function fetch(url)
  local response, err, failed = http.get(url, nil, true)
  local h = response or failed
  if not h then error(tostring(err) .. " (not found may mean a private repository)", 0) end
  local code = h.getResponseCode()
  local bytes = h.readAll()
  h.close()
  if code ~= 200 or not bytes or #bytes == 0 then
    error("HTTP " .. tostring(code) .. " (not found may mean a private repository)", 0)
  end
  return bytes
end
local function validRevision(sha)
  return type(sha) == "string" and #sha == 40 and not sha:find("[^%x]")
end
local function gitRevision()
  local body = fetch("https://github.com/140er/computercraft-scripts.git/info/refs?service=git-upload-pack")
  local at = 1
  while at <= #body do
    local length = assert(tonumber(body:sub(at, at + 3), 16), "Bad Git ref packet")
    if length == 0 then at = at + 4
    else
      assert(length >= 4 and at + length - 1 <= #body, "Bad Git ref length")
      local sha = body:sub(at + 4, at + length - 1):match("^(%x+) refs/heads/server%-only[%z\n]")
      if validRevision(sha) then return sha end
      at = at + length
    end
  end
end
local function revision()
  local ok, sha = pcall(function()
    local body = fetch("https://api.github.com/repos/140er/computercraft-scripts/branches/server-only")
    local branch = textutils.unserializeJSON(body)
    return branch.commit.sha
  end)
  if ok and validRevision(sha) then return sha end
  ok, sha = pcall(gitRevision)
  if ok and validRevision(sha) then return sha end
  if fs.exists("/.so-revision") then
    sha = readFile("/.so-revision"):match("^%s*(.-)%s*$")
    if validRevision(sha) then
      print("Commit lookup unavailable. Using saved commit " .. sha)
      return sha
    end
  end
  error("Cannot resolve server-only commit and no valid saved commit exists", 0)
end
local function download(path, sha)
  local bytes = fetch(BASE .. sha .. "/" .. path)
  if path:match("%.lua$") then
    local fn, why = load(bytes, "@" .. path, "t", _ENV)
    if not fn then error(path .. ": " .. tostring(why), 0) end
  end
  writeFile(NEW .. "/" .. path, bytes)
end
local function validPath(path)
  if type(path) ~= "string" then return false end
  if not (path:match("^[%w_-]+%.lua$") or path:match("^lib/[%w_./-]+$")) then return false end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then return false end
  end
  return true
end
local function previousFiles(role)
  local paths = {}
  for _, group in ipairs({ ROLES.common, ROLES[role] }) do
    for _, path in ipairs(group) do paths[#paths + 1] = path end
  end
  if fs.exists("/.so-files") then
    local saved = assert(textutils.unserialize(readFile("/.so-files")), "Bad installed file list")
    assert(type(saved) == "table", "Bad installed file list")
    for _, path in ipairs(saved) do
      assert(validPath(path), "Bad installed file path")
      paths[#paths + 1] = path
    end
  end
  for _, name in ipairs(fs.list("/")) do
    if name:match("^so%-mod%-.*%.lua$") then paths[#paths + 1] = name end
  end
  return paths
end
local function swap(entries)
  -- CraftOS also runs /startup scripts when startup.lua or install.lua is between moves.
  assert(not fs.exists(BOOT), "Recovery startup already exists")
  writeFile(BOOT, 'for _, path in ipairs({"/install.lua", "/.so-old/install.lua", "/.so-new/install.lua"}) do\n' ..
    '  if fs.exists(path) then\n' ..
    '    if shell.run(path, "recover") then\n' ..
    '      fs.delete("' .. BOOT .. '")\n' ..
    '      shell.run("/startup.lua")\n' ..
    '    end\n' ..
    '    return\n' ..
    '  end\n' ..
    'end\n')
  -- Publish the complete manifest before changing any installed file.
  writeFile(NEW .. "/manifest", textutils.serialize(entries))
  move(NEW .. "/manifest", OLD .. "/manifest")
  local ok, err = pcall(function()
    for _, entry in ipairs(entries) do
      local path = entry.path
      if entry.existed then move("/" .. path, OLD .. "/" .. path) end
      if not entry.remove then move(NEW .. "/" .. path, "/" .. path) end
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
local function rollback()
  local function protocol(root)
    return fs.exists(root .. "/.so-protocol") and readFile(root .. "/.so-protocol") or "1"
  end
  assert(protocol(PREV) == protocol(""), "Previous release uses a different protocol")
  assert(fs.exists(PREV .. "/manifest"), "No previous release")
  local saved = assert(textutils.unserialize(readFile(PREV .. "/manifest")), "Bad previous manifest")
  local entries = {}
  local metadata = { ["startup.lua"] = true, [".so-role"] = true,
    [".so-files"] = true, [".so-revision"] = true, [".so-protocol"] = true }
  local ok, err = pcall(function()
    for _, entry in ipairs(saved) do
      local path = entry.path
      assert(validPath(path) or metadata[path], "Bad previous release path")
      entries[#entries + 1] = { path = path, existed = fs.exists("/" .. path), remove = not entry.existed }
      if entry.existed then writeFile(NEW .. "/" .. path, readFile(PREV .. "/" .. path)) end
    end
    writeFile(NEW .. "/rollback", "yes")
  end)
  if not ok then fs.delete(NEW); error(err, 0) end
  if swap(entries) then print("Restored previous release") end
end
local function install(role, config, handoff)
  local entries, wanted, files = {}, {}, {}
  local function add(path, remove)
    if wanted[path] then return end
    wanted[path] = true
    entries[#entries + 1] = { path = path, existed = fs.exists("/" .. path), remove = remove }
  end
  local current = ""
  local ok, err = pcall(function()
    for _, group in ipairs({ ROLES.common, ROLES[role] }) do
      for _, path in ipairs(group) do
        current = path
        if path ~= "install.lua" then download(path, handoff.revision) end
        files[#files + 1] = path
        add(path)
      end
    end
    writeFile(NEW .. "/.so-files", textutils.serialize(files))
    add(".so-files")
    writeFile(NEW .. "/.so-revision", handoff.revision)
    add(".so-revision")
    writeFile(NEW .. "/.so-protocol", "1")
    add(".so-protocol")
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
    for _, path in ipairs(handoff.previous) do
      assert(validPath(path), "Bad previous file path")
      if not wanted[path] then add(path, true) end
    end
  end)
  if not ok then
    fs.delete(NEW)
    print("Download failed: " .. current .. ": " .. tostring(err))
    return false
  end
  if handoff.updating then writeFile(NEW .. "/keep", "yes") end
  return swap(entries)
end
local function main(command, handoff)
  if type(handoff) ~= "table" then handoff = nil end
  if not handoff then recover()
  else
    assert(validRevision(handoff.revision) and type(handoff.previous) == "table", "Bad installer handoff")
  end
  if command == "recover" then return end
  if command == "rollback" then return rollback() end
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
  if command and command ~= "update" then error("Use install, install update, install rollback or install reset", 0) end
  local updating = command == "update"
  local role = updating and fs.exists("/.so-role") and readFile("/.so-role"):match("^%s*(.-)%s*$") or nil
  if updating and not ROLES[role] then error("Missing or invalid /.so-role; run install first", 0) end
  role = (handoff and handoff.role) or role or choose()
  if not ROLES[role] or role == "common" or (turtle and role ~= "worker") or
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
  local config = handoff and handoff.config
  if role == "server" and not updating and not handoff then config = position() end
  if not handoff then
    local ok, err = pcall(function()
      local sha = revision()
      local previous = previousFiles(role)
      download("install.lua", sha)
      local nextInstaller = assert(load(readFile(NEW .. "/install.lua"), "@install.lua", "t", _ENV))("prepare")
      assert(type(nextInstaller) == "function", "Commit installer does not support pinned updates")
      nextInstaller(command, { revision = sha, previous = previous, role = role, config = config, updating = updating })
    end)
    if not ok then
      if not fs.exists(OLD .. "/manifest") and not fs.exists(NEW .. "/committed") then fs.delete(NEW) end
      print("Install failed: " .. tostring(err))
    end
    return
  end
  handoff.updating = updating
  if not install(role, config, handoff) then return end
  print("Installed " .. role .. ". Use install update to update.")
  if not updating then
    if role ~= "server" then print("On the server press P, then type the 6-digit code here") end
    shell.run("/" .. ROLES[role].program)
  end
end
if ... == "prepare" then return main end
return main(...)
