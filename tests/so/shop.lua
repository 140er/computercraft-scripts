local R = dofile("tests/ui/render.lua")
local Scene = dofile("tests/ui/scene.lua")

-- Literal paths, so part runs declare every fixture they read.
local FIXTURE = {
  page = "tests/ui/fixtures/pocket-shoppage-P.txt", low = "tests/ui/fixtures/pocket-shoplow-P.txt",
  qty = "tests/ui/fixtures/pocket-shopqty-P.txt", noroom = "tests/ui/fixtures/pocket-shopnoroom-P.txt",
}
local POCKET = 10

-- The scene's pocket on its SHOP page with a typed search; stock replaces the scene's when given.
local function pocket(search, stock)
  local s = Scene.new({ panel = true, shop = true, facts = true })
  if stock then s.shop.listen.roomsorter_stock(9, { totals = stock }) end
  s.tap(POCKET, "tab:shop")
  if search then s.type(POCKET, search) end
  s.page = function() return s.view(POCKET) end
  s.text = function() return table.concat(Scene.capture(s.page(), 26, 20).picture().text, "\n") end
  s.ids = function()
    local ids = {}
    for _, b in ipairs(s.page().buttons) do ids[b.id] = true end
    return ids
  end
  s.match = function(key)
    local fixture = R.load(FIXTURE[key])
    local diff = R.diff(fixture, Scene.capture(s.page(), fixture.w, fixture.h))
    assert(#diff == 0, key .. "\n" .. table.concat(diff, "\n"))
  end
  return s
end

local function forty()
  local stock = {}
  for i = 1, 40 do stock[string.format("mod:item_%02d", i)] = 810 - i * 20 end
  return stock
end

local function setup(legacy)
  local s = { now = 1000, sends = {}, session = { id = 2 } }
  local env = setmetatable({
    fs = { exists = function() return not legacy end },
    os = { epoch = function() return 72840000 end },
    rednet = {
      send = function(id, body)
        s.sends[#s.sends + 1] = { id = id, body = body }
        return true
      end,
      broadcast = function() end,
    },
    SO = { now = function() return s.now end, mods = { display = {
      screen = function(_, render, input) s.render, s.input = render, input end,
    } } },
  }, { __index = _G })
  s.mod = assert(loadfile("so-mod-shop.lua", "t", env))()
  function s.at(ms)
    s.now = 1000 + ms
    s.mod.listen.roomsorter_stock(9, { totals = { ["minecraft:iron_ingot"] = 64 } })
    s.mod.tick(s.now)
  end
  s.at(0)
  s.input({ session = s.session, id = "item:minecraft:iron_ingot" })
  function s.order()
    s.input({ session = s.session, id = "order:16:minecraft:iron_ingot" })
    return s.sends[#s.sends].body.rid
  end
  function s.reply(rid, text, sender)
    s.mod.listen.roomsorter(sender or 9, { rid = rid, text })
  end
  function s.text()
    local lines = {}
    for _, row in ipairs(s.render(39, 19, s.session).rows) do lines[#lines + 1] = row.text end
    return table.concat(lines, "\n")
  end
  function s.row(status)
    assert(s.text():find("16 " .. status, 1, true), "missing order row: " .. status)
  end
  return s
end

return function(test, equal)
  for _, acknowledgement in ipairs({ "Getting 16 Iron ingot...", "Crafting 16 Iron ingot..." }) do
    test("shop UB-10 delivers after 121 seconds: " .. acknowledgement, function()
      local s = setup()
      local rid = s.order()
      s.reply(rid, acknowledgement)
      s.at(121000)
      s.row("sent")
      s.reply(rid, "Delivered 16 Iron ingot")
      s.row("delivered")
    end)
  end

  test("shop UB-10 acknowledged order fails at 600 seconds without extending on replies", function()
    local s = setup()
    local rid = s.order()
    s.at(100000)
    s.reply(rid, "Getting 16 Iron ingot...")
    s.at(599999)
    s.reply(rid, "Crafting 16 Iron ingot...")
    s.row("sent")
    s.at(600000)
    s.row("failed")
    for _, reply in ipairs({ "Delivered 16 Iron ingot", "Getting 16 Iron ingot...", "Refused order" }) do
      s.reply(rid, reply)
      s.row("failed")
    end
  end)

  test("shop UB-10 accepts refusal after an acknowledgement and 121 seconds", function()
    local s = setup()
    local rid = s.order()
    s.reply(rid, "Getting 16 Iron ingot...")
    s.at(121000)
    s.reply(rid, "Refused order")
    s.row("failed")
    s.reply(rid, "Delivered 16 Iron ingot")
    s.row("failed")
  end)

  test("shop UB-10 reports no delivery after the acknowledged deadline", function()
    local s = setup(true)
    local rid = s.order()
    s.reply(rid, "Getting 16 Iron ingot...")
    s.at(600000)
    assert(s.text():find("Order: no delivery", 1, true))
    s.reply(rid, "Delivered 16 Iron ingot")
    assert(s.text():find("Order: no delivery", 1, true))
  end)

  test("shop UB-10 unacknowledged order still fails at 120 seconds", function()
    local s = setup()
    local rid = s.order()
    s.at(119999)
    s.row("sent")
    s.reply(rid, "Getting 16 Iron ingot...", 10)
    s.reply(rid + 1000, "Getting 16 Iron ingot...")
    s.at(120000)
    s.row("failed")
    s.reply(rid, "Delivered 16 Iron ingot")
    s.row("failed")
  end)
  test("shop P-U2-1 orders an exact count up to one stack; over the cap sends nothing", function()
    local s = setup()
    s.mod.listen.roomsorter_stock(9, { totals = { ["minecraft:iron_ingot"] = 64, ["minecraft:ender_pearl"] = 20 } })
    local n = #s.sends
    local name, count = s.mod.order("minecraft:iron_ingot", 37)
    equal({ name, count, #s.sends }, { "minecraft:iron_ingot", 37, n + 1 })
    equal({ s.sends[#s.sends].body.cmd, s.sends[#s.sends].body.n }, { "order", 37 })
    for _, bad in ipairs({ 65, 0, -1, 1.5, "37", math.huge }) do
      equal({ s.mod.order("minecraft:iron_ingot", bad) }, { nil, "bad count" })
    end
    equal({ s.mod.stack("minecraft:ender_pearl"), s.mod.stack("minecraft:iron_ingot") }, { 16, 64 })
    equal(select(2, s.mod.order("minecraft:ender_pearl", 16)), 16)
    equal(s.mod.order("minecraft:ender_pearl", 17), nil)
    equal(s.mod.order("minecraft:ender_pearl", 64), nil)
    equal(select(2, s.mod.order("minecraft:ender_pearl", "stack")), 16)
    equal(#s.sends, n + 3)
  end)

  test("shop P-U2-1 the shop screen mutes and refuses chips over the item's stack", function()
    local s = setup()
    s.mod.listen.roomsorter_stock(9, { totals = { ["minecraft:ender_pearl"] = 40 } })
    s.input({ session = s.session, id = "item:minecraft:ender_pearl" })
    local ids = {}
    for _, b in ipairs(s.render(39, 19, s.session).buttons) do ids[b.id] = true end
    assert(ids["order:16:minecraft:ender_pearl"] and not ids["order:64:minecraft:ender_pearl"])
    local n = #s.sends
    s.input({ session = s.session, id = "order:64:minecraft:ender_pearl" })
    equal(#s.sends, n)
  end)

  test("shop P-U2-1 a typed quantity on the pocket sends n=37 once and n over the stack nothing", function()
    local s = pocket("iron 37")
    s.match("qty")
    local n = #s.sends
    s.tap(POCKET, "order:37:minecraft:iron_ingot")
    equal(#s.sends, n + 1)
    equal({ s.sends[#s.sends].body.text, s.sends[#s.sends].body.n }, { "minecraft:iron_ingot", 37 })
    assert(s.text():find("37 IRON INGOT sent", 1, true))
    s.page(); s.panel.tick(0); s.page()
    equal(#s.sends, n + 1, "drawing never orders")
    s.type(POCKET, "iron 65")
    assert(s.text():find("MAX 64", 1, true))
    for id in pairs(s.ids()) do assert(not id:match("^order:%d"), id) end
    s.tap(POCKET, "order:65:minecraft:iron_ingot")
    s.type(POCKET, "pickaxe 2")
    s.tap(POCKET, "order:2:minecraft:iron_pickaxe")
    equal(#s.sends, n + 1)
  end)

  test("shop P-U2-1 a keyboard panel splits a trailing quantity", function()
    local s = Scene.new({ panel = true, shop = true, facts = true })
    local session = { id = 77, keyboard = true, panel = { search = "", page = "main" } }
    local render, input = s.D.screens.panel.render, s.D.screens.panel.input
    input({ session = session, text = "iron 37" })
    local frame = render(26, 20, session)
    local seen
    for _, b in ipairs(frame.buttons) do seen = seen or b.id == "order:37" end
    assert(seen, "ORDER 37 chip")
    local n = #s.sends
    input({ session = session, id = "order:37" })
    equal(#s.sends, n + 1)
    equal({ s.sends[#s.sends].body.text, s.sends[#s.sends].body.n }, { "minecraft:iron_ingot", 37 })
    input({ session = session, text = "iron 99" })
    input({ session = session, id = "order:99" })
    equal(#s.sends, n + 1)
  end)

  test("shop P-U2-3 every item of a 40-item search is reachable at 26x20; a new search resets the page", function()
    local s = pocket("item", forty())
    local seen, count, pages = {}, 0, 0
    repeat
      pages = pages + 1
      for id in pairs(s.ids()) do
        local name = id:match("^pick:(.+)$")
        if name and not seen[name] then seen[name], count = true, count + 1 end
      end
      if pages == 2 then s.match("page") end
      local more = s.text():find(pages .. "/4", 1, true)
      assert(more, "page " .. pages)
      s.tap(POCKET, "next")
    until pages == 4
    equal({ count, pages }, { 40, 4 })
    for _, b in ipairs(s.page().buttons) do
      assert(b.y <= 20 and b.x + b.w - 1 <= 26, b.id)
    end
    assert(s.text():find("4/4", 1, true), "next stops at the last page")
    s.type(POCKET, "item_0")
    assert(not s.text():find("/4", 1, true), "nine matches fit one page")
    s.type(POCKET, "item")
    assert(s.text():find("1/4", 1, true), "a new search starts on page 1")
  end)

  test("shop P-U2-8 status reports found and stale; the pocket says so", function()
    local s = setup()
    equal(s.mod.status(), { found = true, stale = false })
    s.now = s.now + 30000
    equal(s.mod.status(), { found = true, stale = true })
    local p = pocket("iron")
    p.now = p.now + 30000
    assert(p.text():find("stock stale", 1, true))
    assert(p.text():find("IRON INGOT", 1, true), "stale stock still lists")
    local fresh = assert(loadfile("so-mod-shop.lua", "t", p.env))()
    equal(fresh.status(), { found = false, stale = true })
    p.env.SO.mods.shop = fresh
    p.match("noroom")
    for id in pairs(p.ids()) do assert(not id:match("^order:"), id) end
  end)

  test("shop P-U2-9 lows lists empty and low items; empty rows get no order chips", function()
    local s = pocket("iron")
    local names = {}
    for _, item in ipairs(s.shop.lows(10)) do names[#names + 1] = item.name .. "=" .. item.count .. "=" .. item.state end
    equal(names, { "minecraft:iron_bars=0=empty", "minecraft:iron_door=3=low", "minecraft:iron_nugget=5=low" })
    equal(#s.shop.lows(2), 2)
    equal(#s.shop.lows(10, "door"), 1)
    s.tap(POCKET, "show:low")
    s.match("low")
    s.tap(POCKET, "show:empty")
    local ids = s.ids()
    assert(ids["pick:minecraft:iron_bars"], "the empty item is listed")
    s.tap(POCKET, "pick:minecraft:iron_bars")
    for id in pairs(s.ids()) do assert(not id:match("^order:"), id) end
    s.tap(POCKET, "show:all")
    assert(s.ids()["pick:minecraft:gold_ingot"] == nil and s.ids()["pick:minecraft:iron_ingot"])
  end)
end
