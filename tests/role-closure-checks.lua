return function(test)
  local saved = arg
  arg = { "--module" }
  local loads = dofile("tests/make-bundle-manifest.lua")
  arg = saved
  local Roles = dofile("install-roles.lua")
  local installHandle = assert(io.open("install.lua", "rb"))
  local install = installHandle:read("*a")
  installHandle:close()
  local serverHandle = assert(io.open("server.lua", "rb"))
  local server = serverHandle:read("*a")
  serverHandle:close()
  local cached = assert(load("return " .. assert(server:match("local FILES = (%b{})"))))()

  local function setOf(list)
    local out = {}
    for _, name in ipairs(list) do out[name] = true end
    return out
  end
  local function botFiles(id)
    local at = assert(install:find('{ id = "' .. id .. '"', 1, true), id)
    local body = assert(install:match("files = (%b{})", at), id .. " files")
    return assert(load("return " .. body))()
  end
  local function covers(label, have, need)
    for _, name in ipairs(need) do
      assert(have[name], label .. " misses " .. name)
    end
  end

  test("every role ships the files its program loads", function()
    for _, role in ipairs(Roles.list()) do
      local need = loads.programFiles(role.id)
      covers(role.id .. " role shell", setOf(role.files), need)
      covers(role.id .. " install list", setOf(botFiles(role.id)), need)
    end
    for _, id in ipairs({ "ar", "vworld", "pro" }) do
      covers(id .. " install list", setOf(botFiles(id)), loads.programFiles(id))
    end
    local viewAt = assert(install:find('id="view-pro"', 1, true))
    local viewFiles = assert(load("return " .. assert(install:match("files = (%b{})", viewAt))))()
    for _, id in ipairs({ "view-pro", "view-warehouse", "view-map" }) do
      covers(id .. " install list", setOf(viewFiles), loads.programFiles(id))
    end
    local have = setOf(cached)
    local expect = loads.cacheNames()
    covers("server cache", have, expect)
    local wanted = setOf(expect)
    for _, name in ipairs(cached) do
      assert(wanted[name], "server cache lists " .. name .. " outside the manifest")
    end
  end)
end
