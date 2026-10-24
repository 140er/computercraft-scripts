local H = dofile("tests/so/harness.lua")

return function(test, equal)
  local function machine(files)
    local net = H.new()
    local m = net.machine({ id=1, directories=true })
    m.install({ "so-store.lua", "so-ui.lua", "so-mod-daily.lua" })
    for path, text in pairs(files or {}) do m.files[path] = text end
    m.env.SO = { mods={}, now=function() return net.time end }
    m.env.SO.store = m.env.dofile("so-store.lua")
    return m
  end
  local function boot(m)
    m.spawn([[daily=dofile("so-mod-daily.lua")]])
    assert(not m.error, m.error)
  end

  test("daily resets corrupt generations once and saves usable totals", function()
    local m = machine({
      ["so-data/daily"]="garbage",
      ["so-data/daily.tmp"]="{schema=1,generation=2,value={}}",
      ["so-data/daily.bak"]="broken",
    })
    boot(m)
    local today = m.env.daily.today()
    equal(today.ore,0)
    equal(today.oreByName,{})
    equal(today.logs,0)
    equal(today.oreRecent,0)
    equal(#m.log,1)
    equal(m.log[1],"so-daily: unreadable totals reset")
    for _, suffix in ipairs({"", ".tmp", ".bak"}) do
      equal(m.files["so-data/daily"..suffix],nil)
    end
    m.env.daily.tick(0)
    assert(m.files["so-data/daily"],"reset totals were not saved")
    local recovered = machine(m.files)
    boot(recovered)
    equal(recovered.env.daily.today(),m.env.daily.today())
    equal(#recovered.log,0)
  end)

  test("daily recovers valid totals from a surviving generation", function()
    for _, suffix in ipairs({"", ".tmp", ".bak"}) do
      local m = machine()
      local value = {date="2026-10-25",cursor=12,ore=7,oreByName={diamond=7},logs=9,recent={}}
      assert(m.env.SO.store.store("so-data/daily",function() return true end).save(value))
      local files = { ["so-data/daily"]="broken", ["so-data/daily.tmp"]="broken",
        ["so-data/daily.bak"]="broken" }
      files["so-data/daily"..suffix] = m.files["so-data/daily"]
      local recovered = machine(files)
      boot(recovered)
      equal(recovered.env.daily.today().ore,7)
      equal(recovered.env.daily.today().logs,9)
      equal(#recovered.log,0)
      for path, text in pairs(files) do equal(recovered.files[path],text) end
    end
  end)

  test("daily propagates unrelated store errors without deleting files", function()
    local m = machine({["so-data/daily"]="keep"})
    m.env.SO.store.store = function() error("disk unavailable") end
    m.spawn([[daily=dofile("so-mod-daily.lua")]])
    assert(m.error and m.error:find("disk unavailable",1,true))
    equal(m.files["so-data/daily"],"keep")
    equal(#m.log,0)
  end)
end
