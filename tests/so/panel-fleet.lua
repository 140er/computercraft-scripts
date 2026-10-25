-- U4-C2: lost turtles in the panel's ALERTS, the fuel auto row, namespaced shared labels and sending the
-- last order again, on the scene's server (tests/ui/scene.lua) against docs/ui/schematic twins.
local R = dofile("tests/ui/render.lua")
local Scene = dofile("tests/ui/scene.lua")

-- Literal paths, so part runs declare every fixture they read.
local FIXTURE = {
  panelfuel = "tests/ui/fixtures/panelfuel-M.txt", jobsfuel = "tests/ui/fixtures/pocket-jobsfuel-P.txt",
  shopdupe = "tests/ui/fixtures/pocket-shopdupe-P.txt", paneldupe = "tests/ui/fixtures/paneldupe-P.txt",
}
local POCKET = 10
local COPPER = { ["minecraft:copper_ingot"] = 200, ["create:copper_ingot"] = 30 }

local function match(key, frame)
  local fixture = R.load(FIXTURE[key])
  local diff = R.diff(fixture, Scene.capture(frame, fixture.w, fixture.h))
  assert(#diff == 0, key .. "\n" .. table.concat(diff, "\n"))
end

local function text(frame, w, h) return table.concat(Scene.capture(frame, w, h).picture().text, "\n") end
-- Row y's cells from x for n cells, and its value after the leader dots.
local function cells(frame, w, h, y, x, n)
  return table.concat(Scene.chars(Scene.capture(frame, w, h).picture().text[y]), "", x, x + n - 1)
end
local function fuel(frame, w, h)
  for _, row in ipairs(Scene.capture(frame, w, h).picture().text) do
    local value = row:match("^ fuel auto [^%w]*(.-)%s*$")
    if value then return value end
  end
end

local function button(frame, id, y)
  for _, b in ipairs(frame.buttons) do if b.id == id and (not y or b.y == y) then return b end end
end

-- The scene's sends of one cmd ("order"), as id and count.
local function orders(s)
  local out = {}
  for _, m in ipairs(s.sends) do
    if type(m.body) == "table" and m.body.cmd == "order" then out[#out + 1] = m.body.text .. "=" .. m.body.n end
  end
  return out
end

return function(test, equal)
  test("panel P-U2-7 two lost leases give two ALERTS rows, and N lost opens them", function()
    local s = Scene.new({ panel = true, alert = true })
    local status = s.env.SO.mods.lease.status
    s.env.SO.mods.lease.status = function(id)
      if id == 3 then return { lost = true } end
      return status(id)
    end
    s.panel.tick(0)
    s.d.handlers.hello({ from = 21, body = { w = 57, h = 24 } })
    assert(s.d.assign(21, "panel"))
    local main = s.view(21)
    local hit = assert(button(main, "alerts", 3), "N lost is a control")
    equal(cells(main, 57, 24, 3, hit.x, hit.w), "2 lost")
    s.tap(21, "alerts")
    local rows = text(s.view(21), 57, 24)
    local a, b, c = rows:find("#3 lost", 1, true), rows:find("#6 lost", 1, true), rows:find(s.sys.alert.text, 1, true)
    assert(a and b and c and a < b and b < c, rows)
    assert(rows:find("ALERTS %-+ 3"), rows)
    -- The pocket's FLEET flags count the same lost turtles.
    s.view(POCKET)
    local lost = 0
    for _, f in ipairs(s.d.statusModel().flags) do if f.text:match("^#%d+ lost$") then lost = lost + 1 end end
    equal(lost, 2)
  end)

  test("panel P-U2-10 the fuel auto row reads shop.fuelConfig: off, on, waiting and timed out", function()
    local s = Scene.new({ panel = true, shop = true, facts = true })
    s.d.handlers.hello({ from = 21, body = { w = 57, h = 24 } })
    assert(s.d.assign(21, "panel"))
    equal(fuel(s.view(21), 57, 24), nil, "no row before fuel auto is set up")
    assert(s.shop.fuelConfig(true))
    equal(fuel(s.view(21), 57, 24), "on")
    assert(s.shop.fuelConfig(false))
    equal(fuel(s.view(21), 57, 24), nil, "off without an output point is not set up")
    assert(s.shop.fuelConfig(nil, 2))
    equal(fuel(s.view(21), 57, 24), "off")
    local policy
    s.shop.fuelConfig = function() return policy end
    policy = { auto = true, alert = { reason = "fuel order timed out", text = "Fuel fuel order timed out #3" } }
    match("panelfuel", s.view(21))
    policy = { auto = true, waiting = { at = s.now - 125000, rid = 1, sender = 9 } }
    equal(fuel(s.view(21), 57, 24), "timed out", "a waiting order past two minutes")
    policy = { auto = true, waiting = { at = s.now - 45000, rid = 1, sender = 9 } }
    s.tap(POCKET, "tab:jobs")
    match("jobsfuel", s.view(POCKET))
  end)

  test("panel P-U2-4 two ids sharing a label show their namespace and each orders its own id", function()
    local s = Scene.new({ panel = true, shop = true, facts = true })
    s.shop.listen.roomsorter_stock(9, { totals = COPPER })
    s.tap(POCKET, "tab:shop")
    s.type(POCKET, "copper")
    s.tap(POCKET, "pick:create:copper_ingot")
    match("shopdupe", s.view(POCKET))
    s.tap(POCKET, "order:1:create:copper_ingot")
    s.tap(POCKET, "pick:minecraft:copper_ingot")
    s.tap(POCKET, "order:1:minecraft:copper_ingot")
    equal(orders(s), { "create:copper_ingot=1", "minecraft:copper_ingot=1" })
  end)

  test("panel P-U2-13 the last order line sends the same count again, capped at one stack", function()
    local s = Scene.new({ panel = true, shop = true, facts = true })
    s.tap(POCKET, "tab:shop")
    s.type(POCKET, "iron")
    s.tap(POCKET, "order:16:minecraft:iron_ingot")
    assert(button(s.view(POCKET), "order:16:minecraft:iron_ingot", 19), "the order line is a control")
    s.tap(POCKET, "pick:minecraft:raw_iron")
    s.tap(POCKET, "order:16:minecraft:raw_iron")
    s.d.handlers.input({ from = POCKET, body = { id = "order:16:minecraft:raw_iron", x = 2, y = 19 } })
    equal(orders(s), { "minecraft:iron_ingot=16", "minecraft:raw_iron=16", "minecraft:raw_iron=16" })
    -- The pickaxe stacks to 1: a forged 64 sends nothing.
    s.d.handlers.input({ from = POCKET, body = { id = "order:64:minecraft:iron_pickaxe", x = 2, y = 19 } })
    equal(#orders(s), 3)

    -- The panel role on the pocket: the shown item's id, then its line again after a new search.
    local p = Scene.new({ panel = true, shop = true, facts = true })
    p.shop.listen.roomsorter_stock(9, { totals = COPPER })
    assert(p.d.assign(POCKET, "panel"))
    p.type(POCKET, "create:copper")
    p.tap(POCKET, "order:16")
    match("paneldupe", p.view(POCKET))
    assert(button(p.view(POCKET), "order:16:create:copper_ingot", 15), "the panel's order line is a control")
    p.type(POCKET, "iron")
    p.tap(POCKET, "order:16:create:copper_ingot")
    p.d.handlers.input({ from = POCKET, body = { id = "order:99:create:copper_ingot", x = 2, y = 15 } })
    equal(orders(p), { "create:copper_ingot=16", "create:copper_ingot=16" })
  end)
end
