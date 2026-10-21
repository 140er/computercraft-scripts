local function repoRoot()
  local source = debug.getinfo(1, "S").source
  local path = source:sub(1, 1) == "@" and source:sub(2) or source
  local root = path:match("^(.*)[/\\]tests[/\\]ingame[/\\]read%-ssot%.lua$")
  if not root and path:match("^tests[/\\]ingame[/\\]read%-ssot%.lua$") then root = "." end
  assert(root, "read-ssot.lua is not in tests/ingame")
  return root
end

local function hostFs(dir)
  local function full(path)
    return dir .. "/" .. tostring(path):gsub("\\", "/"):gsub("^/+", "")
  end
  return {
    exists = function(path)
      local input = io.open(full(path), "rb")
      if input then input:close() return true end
      return false
    end,
    open = function(path, mode)
      if mode == "w" or mode == "wb" or mode == "a" or mode == "ab" then return nil end
      local input = io.open(full(path), "rb")
      if not input then return nil end
      return {
        readAll = function() return input:read("*a") end,
        read = function(countOrSelf, count)
          local n = type(countOrSelf) == "number" and countOrSelf or count
          if type(n) ~= "number" then return nil end
          return input:read(n)
        end,
        close = function() input:close() end,
      }
    end,
    getFreeSpace = function() return "unlimited" end,
    getCapacity = function() return "unlimited" end,
    makeDir = function() end,
    list = function() return {} end,
    delete = function() end,
    move = function() end,
  }
end

local function loadEnv(dir)
  local root = repoRoot()
  local env = setmetatable({
    fs = hostFs(dir),
    textutils = {
      unserialize = function(text)
        local chunk = load("return " .. text, "state", "t", {})
        if not chunk then return nil end
        local ok, value = pcall(chunk)
        if ok then return value end
      end,
    },
  }, { __index = _G })
  function env.dofile(path)
    local full = root .. "/" .. path:gsub("\\", "/")
    return assert(loadfile(full, "t", env))()
  end
  return env
end

return function(dir)
  local env = loadEnv(dir)
  local store = env.dofile("atomic.lua").store("ssot.state", function(state)
    return type(state) == "table" and type(state.poses) == "table"
  end)
  local state = store.value
  if not state then return nil end
  local map = {
    rev = state.rev,
    chunks = state.chunks,
    names = state.names,
    warehouse = state.warehouse,
    mining = state.mining,
  }
  if state.schema == 2 and env.fs.exists("map/index") then
    local names, chunks, err = env.dofile("mapstore.lua").schema1View(env.fs, "map")
    if err then error(err) end
    map.names, map.chunks = names or {}, chunks or {}
  end
  return state, map
end
