local F = dofile("tests/so/worker-fixture.lua")
local function setup(role)
  local a = F.setup({ id=2, modem=true, turtle=true, capacity=1000000, x=40, y=64, z=10 }, {
    "so-plan.lua", "so-mine-plan.lua", "so-lumber-plan.lua", "so-mod-cells.lua",
    "so-mod-display.lua", "so-mod-lease.lua", "so-mod-" .. role .. ".lua",
  })
  local screens = {}
  local display = a.s.env.SO.mods.display
  local screen = display.screen
  display.screen = function(name, render, input)
    screens[name] = { render=render, input=input }
    return screen(name, render, input)
  end
  a.s.env.SO.mods[role].tick(a.n.time)
  a.screen = assert(screens[role == "mine" and "mining" or "lumber"])
  a.input = function(text) a.screen.input({text=text}) a.n.flush() end
  if role == "lumber" then a.input("area 40 10 42 12 63") end
  a.input("add 2 40 64 10 n")
  a.n.advance(1)
  return a
end
local function interruptTurn(a, happened)
  local turn = a.t.env.turtle.turnRight
  if happened then
    a.t.env.turtle.turnRight = function()
      turn(); a.n.kill(a.t); error("power loss")
    end
  end
  F.send(a, {{op="turnRight"}})
  if happened then a.n.advance(0.05) end
  a.t.env.turtle.turnRight = turn
  a.t.killed=false
  a.t.co,a.t.inbox,a.t.timers=nil,{},{}
  a.t.boot("worker.lua"); a.n.advance(3); F.check(a)
end
return function(test, equal)
  for _, role in ipairs({"mine", "lumber"}) do
    for _, happened in ipairs({false,true}) do
      test(role .. " add reanchors an uncertain turn that " .. (happened and "ran" or "did not run"), function()
        local a = setup(role)
        interruptTurn(a,happened)
        local lease = a.s.env.SO.mods.lease
        equal(lease.status(2).uncertain,true)
        a.s.env.SO.mods[role].tick(a.n.time)
        local text = ""
        for _, row in ipairs(a.screen.render(51,19).rows) do text=text .. row.text .. "\n" end
        assert(text:find("pose uncertain: re-add turtle 2",1,true),text)
        local narrow=""
        for i,row in ipairs(a.screen.render(26,19).rows) do
          if i<=19 then narrow=narrow..row.text:sub(1,26).."\n" end
        end
        assert(narrow:find("pose uncertain:",1,true),narrow)
        assert(narrow:find("re-add turtle 2",1,true),narrow)
        assert(table.concat(a.t.screen,"\n"):find("pose uncertain: re-add turtle 2",1,true))
        local id, err = lease.send(2,{{op="forward"}})
        equal(id,nil);equal(err,"pose uncertain")
        local send, dropped = a.t.env.rednet.send, false
        a.t.env.rednet.send = function(id,payload,protocol)
          local j=payload.body and payload.body.journal
          if not dropped and payload.t=="hello" and type(j)=="table" and j.recovery
            and j.recovery.outcome=="anchored" then dropped=true return true end
          return send(id,payload,protocol)
        end
        a.input("add 2 40 64 10 " .. (happened and "e" or "n"))
        a.n.advance(3); F.check(a)
        equal(dropped,true)
        equal(lease.status(2).uncertain,nil)
        local j=F.journal(a.t)
        equal(j.uncertain,nil);equal(j.pending,nil)
        equal(j.pose,{x=40,y=64,z=10,f=happened and 1 or 0})
        equal(#j.moves,0);equal(#j.dug,0)
        a.t.co,a.t.inbox,a.t.timers=nil,{},{}
        a.t.boot("worker.lua");a.n.advance(3);F.check(a)
        equal(F.journal(a.t).uncertain,nil)
        assert(lease.send(2,{{op="forward"}}))
        a.n.advance(0.2); F.check(a)
        equal(a.t.pos.x,happened and 41 or 40)
        equal(a.t.pos.z,happened and 10 or 9)
        local p=lease.status(2).pose
        equal(p.x,a.t.pos.x);equal(p.z,a.t.pos.z)
      end)
    end
  end
end
