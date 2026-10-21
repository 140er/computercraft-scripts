-- Literal dofile, loadfile, require, and pcall(dofile, "...") edges.
-- One scan per file. Callers decide which edges are shipped.

local M = {}

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
  return text:gsub("\r\n", "\n")
end

function M.read(path)
  return readFile(path)
end

local function isName(byte)
  return (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95
end

local function skipSpace(src, i)
  local n = #src
  while i <= n do
    local b = src:byte(i)
    if b ~= 32 and b ~= 9 and b ~= 10 and b ~= 13 then break end
    i = i + 1
  end
  return i
end

local function skipString(src, i, quote)
  local n = #src
  i = i + 1
  while i <= n do
    local b = src:byte(i)
    if b == 92 then i = i + 2
    elseif b == quote then return i + 1
    else i = i + 1 end
  end
  return n + 1
end

local function quoted(src, i)
  i = skipSpace(src, i)
  local q = src:byte(i)
  if q ~= 34 and q ~= 39 then return nil, i end
  local start = i + 1
  local j = start
  local n = #src
  while j <= n do
    local b = src:byte(j)
    if b == 92 then j = j + 2
    elseif b == q then return src:sub(start, j - 1), j + 1
    else j = j + 1 end
  end
  return nil, n + 1
end

function M.literalDeps(src)
  local out, i, n = {}, 1, #src
  while i <= n do
    local b = src:byte(i)
    if b == 45 and src:byte(i + 1) == 45 then
      if src:sub(i, i + 3) == "--[[" then
        local j = src:find("]]", i + 4, true)
        i = j and j + 2 or n + 1
      else
        local j = src:find("\n", i + 2, true)
        i = j and j + 1 or n + 1
      end
    elseif b == 91 and src:byte(i + 1) == 91 then
      local j = src:find("]]", i + 2, true)
      i = j and j + 2 or n + 1
    elseif b == 34 or b == 39 then
      i = skipString(src, i, b)
    else
      local from, to = src:find("[%a_][%w_]*", i)
      local word = from == i and src:sub(from, to) or nil
      local path, nxt
      if word == "dofile" or word == "loadfile" or word == "require" then
        local j = skipSpace(src, i + #word)
        if src:byte(j) == 40 then
          path, nxt = quoted(src, j + 1)
        end
      elseif word == "pcall" then
        local j = skipSpace(src, i + #word)
        if src:byte(j) == 40 then
          j = skipSpace(src, j + 1)
          if src:sub(j, j + 5) == "dofile" and not isName(src:byte(j + 6) or 0) then
            j = skipSpace(src, j + 6)
            if src:byte(j) == 44 then path, nxt = quoted(src, j + 1) end
          end
        end
      end
      if path then
        out[#out + 1] = path
        i = nxt or (i + 1)
      else
        i = i + 1
      end
    end
  end
  return out
end

function M.normalize(path)
  if type(path) ~= "string" or path == "" or path:find("..", 1, true) or path:byte(1) == 47 then
    return nil
  end
  if path:find("%.lua$") then return path end
  if readFile(path .. ".lua") then return path .. ".lua" end
  local slashed = path:gsub("%.", "/") .. ".lua"
  if readFile(slashed) then return slashed end
  return path .. ".lua"
end

local depCache = {}

local function depsOf(path)
  if depCache[path] then return depCache[path] end
  local src = readFile(path)
  local list = {}
  if src then
    local seen = {}
    for _, raw in ipairs(M.literalDeps(src)) do
      local norm = M.normalize(raw)
      if norm and not seen[norm] then
        seen[norm] = true
        list[#list + 1] = norm
      end
    end
    table.sort(list)
  end
  depCache[path] = list
  return list
end

function M.direct(path)
  return depsOf(path)
end

function M.closure(entry)
  local seen, order = {}, {}
  local function visit(path)
    if not path or seen[path] then return end
    seen[path] = true
    order[#order + 1] = path
    if not readFile(path) then return end
    for _, dep in ipairs(depsOf(path)) do visit(dep) end
  end
  visit(entry)
  return order, seen
end

function M.installRoles()
  local roles = dofile("install-roles.lua")
  local out = {}
  for _, role in ipairs(roles.list()) do
    local files = {}
    for _, name in ipairs(role.files) do files[name] = true end
    local entry = role.id == "roomclient" and "roomsorter.lua" or (role.id .. ".lua")
    out[#out + 1] = { id = role.id, entry = entry, files = files }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.bytes(path)
  local text = readFile(path)
  return text and #text or 0
end

return M
