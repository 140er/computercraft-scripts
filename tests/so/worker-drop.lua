local F = dofile("tests/so/worker-fixture.lua")
return function(test, equal)
  test("unload without a chest keeps the turtle inventory", function()
    local a = F.setup()
    a.t.inv[1] = { name="minecraft:diamond", count=32 }
    F.send(a, { {op="select",slot=1}, {op="inspect"}, {op="drop"} })
    a.n.advance(1); F.check(a)
    equal(a.t.inv[1].count, 32)
    local r = F.sent(a.t, "step.report")[1].body.results
    equal(r[2].ok, false); equal(r[3].ok, false); equal(r[3].err, "no inventory")
  end)
  test("transfers require inventories on each side and preserve counts", function()
    for _, side in ipairs({ {"", "0,0,-1"}, {"Up", "0,1,0"}, {"Down", "0,-1,0"} }) do
      local a = F.setup()
      a.t.inv[1] = {name="minecraft:diamond",count=32}
      for _, block in ipairs({ false, "minecraft:stone" }) do
        a.n.world[side[2]] = block or nil
        F.send(a, {{op="drop"..side[1],n=3}, {op="suck"..side[1],n=2}})
        a.n.advance(1); F.check(a)
        local r = F.sent(a.t,"step.report"); r=r[#r].body.results
        equal(r[1].err,"no inventory"); equal(r[2].err,"no inventory")
        equal(a.t.inv[1].count,32)
      end
      a.n.world[side[2]] = {name="mod:crate",inv={}}
      F.send(a, {{op="drop"..side[1],n=3}, {op="suck"..side[1],n=2}})
      a.n.advance(1); F.check(a)
      equal(a.t.inv[1].count,31)
      local r=F.sent(a.t,"step.report"); r=r[#r].body.results
      equal(r[1].ok,true); equal(r[2].ok,true)
    end
  end)
end
