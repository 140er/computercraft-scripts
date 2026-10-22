local F = dofile("tests/so/worker-fixture.lua")
local sides = {
  { side="front", cell="0,0,-1" },
  { side="up", cell="0,1,0" },
  { side="down", cell="0,-1,0" },
}
return function(test, equal)
  test("discard drops only the requested junk count into open cells on every side", function()
    for _, side in ipairs(sides) do
      local a = F.setup()
      a.t.inv[1] = { name="minecraft:cobblestone", count=12 }
      F.send(a, {{op="discard",side=side.side,n=5}})
      a.n.advance(1); F.check(a)
      local r = F.sent(a.t,"step.report")[1].body.results[1]
      equal(r.ok,true); equal(a.t.inv[1].count,7)
    end
  end)
  test("discard refuses solid blocks, liquids and inventories on every side", function()
    for _, side in ipairs(sides) do
      for _, block in ipairs({ "minecraft:stone", "minecraft:water",
        {name="minecraft:chest",inv={}} }) do
        local a = F.setup()
        a.n.world[side.cell] = block
        a.t.inv[1] = { name="minecraft:cobbled_deepslate", count=12 }
        F.send(a, {{op="discard",side=side.side}})
        a.n.advance(1); F.check(a)
        local r = F.sent(a.t,"step.report")[1].body.results[1]
        equal(r.ok,false); equal(a.t.inv[1].count,12)
        if type(block)=="table" then equal(#block.inv,0); equal(r.err,"inventory present")
        else equal(r.err,"cell occupied") end
      end
    end
  end)
  test("discard accepts inspected air but still refuses an inventory reporting air", function()
    local a = F.setup()
    a.t.inv[1] = { name="minecraft:cobblestone", count=12 }
    a.t.env.turtle.inspectDown = function() return true, {name="minecraft:air"} end
    a.t.env.peripheral.hasType = function(side, kind) return side=="bottom" and kind=="inventory" end
    F.send(a, {{op="discard",n=2}})
    a.n.advance(1); F.check(a)
    equal(F.sent(a.t,"step.report")[1].body.results[1].ok,false)
    equal(a.t.inv[1].count,12)
    a.t.env.peripheral.hasType = function() return false end
    F.send(a, {{op="discard",n=2}})
    a.n.advance(1); F.check(a)
    equal(F.sent(a.t,"step.report")[2].body.results[1].ok,true)
    equal(a.t.inv[1].count,10)
  end)
  test("discard keeps items when inspection cannot establish an empty cell", function()
    local a = F.setup()
    a.t.inv[1] = { name="minecraft:cobblestone", count=12 }
    a.t.env.turtle.inspectDown = function() return false, "Peripheral unavailable" end
    F.send(a, {{op="discard",n=2}})
    a.n.advance(1); F.check(a)
    local r = F.sent(a.t,"step.report")[1].body.results[1]
    equal(r.ok,false); equal(r.err,"cell unknown"); equal(a.t.inv[1].count,12)
  end)
  test("discard defaults down and rejects unknown sides without dropping", function()
    local a = F.setup()
    a.t.inv[1] = { name="minecraft:cobblestone", count=12 }
    F.send(a, {{op="discard",side="back"}, {op="discard",n=2}})
    a.n.advance(1); F.check(a)
    local r = F.sent(a.t,"step.report")[1].body.results
    equal(r[1].ok,false); equal(r[1].err,"bad side")
    equal(r[2].ok,true); equal(a.t.inv[1].count,10)
  end)
end
