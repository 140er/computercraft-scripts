local H = dofile("tests/so/harness.lua")
local F = dofile("so-flags.lua")
local P = dofile("so-plan.lua")
local FILES = {"so-server.lua", "so-store.lua", "so-proto.lua", "so-pair.lua", "so-log.lua", "so-errors.lua",
  "so-plan.lua", "so-mine-plan.lua", "so-lumber-plan.lua", "so-ui.lua", "so-mod-ar.lua", "so-mod-build.lua",
  "so-mod-cells.lua", "so-mod-daily.lua", "so-mod-display.lua", "so-mod-drops.lua", "so-mod-health.lua",
  "so-mod-lease.lua", "so-mod-lumber.lua", "so-mod-map.lua", "so-mod-mine.lua", "so-mod-panel.lua", "so-mod-shop.lua", "so-mod-state.lua"}
local function boot(config)
  local n = H.new()
  local m = n.machine({id=1,modem=true,capacity=16000000})
  m.install(FILES)
  for _, name in ipairs({"x25519", "random", "blake3", "chacha20", "config", "internal/util", "internal/hw",
    "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing"}) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local file = assert(io.open(path, "rb")) m.files[path] = file:read("*a") file:close()
  end
  if config then m.files["so-server.cfg"] = H.encode(config) end
  m.boot("so-server.lua") n.flush() n.advance(1.1)
  assert(m.alive(), tostring(m.error))
  for file, row in pairs(m.env.SO.health.modules) do assert(row.status == "loaded", file .. ": " .. tostring(row.error)) end
  return m.env.SO, m, n
end
local function private(fn, key)
  for i=1,60 do local name, value=debug.getupvalue(fn,i) if name==key then return value end end
  error("missing upvalue " .. key)
end
return function(test, equal)
  test("feature defaults enable every feature and preserve every explicit false", function()
    local count=0
    for name, default in pairs(F.defaults) do
      count=count+1
      local expected=name~="retireLegacyPair" and name~="soundQuiet"
      equal(default,expected,name)
      equal(F.enabled(nil,name),expected,name)
      equal(F.enabled({},name),expected,name)
      local config={}
      if name=="state.coalesceHeartbeats" then config.state={coalesceHeartbeats=false} else config[name]=false end
      equal(F.enabled(config,name),false,name)
    end
    equal(count,29)
    equal(F.enabled({state=false},"state.coalesceHeartbeats"),false)
    local quiet={startMinute=1380,endMinute=420}
    equal(F.get({soundQuiet=quiet},"soundQuiet"),quiet)
  end)
  test("fresh server boots every module with effective defaults without writing a config", function()
    local so,m=boot()
    for name in pairs(F.defaults) do equal(F.get(so.health.config,name),F.get(nil,name),name) end
    equal(m.files["so-server.cfg"],nil)
    equal(so.enroll.enabled(),true)
    equal(select(2,so.updateWorker(12)),"update required")
    assert(table.concat(m.log,"\n"):find("legacy pair: kept",1,true))
    assert(so.enroll.setEnabled(false))
    equal(m.env.textutils.unserialize(m.files["so-server.cfg"]),{enroll=false})
    equal(so.enroll.enabled(),false)
  end)
  test("fresh terminal revoke confirms before forgetting a paired device", function()
    local so,m,n=boot()
    assert(so.pair.remember(12,string.rep("ab",32)))
    m.env.os.queueEvent("key",19,false) n.flush()
    local function enter(text)
      m.env.os.queueEvent("paste",text)
      m.env.os.queueEvent("key",28,false) n.flush()
      assert(m.alive(),tostring(m.error))
    end
    enter("12 revoke")
    assert(so.pair.key(12))
    enter("12")
    equal(so.pair.key(12),nil)
  end)
  test("fresh lease enables boundaries and worker settings without worker consent", function()
    local so=boot()
    equal(so.mods.lease.boundaries(),true)
    equal(select(2,so.mods.lease.settings(12,{autoToolSwap=true})),"update required")
  end)
  test("fresh cells enforce protection and expose confirmed world edits", function()
    local so=boot()
    local box={id="wall",dim="minecraft:overworld",x1=1,x2=1,y1=0,y2=0,z1=0,z2=0}
    assert(so.mods.cells.protect({box}))
    equal(so.mods.cells.admit("mine:2",{dim=box.dim,x=0,y=0,z=0,facing=1},"forward",{dim=box.dim,x=1,y=0,z=0}),false)
    local _,reason=so.mods.cells.releaseRequest("setup:12",1)
    assert(reason~="world edits disabled")
  end)
  test("fresh mining lumber and builder enable interactive setup and worker controls", function()
    local so=boot()
    equal(private(so.mods.mine.tick,"S").poseSetup,true)
    local lumber=private(so.mods.lumber.tick,"S")
    equal({lumber.poseSetup,lumber.scanNow,lumber.workerPark},{true,true,true})
    local build=private(so.mods.build.tick,"S")
    equal({build.poseSetup,build.solid,build.fuelTrips,build.workerPark},{true,true,true,true})
    local render=so.mods.display.screen("build").render
    local frame=render(57,24,{buildSetup=true})
    local solid=false for _,b in ipairs(frame.buttons) do if b.id=="shape solid" then solid=true end end
    assert(solid,"fresh builder does not offer SOLID")
  end)
  test("fresh drop setup enables saved discoveries queue movement and room sinks together", function()
    local so,m=boot()
    local drops=private(so.mods.drops.tick,"S")
    equal({drops.enabled(),drops.queueEnabled(),drops.roomSink},{true,true,true})
    assert(drops.observe({dim=0,x=1,y=63,z=0,side="down",block="minecraft:chest",at=so.now()}))
    local saved=so.store.read("so-drops").value
    equal({saved.v,#saved.candidates,saved.roomSink},{2,1,true})
    drops.setupRefuse=function(reason) error(reason) end
    -- A missing worker may refuse setup, but its feature switch must permit admission.
    local ok,reason=pcall(drops.beginSetup,12)
    assert(not ok and tostring(reason):find("no unassigned idle turtle",1,true), tostring(reason))
    m.files["so-server.cfg"] = H.encode({dropsTestQueue=false,dropsSavedSetup=false,roomSink=false})
    equal({drops.enabled(),drops.queueEnabled()},{false,false})
  end)
  test("room sink explicit false survives a save and server restart", function()
    local so,m,n=boot()
    assert(so.mods.drops.roomSink(false))
    equal(so.store.read("so-drops").value.roomSink,false)
    n.kill(m) m=n.boot(m) n.flush() n.advance(1.1)
    assert(m.alive(),tostring(m.error))
    equal(private(m.env.SO.mods.drops.tick,"S").roomSink,false)
    local disabled=boot({roomSink=false})
    equal(private(disabled.mods.drops.tick,"S").roomSink,false)
    equal(select(2,disabled.mods.drops.roomSink(true)),"room sink disabled")
  end)
  test("fresh display enables acknowledgements inventory and worker park controls", function()
    local so=boot()
    local display=private(so.mods.display.tick,"D")
    equal({display.ackOn,display.invOn,display.workerPark},{true,true,true})
    local panel=private(so.mods.panel.tick,"P")
    equal({panel.flag("panelUpdates"),panel.flag("workerSettings")},{true,true})
  end)
  test("fresh AR and map enable followups and remote dimensions", function()
    local so=boot()
    local ar=private(so.mods.ar.tick,"A")
    equal({ar.follow,ar.remote},{true,true})
    equal(P.dimensionError("minecraft:the_nether"),nil)
    equal(P.dimensionError("minecraft:the_end",{remoteDimensions=false}),"remote dimensions disabled")
    local frame=so.mods.map.render(57,24,{})
    local remote=false for _,b in ipairs(frame.buttons) do if b.id=="map-dim" then remote=true end end
    assert(remote,"fresh map does not offer dimension selection")
  end)
  test("fresh shop enables delivery admission and saved lists", function()
    local so=boot()
    equal(so.mods.shop.deliveryView().enabled,true)
    assert(so.mods.shop.saved("lists"))
  end)
  test("fresh state coalesces routine heartbeats", function()
    local so=boot()
    local state=so.mods.state
    state.handlers.hello({from=12,body={role="worker",fuel=1000}})
    local seq=state.diagnostics().seq
    state.handlers.hello({from=12,body={role="worker",fuel=1000}})
    equal(state.diagnostics().seq,seq)
  end)
end
