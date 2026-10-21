-- Literal dofile, loadfile, require, and pcall of those with a string.
-- Also a string passed to a local function that dofiles, loadfiles, or
-- requires that parameter, including a table of paths walked into it.
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

local LOADERS = { dofile = true, loadfile = true, require = true }
local BLOCKS = { ["function"] = true, ["if"] = true, ["while"] = true, ["for"] = true, ["do"] = true }

local function loaderEnd(src, j)
  for _, name in ipairs({ "dofile", "loadfile", "require" }) do
    if src:sub(j, j + #name - 1) == name and not isName(src:byte(j + #name) or 0) then
      return j + #name
    end
  end
end

local function tokenize(src)
  local tok, i, n = {}, 1, #src
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
      local text, nxt = quoted(src, i)
      if text then tok[#tok + 1] = { kind = "string", text = text } end
      i = nxt or (i + 1)
    elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 then
      local from, to = src:find("[%a_][%w_]*", i)
      tok[#tok + 1] = { kind = "name", text = src:sub(from, to) }
      i = to + 1
    elseif b == 40 or b == 41 or b == 123 or b == 125 or b == 91 or b == 93
        or b == 61 or b == 44 or b == 46 then
      tok[#tok + 1] = { kind = "punct", text = string.char(b) }
      i = i + 1
    else
      i = i + 1
    end
  end
  return tok
end

local function readTable(tok, i)
  local n, values = #tok, {}
  local depth = 1
  i = i + 1
  while i <= n and depth > 0 do
    local t = tok[i]
    if t.text == "{" then
      depth = depth + 1
      i = i + 1
    elseif t.text == "}" then
      depth = depth - 1
      i = i + 1
    elseif depth > 1 then
      i = i + 1
    elseif t.text == "[" then
      local bracket = 1
      i = i + 1
      while i <= n and bracket > 0 do
        if tok[i].text == "[" then bracket = bracket + 1
        elseif tok[i].text == "]" then bracket = bracket - 1 end
        i = i + 1
      end
      if tok[i] and tok[i].text == "=" then i = i + 1 end
      if tok[i] and tok[i].kind == "string" and tok[i].text:find("%.lua$") then
        values[#values + 1] = tok[i].text
      end
      i = i + 1
    elseif t.kind == "name" and tok[i + 1] and tok[i + 1].text == "=" then
      i = i + 2
      if tok[i] and tok[i].kind == "string" and tok[i].text:find("%.lua$") then
        values[#values + 1] = tok[i].text
      end
      i = i + 1
    elseif t.kind == "string" then
      if t.text:find("%.lua$") then values[#values + 1] = t.text end
      i = i + 1
    else
      i = i + 1
    end
  end
  return values, i
end

local function parseFor(tok, i)
  i = i + 1
  if not tok[i] or tok[i].kind ~= "name" then return end
  local valueVar = tok[i].text
  i = i + 1
  if tok[i] and tok[i].text == "," then
    i = i + 1
    if not tok[i] or tok[i].kind ~= "name" then return end
    valueVar = tok[i].text
    i = i + 1
  end
  if not tok[i] or tok[i].text ~= "in" then return end
  i = i + 1
  if not tok[i] or (tok[i].text ~= "pairs" and tok[i].text ~= "ipairs") then return end
  i = i + 1
  if not tok[i] or tok[i].text ~= "(" then return end
  i = i + 1
  if not tok[i] or tok[i].kind ~= "name" then return end
  local tableName = tok[i].text
  i = i + 1
  if not tok[i] or tok[i].text ~= ")" then return end
  i = i + 1
  if not tok[i] or tok[i].text ~= "do" then return end
  return valueVar, tableName, i + 1
end

local function findEnd(tok, i)
  local n, depth = #tok, 0
  while i <= n do
    local text = tok[i].text
    if BLOCKS[text] then depth = depth + 1
    elseif text == "end" then
      if depth == 0 then return i end
      depth = depth - 1
    end
    i = i + 1
  end
  return n + 1
end

function M.forwardedDeps(src)
  local tok, n = tokenize(src), nil
  n = #tok
  local forwards = {}
  local function register(info)
    if info and info.name and next(info.forwarded) then forwards[info.name] = info.forwarded end
  end
  local function parseFunction(i)
    local name, paren
    local p = i + 1
    if tok[p] and tok[p].kind == "name" and tok[p + 1] and tok[p + 1].text == "(" then
      name = tok[p].text
      paren = p + 1
    elseif tok[p] and tok[p].kind == "name" and tok[p + 1] and tok[p + 1].text == "."
        and tok[p + 2] and tok[p + 2].kind == "name" and tok[p + 3] and tok[p + 3].text == "(" then
      paren = p + 3
    elseif tok[p] and tok[p].text == "(" then
      if tok[i - 1] and tok[i - 1].text == "=" and tok[i - 2] and tok[i - 2].kind == "name" then
        name = tok[i - 2].text
      end
      paren = p
    else
      return nil, i + 1
    end
    p = paren + 1
    local params, index = {}, 1
    while tok[p] and tok[p].text ~= ")" do
      if tok[p].kind == "name" then
        params[index] = tok[p].text
        index = index + 1
      end
      p = p + 1
      if p > n then break end
    end
    if tok[p] and tok[p].text == ")" then p = p + 1 end
    local forwarded, depth = {}, 0
    local function mark(arg, mode)
      if arg and arg.kind == "name" then
        for pos, pname in pairs(params) do
          if pname == arg.text then
            if mode ~= "guarded" or forwarded[pos] == "open" then
              forwarded[pos] = "open"
            else
              forwarded[pos] = "guarded"
            end
          end
        end
      end
    end
    while p <= n do
      local text = tok[p].text
      if text == "function" then
        local info, nxt = parseFunction(p)
        register(info)
        p = nxt
      elseif BLOCKS[text] then
        depth = depth + 1
        p = p + 1
      elseif text == "end" then
        if depth == 0 then
          p = p + 1
          break
        end
        depth = depth - 1
        p = p + 1
      elseif LOADERS[text] and tok[p + 1] and tok[p + 1].text == "(" then
        mark(tok[p + 2], "open")
        p = p + 1
      elseif text == "pcall" and tok[p + 1] and tok[p + 1].text == "("
          and tok[p + 2] and LOADERS[tok[p + 2].text] and tok[p + 3] and tok[p + 3].text == "," then
        mark(tok[p + 4], "guarded")
        p = p + 1
      else
        p = p + 1
      end
    end
    return { name = name, forwarded = forwarded }, p
  end

  local i = 1
  while i <= n do
    if tok[i].text == "function" then
      local info, nxt = parseFunction(i)
      register(info)
      i = nxt or (i + 1)
    else
      i = i + 1
    end
  end

  local tables = {}
  i = 1
  while i <= n do
    if tok[i].kind == "name" and tok[i + 1] and tok[i + 1].text == "="
        and tok[i + 2] and tok[i + 2].text == "{" then
      local values, nxt = readTable(tok, i + 2)
      local list = tables[tok[i].text] or {}
      for _, value in ipairs(values) do list[#list + 1] = value end
      tables[tok[i].text] = list
      i = nxt
    else
      i = i + 1
    end
  end

  local openSet, guardedSet = {}, {}
  local function add(path, mode)
    if not path then return end
    if mode ~= "guarded" then
      openSet[path] = true
      guardedSet[path] = nil
    elseif not openSet[path] then
      guardedSet[path] = true
    end
  end
  local function scan(from, limit, binding)
    local j = from
    while j < limit do
      local text = tok[j].text
      if text == "for" then
        local var, tableName, bodyAt = parseFor(tok, j)
        if var and bodyAt then
          local endAt = findEnd(tok, bodyAt)
          scan(bodyAt, endAt, { var = var, table = tableName })
          j = endAt + 1
        else
          j = j + 1
        end
      elseif forwards[text] and tok[j + 1] and tok[j + 1].text == "(" then
        local spec = forwards[text]
        local k = j + 2
        local argIndex, depth, saw = 1, 0, false
        while k <= n do
          local t = tok[k].text
          if t == "(" then depth = depth + 1
          elseif t == ")" then
            if depth == 0 then break end
            depth = depth - 1
          elseif t == "," and depth == 0 then
            argIndex = argIndex + 1
            saw = false
          elseif depth == 0 and not saw then
            saw = true
            if spec[argIndex] then
              local mode = spec[argIndex] == "guarded" and "guarded" or "open"
              if tok[k].kind == "string" then add(tok[k].text, mode)
              elseif binding and tok[k].kind == "name" and tok[k].text == binding.var then
                for _, value in ipairs(tables[binding.table] or {}) do add(value, mode) end
              end
            end
          end
          k = k + 1
        end
        j = j + 1
      else
        j = j + 1
      end
    end
  end
  scan(1, n + 1, nil)
  local function keys(set)
    local list = {}
    for path in pairs(set) do list[#list + 1] = path end
    table.sort(list)
    return list
  end
  return keys(openSet), keys(guardedSet)
end

function M.literalDeps(src)
  local required, guarded, i, n = {}, {}, 1, #src
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
      local path, nxt, guardedLoad
      if word == "dofile" or word == "loadfile" or word == "require" then
        local j = skipSpace(src, i + #word)
        if src:byte(j) == 40 then
          path, nxt = quoted(src, j + 1)
        end
      elseif word == "pcall" then
        local j = skipSpace(src, i + #word)
        if src:byte(j) == 40 then
          j = skipSpace(src, j + 1)
          local after = loaderEnd(src, j)
          if after then
            j = skipSpace(src, after)
            if src:byte(j) == 44 then
              path, nxt = quoted(src, j + 1)
              guardedLoad = true
            end
          end
        end
      end
      if path then
        local bucket = guardedLoad and guarded or required
        bucket[#bucket + 1] = path
        i = nxt or (i + 1)
      else
        i = i + 1
      end
    end
  end
  return required, guarded
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
local requiredEdge = {}
local guardedAbsent = {}

local function depsOf(path)
  if depCache[path] then return depCache[path] end
  local src = readFile(path)
  local list = {}
  if src then
    local seen = {}
    local function consider(raw, guarded)
      local norm = M.normalize(raw)
      if not norm or seen[norm] then return end
      if guarded and not readFile(norm) then
        if not requiredEdge[norm] then guardedAbsent[norm] = true end
        return
      end
      requiredEdge[norm] = true
      guardedAbsent[norm] = nil
      seen[norm] = true
      list[#list + 1] = norm
    end
    local required, guarded = M.literalDeps(src)
    local forwarded, forwardedGuarded = M.forwardedDeps(src)
    for _, raw in ipairs(required) do consider(raw, false) end
    for _, raw in ipairs(forwarded) do consider(raw, false) end
    for _, raw in ipairs(guarded) do consider(raw, true) end
    for _, raw in ipairs(forwardedGuarded) do consider(raw, true) end
    table.sort(list)
  end
  depCache[path] = list
  return list
end

function M.guardedAbsent()
  local out = {}
  for path in pairs(guardedAbsent) do out[#out + 1] = path end
  table.sort(out)
  return out
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
