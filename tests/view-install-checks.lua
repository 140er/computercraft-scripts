return function(test,equal,read,mocks)
  local function fixture()
    local m=mocks.new(false)
    m.env.term.getSize=function() return 51,19 end
    local code=read("install.lua")
    local prefix=assert(code:match("^(.-)\n%-+[\r]?\n%-%- Walking through one bot"))
    local roles=assert(load(prefix.."\nreturn BOTS","=install.lua","t",m.env))()
    local byId={}
    for _,role in ipairs(roles) do byId[role.id]=role end
    return m,byId,roles
  end
  test("view installer roles preserve existing order and boot the selected mode",function()
    local m,byId,roles=fixture()
    equal(roles[#roles-4].id,"smartmine")
    equal(roles[#roles-3].id,"store")
    for offset,mode in ipairs({"pro","warehouse","map"}) do
      local role=byId["view-"..mode]
      assert(role==roles[#roles-3+offset])
      equal(role.start[1],"hub") equal(role.start[2],mode)
      local present={}
      for _,name in ipairs(role.files) do present[name]=true end
      for _,name in ipairs({"hub.lua","miner.lua","fleetview.lua","atomic.lua","ssot.lua","ssot-client.lua",
        "nav.lua","mine-tasks.lua","mining.lua","views.lua","view-source.lua","view-scene.lua","directview.lua"}) do
        assert(present[name],role.id.." missing "..name)
      end
      local configured=role.steps[#role.steps].run({server=11,secret="installer-secret-123",gpu="directgpu_0",monitor="monitor_4"})
      equal(configured[1],"hub") equal(configured[2],"view-installed")
      local cfg=assert(load("return "..m.files["views.cfg"],"=views.cfg","t",{}))()
      assert(cfg.enabled) equal(cfg.mode,mode) equal(cfg.server,11)
      equal(cfg.gpu,"directgpu_0") equal(cfg.monitor,"monitor_4")
      local launched
      local env={shell={run=function(...) launched={...} end}}
      assert(load(m.files["startup.lua"],"=startup.lua","t",env))()
      equal(launched[1],"hub") equal(launched[2],mode)
    end
  end)
  test("view installer rejects bad pairing before writing config or startup",function()
    local m,byId=fixture()
    local role=byId["view-map"]
    local function setup(ctx) return role.steps[#role.steps].run(ctx) end
    assert(not pcall(setup,{server=11,secret="short"}))
    assert(not m.files["views.cfg"] and not m.files["startup.lua"])
    assert(not pcall(setup,{server=-1,secret="installer-secret-123"}))
    assert(not m.files["views.cfg"] and not m.files["startup.lua"])
    for _,step in ipairs(role.steps) do
      if step.ask=="server" then
        assert(not step.validate("-1")) assert(not step.validate("1.5")) assert(step.validate("11"))
      elseif step.ask=="secret" then
        assert(not step.validate("short")) assert(step.validate("installer-secret-123"))
      end
    end
  end)
end
