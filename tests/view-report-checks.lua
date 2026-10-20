return function(test, read)
  test("a killed report write does not empty the previous result", function()
    local source = read("tests/views-runtime.lua")
    local body = assert(source:match("local function json%(path,v%)\n(.-)\nend\nlocal function write"), "json writer missing")
    local files = {}
    local failWrite = false
    local fake = {}
    function fake.open(path, mode)
      assert(mode == "w")
      assert(path:sub(-4) == ".tmp", "destination was truncated")
      local buf = ""
      return {
        write = function(text)
          if failWrite then error("killed during write", 0) end
          buf = buf .. text
        end,
        close = function() files[path] = buf end,
      }
    end
    function fake.exists(path) return files[path] ~= nil end
    function fake.delete(path) files[path] = nil end
    function fake.move(from, to)
      assert(files[from], "move of incomplete temp")
      files[to] = files[from]
      files[from] = nil
    end
    local env = setmetatable({
      fs = fake,
      textutils = { serializeJSON = function(v) return '{"ok":' .. tostring(v.ok) .. '}' end },
    }, { __index = _G })
    local json = assert(load("return function(path,v)\n" .. body .. "\nend", "=json", "t", env))()
    json("sandbox-result.json", { ok = true })
    assert(files["sandbox-result.json"] == '{"ok":true}')
    failWrite = true
    assert(not pcall(json, "sandbox-result.json", { ok = false }))
    assert(files["sandbox-result.json"] == '{"ok":true}', "killed rewrite emptied the report")
  end)
  test("scene readiness waits for the seeded iron cell", function()
    local source = read("tests/views-runtime.lua")
    assert(source:find('Scene.hasCell(gpuRun.scene, 0, 66, 4, "minecraft:iron_ore")', 1, true),
      "readiness still accepts any cell")
  end)
end
