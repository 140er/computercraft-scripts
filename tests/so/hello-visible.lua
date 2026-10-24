local F = dofile("tests/so/worker-fixture.lua")
local H = dofile("tests/so/harness.lua")
local modules = { "so-mod-state.lua", "so-log.lua", "so-mod-lease.lua", "so-ui.lua",
  "so-mod-display.lua", "so-mod-panel.lua" }
local function setup()
  return F.setup({ id=2, modem=true, turtle=true, capacity=1000000, width=39, height=13 }, modules)
end
local function send(a, body, key)
  a.seq = (a.seq or 0) + 1
  local p = a.t.env.dofile("so-proto.lua")
  a.t.env.rednet.send(1, p.encode(p.build(key or string.rep("a",64), "hello", body, "hello-test-" .. a.seq)), "so")
  a.n.flush()
end
local function events(a)
  local out = {}
  for _, ev in ipairs(a.s.env.SO.mods.state.history.page({count=50}).entries) do
    if ev.kind == "machine" then out[#out+1] = ev end
  end
  return out
end
local function text(frame)
  local rows = {}
  for _, row in ipairs(frame.rows) do rows[#rows+1] = row.text end
  return table.concat(rows, "\n")
end
return function(test, equal)
  test("hello registers an idle paired turtle in fleet, status, terminal and panel", function()
    local a = setup()
    a.n.advance(5)
    local mods = a.s.env.SO.mods
    local fleet = mods.state.view.get({name="fleet"}).data
    equal(#fleet, 1)
    equal(fleet[1].id, 2)
    equal(fleet[1].role, "turtle")
    equal(fleet[1].fuel, a.t.env.turtle.getFuelLevel())
    equal(mods.lease.status(2).open, nil)
    equal(events(a)[1].data.journal, "2-0")
    local frame
    mods.display.handlers.hello({from=3,body={w=26,h=20}})
    mods.display.handlers["view.get"]({from=3},function(_, f) frame=f end)
    assert(text(frame):find("TURTLES",1,true) and text(frame):find("2  idle",1,true), text(frame))
    local d
    for i=1,20 do
      local name, value = debug.getupvalue(mods.display.tick,i)
      if name == "D" then d=value break end
    end
    local terminal = mods.display.terminal(d.model,{id=1,mode="normal",uptime="up 0h00",log={}},51,19)
    assert(text(terminal):find("1 ok",1,true), text(terminal))
    local panel = mods.display.screen("panel").render(26,20,{})
    assert(text(panel):find("TURTLES 1 ok, 0 lost",1,true), text(panel))
    F.check(a)
  end)
  test("hello throttles unchanged and small fuel updates but records journal and significant fuel changes", function()
    local a = setup()
    local body = {role="turtle",fuel=1000,journal={id="fresh"}}
    send(a,body)
    local count = #events(a)
    for _=1,5 do send(a,body) end
    equal(#events(a), count)
    body.fuel=999;send(a,body);equal(#events(a),count)
    body.fuel=900;send(a,body);count=count+1;equal(#events(a),count)
    body.journal.id="changed";send(a,body);count=count+1;equal(#events(a),count)
    a.n.time=a.n.time+59999
    send(a,body);equal(#events(a),count)
    a.n.time=a.n.time+1
    send(a,body);count=count+1;equal(#events(a),count)
    body.fuel=0;send(a,body);count=count+1;equal(#events(a),count)
    body.fuel=1;send(a,body);count=count+1;equal(#events(a),count)
    body.fuel="unlimited";send(a,body);count=count+1;equal(#events(a),count)
    body.journal.id="forged"
    send(a,body,string.rep("b",64));equal(#events(a),count)
  end)
  test("paired display hello registers a display without adding a turtle", function()
    local a = setup()
    assert(a.s.env.SO.pair.remember(3,string.rep("a",64)))
    local display = a.n.machine({id=3,modem=true,width=26,height=20})
    for path, data in pairs(a.t.files) do display.files[path]=data end
    display.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=string.rep("a",64)}}})
    display.install({"display.lua"});display.boot("display.lua")
    a.n.flush();a.n.advance(5)
    assert(display.alive(),tostring(display.error))
    local state = a.s.env.SO.mods.state
    equal(state.get("machines/3").role,"display")
    equal(#state.view.get({name="fleet"}).data,2)
    local panel = a.s.env.SO.mods.display.screen("panel").render(26,20,{})
    assert(text(panel):find("TURTLES 1 ok, 0 lost",1,true))
  end)
  test("worker screen fits five rows and shows label, connection and elapsed seen time", function()
    local a=setup()
    a.n.advance(5)
    equal(a.t.screen[1],a.t.env.os.getComputerLabel())
    equal(a.t.screen[5],"server 1 ok")
    assert(a.t.screen[4]:match("^seen %ds ago$"),a.t.screen[4])
    a.n.kill(a.s);a.n.advance(65)
    equal(a.t.screen[5],"waiting for server")
    assert(a.t.screen[4]:match("^seen %dm ago$"),a.t.screen[4])
    for y,row in pairs(a.t.screen) do assert(y<=5 and #row<=39,row) end
    local b=setup()
    b.n.kill(b.s)
    b.t=b.n.boot(b.t);b.n.advance(3)
    equal(b.t.screen[1],b.t.env.os.getComputerLabel())
    equal(b.t.screen[5],"waiting for server")
    equal(b.t.screen[4],"seen -")
  end)
end
