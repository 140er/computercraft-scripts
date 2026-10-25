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
local CACHE = "/.so-download"
local BOOT = "/startup/so-install-recover.lua"
local RECOVERY = 'for _, path in ipairs({"/install.lua", "/.so-old/install.lua", "/.so-new/install.lua"}) do\n' ..
    '  if fs.exists(path) then\n' ..
    '    if shell.run(path, "recover") then\n' ..
    '      fs.delete("' .. BOOT .. '")\n' ..
    '      shell.run("/startup.lua")\n' ..
    '    end\n' ..
    '    return\n' ..
    '  end\n' ..
    'end\n'
local function readFile(path)
  local h = assert(fs.open(path, "r"), "Cannot read " .. path)
  local value = h.readAll()
  h.close()
  return value
end
local function writeFile(path, value)
  if fs.getFreeSpace then
    local free = fs.getFreeSpace(path)
    assert(free == "unlimited" or free >= #value + 512, "Disk space changed before writing " .. path)
  end
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
-- Two stacked buttons centred on the screen. Each button's box is both what
-- gets drawn and what accepts a touch.
local function roleButtons(out)
  local w, h = out.getSize()
  local tall = h >= 7 and 3 or 1
  local top = math.floor((h - 2 * tall - 1) / 2) + 1
  local list = {}
  for i, role in ipairs({ "server", "display" }) do
    local y1 = top + (i - 1) * (tall + 1)
    list[i] = { role = role, x1 = 2, x2 = w - 1, y1 = y1, y2 = y1 + tall - 1 }
  end
  return list
end
local function drawRoleButtons(out, list, selected)
  out.setBackgroundColor(colors.black)
  out.clear()
  for i, b in ipairs(list) do
    local on, width = i == selected, b.x2 - b.x1 + 1
    local label = b.role:upper()
    if on and #label + 4 <= width then label = "> " .. label .. " <" end
    out.setBackgroundColor(on and colors.white or colors.gray)
    out.setTextColor(on and colors.black or colors.white)
    for y = b.y1, b.y2 do
      local text = y == math.floor((b.y1 + b.y2) / 2) and label or ""
      local left = math.floor((width - #text) / 2)
      out.setCursorPos(b.x1, y)
      out.write((string.rep(" ", left) .. text .. string.rep(" ", width)):sub(1, width))
    end
  end
end
local function choose()
  if turtle then return "worker" end
  if pocket then return "display" end
  local monitor = peripheral.find("monitor")
  local out = monitor or term
  local list, selected = roleButtons(out), monitor and 2 or 1
  -- Reset the screen even when the picker is terminated or fails, then pass the error on.
  local ok, role = pcall(function()
    while true do
      drawRoleButtons(out, list, selected)
      local ev, a, x, y = os.pullEvent()
      if ev == "key" then
        if a == keys.up or a == keys.down then selected = 3 - selected end
        if a == keys.enter then return list[selected].role end
      elseif (ev == "mouse_click" and not monitor) or
        (ev == "monitor_touch" and monitor and a == peripheral.getName(monitor)) then
        for _, b in ipairs(list) do
          if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b.role end
        end
      end
    end
  end)
  out.setBackgroundColor(colors.black)
  out.setTextColor(colors.white)
  out.clear()
  out.setCursorPos(1, 1)
  if not ok then error(role, 0) end
  return role
end
local function position()
  local config = {}
  if fs.exists("/so-server.cfg") then
    config = textutils.unserialize(readFile("/so-server.cfg"))
    assert(type(config) == "table", "Bad so-server.cfg; refusing to replace saved settings")
  end
  local function sane(x, y, z)
    return type(x) == "number" and type(y) == "number" and type(z) == "number"
      and x == x and y == y and z == z
      and math.abs(x) <= 30000000 and math.abs(z) <= 30000000
      and y >= -2048 and y <= 2048
      and x % 1 == 0 and y % 1 == 0 and z % 1 == 0
  end
  local dimensions = { [""] = "minecraft:overworld", ["0"] = "minecraft:overworld",
    ["-1"] = "minecraft:the_nether", ["1"] = "minecraft:the_end",
    overworld="minecraft:overworld", nether="minecraft:the_nether", the_nether="minecraft:the_nether",
    ["end"]="minecraft:the_end", the_end="minecraft:the_end" }
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
      config.pos = { dim = dim, x = x, y = y, z = z }
      return textutils.serialize(config)
    end
    x, y, z = nil, nil, nil
  end
end
local function fetch(url)
  local response, err, failed = http.get(url, nil, true)
  local h = response or failed
  if not h then error(tostring(err) .. " (not found may mean a private repository)", 0) end
  local ok, code, bytes = pcall(function() return h.getResponseCode(), h.readAll() end)
  h.close()
  if not ok then error(code, 0) end
  if code ~= 200 or not bytes or #bytes == 0 then
    error("HTTP " .. tostring(code) .. " (not found may mean a private repository)", 0)
  end
  return bytes
end
local function validRevision(sha)
  return type(sha) == "string" and #sha == 40 and not sha:find("[^%x]")
end
local function installedRevision()
  local sha = fs.exists("/.so-revision") and readFile("/.so-revision"):match("^%s*(.-)%s*$")
  return validRevision(sha) and sha:sub(1, 7) or "unknown"
end
local function startUpdated(previous)
  local role = readFile("/.so-role"):match("^%s*(.-)%s*$")
  print("Updated " .. role .. " from " .. previous .. " to " .. installedRevision())
  shell.run("/" .. ROLES[role].program)
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
local function revision(allowSaved)
  local ok, sha = pcall(function()
    local body = fetch("https://api.github.com/repos/140er/computercraft-scripts/branches/server-only")
    local branch = textutils.unserializeJSON(body)
    return branch.commit.sha
  end)
  if ok and validRevision(sha) then return sha end
  ok, sha = pcall(gitRevision)
  if ok and validRevision(sha) then return sha end
  if allowSaved ~= false and fs.exists("/.so-revision") then
    sha = readFile("/.so-revision"):match("^%s*(.-)%s*$")
    if validRevision(sha) then
      print("Commit lookup unavailable. Using saved commit " .. sha)
      return sha
    end
  end
  error("Cannot resolve server-only commit" .. (allowSaved == false and "" or " and no valid saved commit exists"), 0)
end

local yieldEvent = "so-install-yield-" .. tostring({})
local function yieldWork()
  local pending = {}
  os.queueEvent(yieldEvent)
  while true do
    local event = table.pack(os.pullEvent())
    if event[1] == yieldEvent then break end
    pending[#pending+1] = event
  end
  -- Filtered pulls discard other events, so put them back for the role or caller.
  for _,event in ipairs(pending) do os.queueEvent(table.unpack(event,1,event.n)) end
end
local function digest(msg, git)
  local K
  if not git then
    K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  }
  end
  local h = git and {0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0}
    or {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
  local b, mask = bit32, 0xffffffff
  local bits = #msg * 8
  msg = msg .. string.char(128) .. string.rep("\0", (55 - #msg) % 64) .. string.char(0,0,0,0,
    b.band(b.rshift(bits,24),255),b.band(b.rshift(bits,16),255),b.band(b.rshift(bits,8),255),b.band(bits,255))
  for block = 1, #msg, 64 do
    local w = {}
    for t = 0, 15 do
      local a,c,d,e = msg:byte(block+t*4,block+t*4+3)
      w[t] = b.bor(b.lshift(a,24),b.lshift(c,16),b.lshift(d,8),e)
    end
    for t = 16, git and 79 or 63 do
      if git then w[t] = b.lrotate(b.bxor(w[t-3],w[t-8],w[t-14],w[t-16]),1)
      else
        local x,y = w[t-15],w[t-2]
        w[t] = b.band(w[t-16]+b.bxor(b.rrotate(x,7),b.rrotate(x,18),b.rshift(x,3))+w[t-7]+
          b.bxor(b.rrotate(y,17),b.rrotate(y,19),b.rshift(y,10)),mask)
      end
    end
    local a,c,d,e,f,g,j,l = table.unpack(h)
    for t = 0, git and 79 or 63 do
      if git then
        local v, constant
        if t < 20 then v,constant = b.bor(b.band(c,d),b.band(b.bnot(c),e)),0x5a827999
        elseif t < 40 then v,constant = b.bxor(c,d,e),0x6ed9eba1
        elseif t < 60 then v,constant = b.bor(b.band(c,d),b.band(c,e),b.band(d,e)),0x8f1bbcdc
        else v,constant = b.bxor(c,d,e),0xca62c1d6 end
        a,c,d,e,f = b.band(b.lrotate(a,5)+v+f+constant+w[t],mask),a,b.lrotate(c,30),d,e
      else
        local t1 = b.band(l+b.bxor(b.rrotate(f,6),b.rrotate(f,11),b.rrotate(f,25))+
          b.bxor(b.band(f,g),b.band(b.bnot(f),j))+K[t+1]+w[t],mask)
        local t2 = b.band(b.bxor(b.rrotate(a,2),b.rrotate(a,13),b.rrotate(a,22))+
          b.bxor(b.band(a,c),b.band(a,d),b.band(c,d)),mask)
        a,c,d,e,f,g,j,l = b.band(t1+t2,mask),a,c,d,b.band(e+t1,mask),f,g,j
      end
    end
    local state = git and {a,c,d,e,f} or {a,c,d,e,f,g,j,l}
    for i,v in ipairs(state) do h[i] = b.band(h[i]+v,mask) end
    if (block+63) % 8192 == 0 then yieldWork() end
  end
  local out = {}
  for i,v in ipairs(h) do out[i] = string.format("%08x",v) end
  yieldWork()
  return table.concat(out)
end
local function validPath(path)
  if type(path) ~= "string" or path:find("//",1,true) or path:sub(-1) == "/" then return false end
  if not (path:match("^[%w_-]+%.lua$") or path:match("^lib/[%w_./-]+$")) then return false end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then return false end
  end
  return true
end
local function roleFiles(role, roles)
  roles = roles or ROLES
  assert(role ~= "common" and roles[role], "Unknown kit role")
  local paths, seen = {}, {}
  for _,group in ipairs({roles.common,roles[role]}) do
    for _,path in ipairs(group) do
      assert(validPath(path) and not seen[path], "Invalid or duplicate role path")
      seen[path],paths[#paths+1] = true,path
    end
  end
  assert(seen[roles[role].program] and validPath(roles[role].program), "Missing role program")
  return paths
end
local function compile(path, bytes)
  if path:match("%.lua$") then return assert(load(bytes,"@" .. path,"t",_ENV)) end
end
local function metadata(sha)
  local tree = textutils.unserializeJSON(fetch("https://api.github.com/repos/140er/computercraft-scripts/git/trees/" .. sha .. "?recursive=1"))
  assert(type(tree) == "table" and not tree.truncated and type(tree.tree) == "table", "Missing commit size metadata")
  local list, seen = {}, {}
  for _,v in ipairs(tree.tree) do
    if v.type ~= "tree" and validPath(v.path) then
      assert(v.type == "blob" and v.mode ~= "120000" and validRevision(v.sha) and
        type(v.size) == "number" and v.size >= 0 and v.size % 1 == 0 and not seen[v.path], "Bad commit metadata")
      seen[v.path] = true
      list[#list+1] = {path=v.path,bytes=v.size,blob=v.sha:lower()}
    end
  end
  table.sort(list,function(a,b) return a.path < b.path end)
  assert(seen["install.lua"], "Missing installer metadata")
  return list
end
local function selectFiles(list, role, roles, exact)
  local byPath, selected = {}, {}
  for _,v in ipairs(list) do byPath[v.path] = v end
  for _,path in ipairs(roleFiles(role,roles)) do
    selected[#selected+1] = assert(byPath[path], "Missing metadata or kit file " .. path)
  end
  assert(not exact or #selected == #list, "Kit must contain exactly the selected role")
  return selected
end
local function verified(v, bytes)
  assert(#bytes == v.bytes, "Size mismatch " .. v.path)
  if v.sha256 then assert(digest(bytes) == v.sha256, "Digest mismatch " .. v.path) end
  if v.blob then assert(digest("blob " .. #bytes .. "\0" .. bytes,true) == v.blob, "Blob mismatch " .. v.path) end
  compile(v.path,bytes)
  yieldWork()
  return bytes
end
local function cacheIndex(sha, role, list)
  local metadata = {}
  for _,v in ipairs(list) do metadata[#metadata+1] = v.path .. "\0" .. v.bytes .. "\0" .. v.blob .. "\n" end
  return {version=1,commit=sha,role=role,manifestDigest=digest(table.concat(metadata)),files={}}
end
local function readCacheIndex()
  local path = fs.exists(CACHE .. "/index") and CACHE .. "/index" or CACHE .. "/index.bak"
  assert(fs.exists(path), "No resumable download")
  return textutils.unserialize(readFile(path))
end
local function cached(index, list, resume)
  local bytes,byPath = {},{}
  if not resume then return bytes end
  local saved = readCacheIndex()
  assert(type(saved) == "table" and saved.version == 1 and saved.commit == index.commit and
    saved.role == index.role and saved.manifestDigest == index.manifestDigest and type(saved.files) == "table",
    "Cache belongs to another revision or manifest; retry without --resume")
  for _,v in ipairs(list) do byPath[v.path] = v end
  for _,v in ipairs(saved.files) do
    local expected = byPath[v.path]
    assert(expected and not bytes[v.path] and v.blob == expected.blob and type(v.sha256) == "string", "Bad cache index")
    local value = verified(expected,readFile(CACHE .. "/code/" .. v.path))
    assert(#value == v.bytes and digest(value) == v.sha256, "Corrupt cached file " .. v.path)
    bytes[v.path] = value
    index.files[#index.files+1] = {path=v.path,bytes=#value,sha256=v.sha256,blob=expected.blob}
  end
  return bytes
end
local function admission(list, cachedBytes, generated, entries, index)
  local S,L,N = 0,0,0
  local paths = {}
  for _,path in ipairs({NEW,OLD,PREV,CACHE,BOOT}) do
    assert(fs.getDrive(path) == fs.getDrive("/"), "Installer state crosses a mount")
  end
  local function count(path)
    while path ~= "" and path ~= "/" do
      if not paths[path] and not fs.exists(path) then N = N+1; paths[path] = true end
      path = fs.getDir(path)
    end
  end
  for _,v in ipairs(list) do
    S = S+v.bytes
    if not cachedBytes[v.path] then L = math.max(L,v.bytes) end
    count((CACHE .. "/code") .. "/" .. v.path)
    count(NEW .. "/" .. v.path)
    count(OLD .. "/" .. v.path)
    count(CACHE .. "/file.tmp")
  end
  for _,entry in ipairs(entries) do if entry.existed then count(OLD .. "/" .. entry.path) end end
  local C,G = 0,0
  for _,v in ipairs(list) do if cachedBytes[v.path] then C = C+#cachedBytes[v.path] end end
  for path,value in pairs(generated) do G = G+#value; count(NEW .. "/" .. path) end
  local complete = {version=1,commit=index.commit,role=index.role,manifestDigest=index.manifestDigest,files={}}
  for _,v in ipairs(list) do complete.files[#complete.files+1] = {path=v.path,bytes=v.bytes,sha256=string.rep("f",64),blob=v.blob} end
  local M = 3*math.max(#textutils.serialize(complete),#textutils.serialize(index))+2*#textutils.serialize(entries)+#RECOVERY+9
  for _,path in ipairs({CACHE .. "/index.tmp",CACHE .. "/index.bak",CACHE .. "/index",NEW .. "/manifest",NEW .. "/committed",NEW .. "/keep",NEW .. "/rollback",BOOT}) do count(path) end
  local required = 2*S-C+L+G+M+4096+512*N
  local free = fs.getFreeSpace("/")
  print("Space required " .. required .. " bytes; free " .. tostring(free) .. " bytes")
  assert(free == "unlimited" or (type(free) == "number" and free >= required), "Not enough free space; installed files unchanged")
end
local function obtain(v, sha, index, bytes)
  if bytes[v.path] then return bytes[v.path] end
  print(v.path)
  local ok,value
  for attempt = 1,3 do
    ok,value = pcall(fetch,BASE .. sha .. "/" .. v.path)
    if ok then break end
    if attempt < 3 then print("Retrying " .. v.path .. " (" .. (attempt+1) .. "/3)") end
  end
  if not ok then error(value,0) end
  verified(v,value)
  writeFile(CACHE .. "/file.tmp",value)
  local dest = CACHE .. "/code/" .. v.path
  if fs.exists(dest) then fs.delete(dest) end
  move(CACHE .. "/file.tmp",dest)
  index.files[#index.files+1] = {path=v.path,bytes=#value,sha256=digest(value),blob=v.blob}
  writeFile(CACHE .. "/index.tmp",textutils.serialize(index))
  if fs.exists(CACHE .. "/index") then
    fs.delete(CACHE .. "/index.bak")
    move(CACHE .. "/index",CACHE .. "/index.bak")
  end
  move(CACHE .. "/index.tmp",CACHE .. "/index")
  fs.delete(CACHE .. "/index.bak")
  bytes[v.path] = value
  return value
end
local function installerRoles(bytes)
  local prefix = assert(bytes:match("^(local ROLES%s*=%s*{.-)local BASE ="), "Missing pinned ROLES")
  local roles = assert(load(prefix .. "return ROLES","@pinned-roles","t",{}))()
  assert(type(roles) == "table" and type(roles.common) == "table", "Bad pinned ROLES")
  return roles
end
local function prepareInstaller(bytes)
  local apply,roles = compile("install.lua",bytes)("prepare")
  assert(type(apply) == "function" and type(roles) == "table",
    "pinned installer too old for staged update/offline kit; update from a newer commit")
  return apply
end
local function readKit(mount)
  assert(type(mount) == "string" and mount:match("^/?[%w_-]+$") and fs.getDrive(mount) ~= fs.getDrive("/"), "Expected a mounted kit disk")
  local root = mount .. "/so-kit"
  local kit = textutils.unserialize(readFile(root .. "/manifest"))
  assert(type(kit) == "table" and kit.version == 1 and validRevision(kit.commit) and
    ROLES[kit.role] and kit.role ~= "common" and type(kit.files) == "table", "Bad kit manifest")
  local bytes,seen = {},{}
  for _,v in ipairs(kit.files) do
    assert(type(v) == "table" and validPath(v.path) and not seen[v.path] and
      type(v.bytes) == "number" and v.bytes >= 0 and v.bytes % 1 == 0 and
      validRevision(v.blob) and v.blob == v.blob:lower() and
      type(v.sha256) == "string" and #v.sha256 == 64 and not v.sha256:find("[^0-9a-f]"), "Bad kit entry")
    assert(fs.getDrive(root .. "/code/" .. v.path) == fs.getDrive(mount), "Kit crosses a mount")
    seen[v.path] = true
    bytes[v.path] = verified(v,readFile(root .. "/code/" .. v.path))
  end
  local chunk = assert(bytes["install.lua"], "Missing kit installer")
  local roles = installerRoles(chunk)
  selectFiles(kit.files,kit.role,roles,true)
  local apply = prepareInstaller(chunk)
  return kit,bytes,apply
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
  writeFile(BOOT, RECOVERY)
  -- Publish the complete manifest before changing any installed file.
  writeFile(NEW .. "/manifest", textutils.serialize(entries))
  move(NEW .. "/manifest", OLD .. "/manifest")
  local ok, err = pcall(function()
    assert(fs.getFreeSpace("/") == "unlimited" or fs.getFreeSpace("/") >= 4096, "Not enough space for swap markers")
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
  local sizes,generated = {},{}
  for _,entry in ipairs(saved) do
    assert(validPath(entry.path) or metadata[entry.path], "Bad previous release path")
    if entry.existed then sizes[#sizes+1] = {path=entry.path,bytes=#readFile(PREV .. "/" .. entry.path)} end
  end
  admission(sizes,{},generated,saved,{commit="rollback",role="rollback",manifestDigest=""})
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
  -- An older worker never reads or deletes the enroll token and secret.
  fs.delete("/so-enroll")
  return swap(entries)
end
local function installPlan(role, config, manifest, previous, sha, roles)
  local entries, wanted, generated = {},{},{}
  local list = selectFiles(manifest,role,roles)
  local files = roleFiles(role,roles)
  roles = roles or ROLES
  local function add(path, remove)
    if wanted[path] then return end
    wanted[path] = true
    entries[#entries+1] = {path=path,existed=fs.exists("/" .. path),remove=remove}
  end
  for _,path in ipairs(files) do
    assert(fs.getDrive("/" .. path) == fs.getDrive("/"), "Install path crosses a mount")
    add(path)
  end
  generated[".so-files"] = textutils.serialize(files)
  generated[".so-revision"] = sha
  generated[".so-protocol"] = "1"
  generated["startup.lua"] = 'if shell.run("/install.lua", "recover") then shell.run("/' .. roles[role].program .. '") end\n'
  generated[".so-role"] = role
  if config then generated["so-server.cfg"] = config end
  for path in pairs(generated) do add(path) end
  for _,path in ipairs(previous) do
    assert(validPath(path), "Bad previous file path")
    if not wanted[path] then add(path,true) end
  end
  return list,generated,entries
end
local function install(role, config, handoff)
  local list,generated,entries = installPlan(role,config,handoff.manifest,handoff.previous,handoff.revision)
  local ok,err = pcall(function()
    admission(list,handoff.bytes,generated,entries,handoff.index)
    for _,v in ipairs(list) do
      local value = handoff.offline and assert(handoff.bytes[v.path])
        or obtain(v,handoff.revision,handoff.index,handoff.bytes)
      writeFile(NEW .. "/" .. v.path,value)
      yieldWork()
    end
    for path,value in pairs(generated) do writeFile(NEW .. "/" .. path,value) end
    if handoff.updating then writeFile(NEW .. "/keep","yes") end
  end)
  if not ok then
    fs.delete(NEW)
    print("Download failed: " .. tostring(err))
    return false
  end
  if not swap(entries) then return false end
  if not handoff.offline then fs.delete(CACHE) end
  return true
end
local function exportKit(mount,role,sha)
  assert(validRevision(sha), "Expected a full 40-character commit SHA")
  assert(type(mount) == "string" and mount:match("^/?[%w_-]+$") and fs.getDrive(mount) ~= fs.getDrive("/"), "Expected a mounted kit disk")
  local root = mount .. "/so-kit"
  assert(not fs.exists(root), "Kit directory already exists")
  local list = metadata(sha)
  local installer
  for _,v in ipairs(list) do
    if v.path == "install.lua" then
      installer = verified(v,fetch(BASE .. sha .. "/install.lua"))
    end
  end
  local roles = installerRoles(installer)
  local selected = selectFiles(list,role,roles)
  local kit,bytes = {version=1,commit=sha,role=role,files={}},{}
  for _,v in ipairs(selected) do
    kit.files[#kit.files+1] = {path=v.path,bytes=v.bytes,sha256=string.rep("f",64),blob=v.blob}
  end
  local required = #textutils.serialize(kit)+512
  local dirs = {}
  for _,v in ipairs(kit.files) do
    required = required+math.max(512,v.bytes)
    local path = fs.getDir(root .. "/code/" .. v.path)
    while path ~= mount and path ~= "" and path ~= "/" do
      if not dirs[path] then dirs[path] = true; required = required+512 end
      path = fs.getDir(path)
    end
  end
  local free = fs.getFreeSpace(mount)
  assert(free == "unlimited" or free >= required, "Kit does not fit this disk")
  for i,v in ipairs(selected) do
    local value = v.path == "install.lua" and installer or verified(v,fetch(BASE .. sha .. "/" .. v.path))
    bytes[v.path] = value
    kit.files[i].sha256 = digest(value)
  end
  for _,v in ipairs(kit.files) do writeFile(root .. "/code/" .. v.path,bytes[v.path]) end
  writeFile(root .. "/manifest",textutils.serialize(kit))
  print("Kit " .. role .. " " .. sha)
end
-- An enroll token S-XXXX-XXXX-XXXX-XXXX, normalised, or nil.
local function enrollToken(text)
  if type(text) ~= "string" then return nil end
  text = text:upper():gsub("%s", "")
  local id, rest = text:match("^(%d+)%-([%w%-]+)$")
  if not id or #id > 10 then return nil end
  rest = rest:gsub("%-", "")
  if #rest ~= 16 or rest:find("[^ABCDEFGHJKLMNPQRSTUVWXYZ23456789]") then return nil end
  return id .. "-" .. rest:sub(1, 4) .. "-" .. rest:sub(5, 8) .. "-" .. rest:sub(9, 12) .. "-" .. rest:sub(13, 16)
end
local function main(command, handoff, extra, last)
  if command == "kit" then return exportKit(handoff,extra,last) end
  local kit,kitBytes,kitApply
  if command == "offline" then
    assert(extra == nil and last == nil, "Use install offline <mount>")
    kit,kitBytes,kitApply = readKit(handoff)
    recover()
    command,handoff = fs.exists("/.so-role") and "update" or nil,nil
    if command == "update" then assert(readFile("/.so-role"):match("^%s*(.-)%s*$") == kit.role, "Kit role differs from installed role") end
  end
  local resume = extra == "--resume" or handoff == "--resume"
  if extra ~= nil then assert(extra == "--resume", "Expected --resume") end
  if handoff == "--resume" then handoff = nil end
  local requestedRevision
  if type(handoff) ~= "table" then
    requestedRevision, handoff = handoff, nil
    if validRevision(command) then
      assert(requestedRevision == nil, "Supply only one commit SHA")
      requestedRevision, command = command, nil
    end
    assert(requestedRevision == nil or ((command == nil or command == "update") and validRevision(requestedRevision)),
      "Expected a full 40-character commit SHA")
    assert(command == nil or command == "update" or command == "rollback" or command == "reset"
      or command == "recover" or command == "check" or enrollToken(command),
      "Use install [sha], install update [sha] [--resume], install offline <mount>, install kit <mount> <role> <sha>, install check, install rollback or install reset")
    if command == "check" then
      local sha = revision(false)
      local saved = fs.exists("/.so-revision") and readFile("/.so-revision"):match("^%s*(.-)%s*$")
      if saved == sha then print("Current " .. sha)
      else print("Update available: " .. installedRevision() .. " to " .. sha) end
      return
    end
  end
  if handoff then
    assert(validRevision(handoff.revision) and type(handoff.previous) == "table", "Bad installer handoff")
  elseif not kit then recover() end
  local enroll = handoff and enrollToken(handoff.enroll)
  if not handoff and enrollToken(command) then enroll, command = enrollToken(command), nil end
  if command == "recover" then return end
  local previous = (command == "update" or command == "rollback") and installedRevision()
  if command == "rollback" then
    if rollback() then startUpdated(previous) end
    return
  end
  if command == "reset" then
    local count = 0
    for _, path in ipairs({ "/so-keys", "/so-keys.bak" }) do
      local ok, saved = pcall(function() return textutils.unserialize(readFile(path)) end)
      if ok and type(saved) == "table" and type(saved.value) == "table"
        and type(saved.value.keys) == "table" then
        for _ in pairs(saved.value.keys) do count = count + 1 end
        break
      end
    end
    print('Delete this machine\'s files and ' .. count .. ' paired keys? Type "yes" to confirm.')
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
  role = (kit and kit.role) or (handoff and handoff.role) or role or choose()
  if not ROLES[role] or role == "common" or (turtle and role ~= "worker") or
    (pocket and role ~= "display") or (role == "worker" and not turtle) then
    error("Role does not match this machine", 0)
  end
  if enroll and role ~= "worker" then error("Enroll tokens are for turtles", 0) end
  if enroll and (fs.exists("/so-keys") or fs.exists("/so-keys.bak") or fs.exists("/so-keys.tmp")) then
    print("This turtle has paired keys. Run install reset first.")
    return
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
      local saved
      if resume then
        saved = readCacheIndex()
        assert(type(saved) == "table" and validRevision(saved.commit), "Bad cached revision")
        assert(not requestedRevision or requestedRevision == saved.commit, "Cache belongs to another revision")
        print("Resuming pinned commit " .. saved.commit)
      end
      local sha = kit and kit.commit or requestedRevision or (saved and saved.commit) or revision()
      local manifest = kit and kit.files or metadata(sha)
      local index = cacheIndex(sha,role,manifest)
      local bytes = kitBytes or cached(index,manifest,resume)
      local previousFilesList = previousFiles(role)
      local nextInstaller = kitApply
      if not kit then
        local installerEntry
        for _,v in ipairs(manifest) do if v.path == "install.lua" then installerEntry = v end end
        admission({assert(installerEntry)},bytes,{}, {},index)
        if not resume then
          fs.delete(CACHE)
          writeFile(CACHE .. "/index",textutils.serialize(index))
        end
        local installer = obtain(installerEntry,sha,index,bytes)
        local roles = installerRoles(installer)
        local list,generated,entries = installPlan(role,config,manifest,previousFilesList,sha,roles)
        admission(list,bytes,generated,entries,index)
        nextInstaller = prepareInstaller(installer)
      end
      assert(type(nextInstaller) == "function", "Commit installer does not support pinned updates")
      nextInstaller(command, { revision = sha, previous = previousFilesList, role = role, config = config, updating = updating,
        enroll = enroll, manifest=manifest,index=index,bytes=bytes,offline=kit ~= nil })
    end)
    if not ok then
      if not fs.exists(OLD .. "/manifest") and not fs.exists(NEW .. "/committed") then fs.delete(NEW) end
      print("Install failed: " .. tostring(err))
    end
    return
  end
  if not handoff.manifest and fs.exists(NEW .. "/install.lua") then
    -- Installers before B4-G stage the pinned bootstrap and pass only the original handoff.
    local manifest = metadata(handoff.revision)
    local bytes = {}
    for _,v in ipairs(manifest) do
      if v.path == "install.lua" then bytes[v.path] = verified(v,readFile(NEW .. "/install.lua")) end
    end
    assert(bytes["install.lua"], "Missing pinned installer")
    local index = cacheIndex(handoff.revision,role,manifest)
    local list,generated,entries = installPlan(role,config,manifest,handoff.previous,handoff.revision)
    admission(list,bytes,generated,entries,index)
    fs.delete(CACHE)
    writeFile(CACHE .. "/index",textutils.serialize(index))
    handoff.manifest,handoff.index,handoff.bytes = manifest,index,bytes
  end
  handoff.updating = updating
  if not install(role, config, handoff) then return end
  if updating then startUpdated(previous); return end
  print("Installed " .. role .. ". Use install update to update.")
  if enroll then
    local ok, saved = pcall(function() return textutils.unserialize(readFile("/so-enroll")) end)
    local sk = ok and type(saved) == "table" and saved.token == enroll and saved.sk or nil
    writeFile("/so-enroll", textutils.serialize({ token = enroll, sk = sk }))
    print("Enrolling with server " .. enroll:match("^%d+") .. ". Approve it on the panel.")
  elseif role ~= "server" then print("On the server press P, then type the 6-digit code here") end
  shell.run("/" .. ROLES[role].program)
end
if ... == "prepare" then return main, ROLES end
return main(...)
