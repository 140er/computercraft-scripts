local M = {}
local A = dofile("atomic.lua")
M.slice = 12000
M.protocol = "codeshelf"

local function readCfg()
  local t = A.read("shelf.cfg")
  if type(t) == "table" and type(t.value) == "table" and t.v == 1 then return t.value end
  if type(t) == "table" and t.v == 1 and t.codeShelf ~= nil then return t end
  if type(t) == "table" and t.codeShelf ~= nil then return t end
  return nil
end

local function namesOf(role)
  local out, seen = {}, {}
  local function add(name)
    if not seen[name] then seen[name] = true out[#out + 1] = name end
  end
  for _, name in ipairs(role.program or {}) do add(name) end
  for _, name in ipairs(role.serves or {}) do add(name) end
  return out
end

local function fileInfo(sizeOf, name)
  local n = sizeOf(name) or 0
  if n <= 0 or not fs.exists(name) then return nil end
  local h = fs.open(name, "r")
  if not h then return nil end
  local text = h.readAll()
  h.close()
  return { hash = A.hash(text), size = #text }
end

local function helloFor(opts, roleName)
  local roles = opts.roles
  local program, serves, listed = {}, {}, {}
  if roleName and roles.roles[roleName] and roles.roleShelf(roleName) == opts.name then
    local role = roles.roles[roleName]
    program, serves = role.program, role.serves or {}
    for _, name in ipairs(namesOf(role)) do listed[#listed + 1] = name end
  else
    local union = roles.union(opts.name, opts.sizeOf)
    for name in pairs(union.files) do listed[#listed + 1] = name end
    table.sort(listed)
    program = listed
    serves = {}
  end
  local files = {}
  for _, name in ipairs(listed) do
    local info = fileInfo(opts.sizeOf, name)
    if info then files[name] = info end
  end
  return {
    type = "shelf", name = opts.name, role = roleName,
    program = program, serves = serves, files = files,
  }
end

local function send(id, msg)
  rednet.send(id, msg, M.protocol)
end

function M.host(opts)
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then error("Attach a wireless or ender modem to this computer.", 0) end
  rednet.open(peripheral.getName(modem))
  rednet.host(M.protocol, opts.name)
  local union = opts.roles.union(opts.name, opts.sizeOf)
  while true do
    local id, m = rednet.receive(M.protocol)
    if type(m) == "table" and m.type == "hello" then
      local reply = helloFor(opts, m.role)
      reply.rid = m.rid
      send(id, reply)
    elseif type(m) == "table" and m.type == "get" and type(m.file) == "string" then
      if not union.files[m.file] then
        send(id, { type = "file", file = m.file, error = "absent", rid = m.rid })
      else
        local h = fs.open(m.file, "r")
        local text = h and h.readAll() or ""
        if h then h.close() end
        local hash, size = A.hash(text), #text
        local offset = type(m.offset) == "number" and m.offset or 0
        if offset < 0 or offset % 1 ~= 0 then offset = 0 end
        local current = m.hash == hash
        send(id, {
          type = "file", file = m.file, hash = hash, size = size, offset = offset, rid = m.rid,
          current = current, code = current and nil or text:sub(offset + 1, offset + M.slice),
        })
      end
    end
  end
end

local function lookup(name)
  return rednet.lookup(M.protocol, name)
end

local function ask(id, msg)
  local rid = math.random(1, 1073741824)
  msg.rid = rid
  rednet.send(id, msg, M.protocol)
  local deadline = os.clock() + 8
  repeat
    local from, reply = rednet.receive(M.protocol, math.max(0, deadline - os.clock()))
    if from == id and type(reply) == "table" and reply.rid == rid then return reply end
  until os.clock() >= deadline
end

function M.fetch(file)
  local cfg = readCfg()
  if not cfg or cfg.codeShelf ~= true then return nil, "shelf off" end
  local name = cfg.shelf
  if type(name) ~= "string" then return nil, "shelf_absent" end
  local id = lookup(name)
  if not id then return nil, "shelf_absent" end
  local hello = ask(id, { type = "hello", role = cfg.role })
  local info = hello and hello.files and hello.files[file]
  if not info then return nil, "shelf_absent" end
  local localHash
  if fs.exists(file) then
    local h = fs.open(file, "r")
    local text = h.readAll()
    h.close()
    localHash = A.hash(text)
  end
  local parts, offset = {}, 0
  while offset < info.size do
    local reply = ask(id, { type = "get", file = file, hash = localHash, offset = offset })
    if not reply or reply.error or reply.file ~= file or reply.hash ~= info.hash then
      return nil, "shelf_absent"
    end
    if reply.current then return nil, "current" end
    if type(reply.code) ~= "string" or #reply.code == 0 or reply.offset ~= offset then
      return nil, "shelf_absent"
    end
    parts[#parts + 1] = reply.code
    offset = offset + #reply.code
  end
  local text = table.concat(parts)
  if #text ~= info.size or A.hash(text) ~= info.hash or not load(text, "=" .. file) then
    return nil, "shelf_absent"
  end
  return text
end

local function hostsFor(roles, files)
  local need = {}
  local byName = {}
  for _, name in ipairs(files) do byName[name] = true end
  for shelfName, roleNames in pairs(roles.shelves) do
    local union = roles.union(shelfName, function() return 1 end)
    for name in pairs(union.files) do
      if byName[name] then need[shelfName] = true end
    end
  end
  return need
end

function M.enable(files, opts)
  opts = opts or {}
  local roles = opts.roles
  if not roles then return false, "shelf_absent" end
  local cfg = readCfg()
  local shelves = {}
  if opts.shelf then shelves[opts.shelf] = true
  elseif cfg and type(cfg.shelf) == "string" then shelves[cfg.shelf] = true
  else shelves = hostsFor(roles, files) end
  local have = {}
  for shelfName in pairs(shelves) do
    local id = lookup(shelfName)
    if not id then return false, "shelf_absent" end
    local hello = ask(id, { type = "hello", role = opts.role })
    if not hello or type(hello.files) ~= "table" then return false, "shelf_absent" end
    for name, info in pairs(hello.files) do have[name] = info end
  end
  for _, name in ipairs(files) do
    local info = have[name]
    if not info or type(info.hash) ~= "string" then return false, "shelf_absent" end
    if fs.exists(name) then
      local h = fs.open(name, "r")
      local text = h.readAll()
      h.close()
      if A.hash(text) ~= info.hash then return false, "shelf_absent" end
    end
  end
  local disk = A.mount("/")
  local function valid(v)
    return type(v) == "table"
  end
  local rec = disk:open("shelf.cfg", valid, { class = "control", limit = 4096 })
  local body = { v = 1, codeShelf = true, shelf = opts.shelf or cfg and cfg.shelf, role = opts.role }
  local ok, err = rec:save(body)
  if not ok then return false, err end
  return true
end

return M
