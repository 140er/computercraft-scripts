local F = dofile("tests/so/worker-fixture.lua")
local P = dofile("so-plan.lua")
local function setup(enabled, fail, full)
  local a = F.setup(nil, {"so-mod-lease.lua"})
  local calls = 0
  local equipped = {left={name="minecraft:diamond_axe"},right={name="computercraft:wireless_modem"}}
  local inventory = {[1]={name="minecraft:diamond_pickaxe",count=1}}
  local selected = 1
  a.n.onBoot = function(m)
  if m.id ~= 2 then return end
  local t = m.env.turtle
  t.getEquippedLeft = function() return equipped.left end
  t.getEquippedRight = function() return equipped.right end
  t.getSelectedSlot = function() return selected end
  t.select = function(slot) selected=slot return true end
  t.getItemDetail = function(slot) return inventory[slot or selected] end
  t.getItemCount = function(slot) return inventory[slot] and inventory[slot].count or (full and 64 or 0) end
  local function equip(side)
    calls=calls+1
    if fail then return false,"inventory full" end
    equipped[side],inventory[selected]=inventory[selected],equipped[side]
    return true
  end
  t.equipLeft = function() return equip("left") end
  t.equipRight = function() return equip("right") end
  end
  a.t.files["so-worker.cfg"] = "{autoToolSwap="..tostring(enabled).."}"
  a.n.kill(a.t); a.t=a.n.boot(a.t); a.n.advance(5)
  a.equipped,a.inventory=equipped,inventory
  a.calls=function() return calls end
  return a
end
local function report(a)
  local reports=F.sent(a.t,"step.report")
  return assert(reports[#reports]).body
end
return function(test,equal)
  test("tool readiness distinguishes missing, equipped and old workers",function()
    equal(P.toolCheck(nil,"pickaxe").ok,true)
    equal(P.toolCheck(nil,"pickaxe").text,"tools unknown")
    equal(P.toolCheck({left=false,right=false},"pickaxe").ok,false)
    equal(#P.missing({P.toolCheck({left=false,right=false},"pickaxe")}),0)
    equal(#P.missing({P.toolCheck({left=false,right=false},"pickaxe",nil,true)}),1)
    equal(P.toolCheck({left="minecraft:diamond_pickaxe",right=false},"axe").ok,false)
    equal(P.toolCheck({left="minecraft:diamond_axe",right=false},"axe").ok,true)
    local health=assert(loadfile("so-mod-health.lua","t",setmetatable({dofile=dofile},{__index=_G})))()
    local rows=health.attention({now=0,disk={},jobs={mining={turtles={["2"]={}}}},
      machines={["2"]={}},leases={["2"]={tools={left=false,right=false}}}})
    equal(#rows,1);equal(rows[1].text,"T2 needs pickaxe");equal(rows[1].target,"mining")
  end)
  test("worker tool swaps default off and preserve the old tool",function()
    local a=setup(false)
    local allowed,reason=a.s.env.SO.mods.lease.ensureTool(2,"pickaxe")
    equal(allowed,true);equal(reason,"needs pickaxe");equal(a.calls(),0)
    F.send(a,{{op="tool",kind="pickaxe"}});a.n.advance(1)
    equal(report(a).results[1].ok,false);equal(report(a).results[1].err,"tool swaps disabled")
    equal(a.equipped.left.name,"minecraft:diamond_axe");equal(a.calls(),0)
    equal(a.s.env.SO.mods.lease.status(2).tools.left,"minecraft:diamond_axe")
    F.check(a)
  end)
  test("worker swap preserves tools with a full inventory and is idempotent after reboot",function()
    local a=setup(true,false,true)
    F.send(a,{{op="tool",kind="pickaxe"}});a.n.advance(1)
    equal(report(a).results[1].ok,true);equal(a.calls(),1)
    equal(a.equipped.left.name,"minecraft:diamond_pickaxe")
    equal(a.equipped.right.name,"computercraft:wireless_modem")
    equal(a.inventory[1].name,"minecraft:diamond_axe")
    a.n.kill(a.t);a.t=a.n.boot(a.t);a.n.advance(5)
    F.send(a,{{op="tool",kind="pickaxe"}});a.n.advance(1)
    equal(report(a).results[1].ok,true);equal(a.calls(),1)
    F.send(a,{{op="discard",side="down"},{op="equipLeft"}});a.n.advance(1)
    equal(report(a).results[1].err,"tool kept");equal(report(a).results[2].err,"use tool step")
    equal(a.inventory[1].name,"minecraft:diamond_axe");F.check(a)
  end)
  test("failed automatic swap keeps old tools and raises a lease alert",function()
    local a=setup(true,true)
    local lease=a.s.env.SO.mods.lease
    equal(lease.ensureTool(2,"pickaxe"),false)
    a.n.advance(1)
    equal(a.equipped.left.name,"minecraft:diamond_axe")
    equal(a.inventory[1].name,"minecraft:diamond_pickaxe")
    equal(lease.status(2).toolError,"tool swap failed: inventory full")
    lease.ensureTool(2,"pickaxe");a.n.advance(1);equal(a.calls(),1)
    lease.describe(2,"mine","needs pickaxe");a.n.advance(5)
    equal(a.t.screen[2],"mine idle");equal(a.t.screen[4],"needs pickaxe")
    F.check(a)
  end)
  test("missing tools stay stationary beyond expiry and status traffic refreshes equipment",function()
    local a=setup(false)
    F.send(a,{{op="forward"}},1000);a.n.advance(0.2)
    local z=a.t.pos.z
    F.send(a,{{op="tool",kind="pickaxe"}},1000);a.n.advance(0.2)
    local lease=a.s.env.SO.mods.lease
    for _=1,8 do lease.describe(2,"mine","needs pickaxe");a.n.advance(20) end
    equal(a.t.pos.z,z)
    a.equipped.left={name="minecraft:diamond_pickaxe"}
    for _=1,4 do lease.describe(2,"mine","needs pickaxe");a.n.advance(20) end
    equal(lease.status(2).tools.left,"minecraft:diamond_pickaxe")
    equal(lease.ensureTool(2,"pickaxe"),true);F.check(a)
  end)
  test("power loss after equip before completion never swaps the old tool back",function()
    local a=setup(true)
    local equip=a.t.env.turtle.equipLeft
    a.t.env.turtle.equipLeft=function()
      equip();a.n.kill(a.t);error("power loss")
    end
    F.send(a,{{op="tool",kind="pickaxe"}});a.n.advance(0.1)
    equal(F.journal(a.t).pending.op,"tool")
    equal(a.equipped.left.name,"minecraft:diamond_pickaxe")
    a.t=a.n.boot(a.t);a.n.advance(5)
    F.send(a,{{op="tool",kind="pickaxe"}});a.n.advance(1)
    equal(report(a).results[1].ok,true);equal(a.calls(),1)
    equal(a.inventory[1].name,"minecraft:diamond_axe");F.check(a)
  end)
  test("lumber recovers a lost worker before tool checks and parks a missing axe",function()
    local s=dofile("tests/so/lumber-fixture.lua")("scan")
    local checked=0
    s.mods.lease.status=function() return {lost=true} end
    s.mods.lease.ensureTool=function() checked=checked+1 return false,"needs axe" end
    s.tick(1)
    equal(checked,0);equal(s.queued().steps[1].op,"inspectDown")
    equal(s.queued().opts.recover,true)
    s.report(false)
    s.mods.lease.status=function() return {} end
    s.tick(2)
    equal(checked,1);equal(s.queued().steps[1].op,"inspectDown")
    equal(s.row.alert,"needs axe")
  end)

  test("worker equips an axe on the empty side before replacing a tool",function()
    for _, empty in ipairs({"left","right"}) do
      local a=setup(true)
      local occupied=empty == "left" and "right" or "left"
      a.equipped[empty]=nil
      a.equipped[occupied]={name="minecraft:diamond_pickaxe"}
      a.inventory[1]={name="minecraft:diamond_axe",count=1}
      F.send(a,{{op="tool",kind="axe"}});a.n.advance(1)
      equal(report(a).results[1].ok,true);equal(a.calls(),1)
      equal(a.equipped[empty].name,"minecraft:diamond_axe")
      equal(a.equipped[occupied].name,"minecraft:diamond_pickaxe")
      equal(a.inventory[1],nil)
      F.check(a)
    end
  end)

end
