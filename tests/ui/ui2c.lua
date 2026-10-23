-- Shop storage browser: fixtures, category table, browsing, search and orders.
local R = dofile("tests/ui/render.lua")
local NOW = 72840000 -- 21:14 in Amsterdam
local SIZES = { { 57, 24 }, { 39, 19 }, { 26, 20 }, { 29, 12 }, { 100, 38 } }

local function setup(kit)
  local s = { now = NOW, sends = {} }
  local env = setmetatable({
    fs = { exists = function() return kit ~= false end },
    os = { epoch = function() return s.now end },
    rednet = {
      send = function(id, body, protocol) s.sends[#s.sends + 1] = { id = id, body = body, protocol = protocol } end,
      broadcast = function() end,
    },
    SO = { now = function() return s.now end, mods = { display = { screen = function(_, render, input)
      s.render, s.input = render, input end } } },
  }, { __index = _G })
  s.mod = assert(loadfile("so-mod-shop.lua", "t", env))()
  s.mod.tick(s.now)
  for i = 1, 30 do
    local name, value = debug.getupvalue(s.render, i)
    if name == "S" then s.S = value break end
  end
  return s
end

-- The mockup stock: id, count, history, stack, category/sub; plus recent orders and recipes.
local function stock()
  local data = { items = {}, orders = {}, recipes = {} }
  for line in io.lines("tests/ui/shop-stock.tsv") do
    local f = {}
    for field in line:gmatch("[^\t]+") do f[#f + 1] = field end
    if f[1] == "order" then
      data.orders[#data.orders + 1] = { hm = f[3], n = tonumber(f[4]), status = f[5] }
    elseif f[1] == "recipe" then
      data.recipes[#data.recipes + 1] = { name = f[2], can = tonumber(f[3]) }
    elseif not line:match("^#") then
      local samples = {}
      for value in f[3]:gmatch("[^,]+") do samples[#samples + 1] = tonumber(value) end
      if #samples == 1 then
        for i = 2, 59 do samples[i] = samples[1] end
        samples[60] = tonumber(f[2])
      end
      data.items[#data.items + 1] = { name = f[1], count = tonumber(f[2]), samples = samples,
        stack = tonumber(f[4]), kind = f[5] }
    end
  end
  return data
end

local function loaded()
  local s, data = setup(), stock()
  local totals, stacks = {}, {}
  for _, item in ipairs(data.items) do
    if item.count > 0 then totals[item.name] = item.count end
    stacks[item.name] = item.stack
  end
  s.mod.listen.roomsorter_stock(9, { totals = totals, stacks = stacks })
  s.mod.tick(s.now)
  s.mod.listen.roomsorter(9, { rid = s.sends[#s.sends].body.rid, totals = totals, recipes = data.recipes })
  s.S.history = {}
  for _, item in ipairs(data.items) do s.S.history[item.name] = item.samples end
  s.S.recent["minecraft:iron_ingot"] = data.orders
  s.data = data
  return s
end

local function capture(frame, w, h)
  local out = R.capture(w, h)
  assert(#frame.rows == h)
  for y, row in ipairs(frame.rows) do
    local fg, bg = {}, {}
    for _, run in ipairs(row.runs) do
      fg[#fg + 1] = string.rep(run[2], run[1]); bg[#bg + 1] = string.rep(run[3], run[1])
    end
    fg, bg = table.concat(fg), table.concat(bg)
    assert(#fg == w and #bg == w and #row.text <= w)
    out.setCursorPos(1, y); out.blit(row.text .. string.rep(" ", w - #row.text), fg, bg)
  end
  for i, b in ipairs(frame.buttons) do
    assert(b.x >= 1 and b.y >= 1 and b.w > 0 and b.h > 0 and b.x + b.w - 1 <= w and b.y + b.h - 1 <= h, b.id)
    for j = i + 1, #frame.buttons do
      local o = frame.buttons[j]
      assert(b.x + b.w <= o.x or o.x + o.w <= b.x or b.y + b.h <= o.y or o.y + o.h <= b.y,
        "overlap " .. b.id .. " " .. o.id)
    end
  end
  return out
end

local function contrast(out)
  for _, row in ipairs(out.cells) do
    for _, cell in ipairs(row) do
      local fg, bg = cell[2], cell[3]
      if cell[1]:byte() >= 128 and cell[1]:byte() <= 159 and bg == "f" and fg ~= "0" and fg ~= "8" then fg, bg = bg, fg end
      assert((bg == "f" or bg == "7" or bg == "c") and (fg == "0" or fg == "8") or
        (bg == "d" or bg == "1" or bg == "e" or bg == "b" or bg == "a" or bg == "9" or bg == "0") and fg == "f",
        "contrast " .. fg .. "/" .. bg)
    end
  end
end

local function ids(frame, pattern)
  local out = {}
  for _, b in ipairs(frame.buttons) do
    local got = b.id:match(pattern)
    if got then out[#out + 1] = got end
  end
  return out
end

local function has(frame, id)
  for _, b in ipairs(frame.buttons) do if b.id == id then return b end end
end

local function text(frame)
  local lines = {}
  for _, row in ipairs(frame.rows) do lines[#lines + 1] = row.text end
  return table.concat(lines, "\n")
end

-- Taps a drawn button by id, as the display module would forward it.
local function tap(s, w, h, id, session)
  session = session or { id = 2 }
  local b = has(s.render(w, h, session), id)
  assert(b, "missing button " .. id .. " at " .. w .. "x" .. h)
  s.input({ id = id, x = b.x, y = b.y, session = session })
end

local PAGES = {
  home = {},
  list = { "cat:ores" },
  item = { "cat:ores", "item:minecraft:iron_ingot", "order:16:minecraft:iron_ingot", "reply" },
  find = { "search", "key:I", "key:R", "key:O", "key:N" },
  results = { "search", "key:I", "key:R", "key:O", "key:N", "found" },
  low = { "low", "sort:trend" },
  mods = { "cat:mods", "sort:name" },
}

local function scene(page, w, h)
  local s = loaded()
  for _, id in ipairs(PAGES[page]) do
    if id == "reply" then
      s.mod.listen.roomsorter(9, { rid = s.sends[#s.sends].body.rid, "Getting 16 Iron ingot..." })
    else tap(s, w, h, id) end
  end
  return s, s.render(w, h, { id = 2 })
end

return function(test, equal)
  test("UI2c every shop page matches its fixture at every size", function()
    for _, case in ipairs({
      { "tests/ui/fixtures/shop-home-57x24.txt", "home", 57, 24 },
      { "tests/ui/fixtures/shop-home-39x19.txt", "home", 39, 19 },
      { "tests/ui/fixtures/shop-home-26x20.txt", "home", 26, 20 },
      { "tests/ui/fixtures/shop-home-29x12.txt", "home", 29, 12 },
      { "tests/ui/fixtures/shop-home-100x38.txt", "home", 100, 38 },
      { "tests/ui/fixtures/shop-list-57x24.txt", "list", 57, 24 },
      { "tests/ui/fixtures/shop-list-39x19.txt", "list", 39, 19 },
      { "tests/ui/fixtures/shop-list-26x20.txt", "list", 26, 20 },
      { "tests/ui/fixtures/shop-list-29x12.txt", "list", 29, 12 },
      { "tests/ui/fixtures/shop-list-100x38.txt", "list", 100, 38 },
      { "tests/ui/fixtures/shop-item-57x24.txt", "item", 57, 24 },
      { "tests/ui/fixtures/shop-item-39x19.txt", "item", 39, 19 },
      { "tests/ui/fixtures/shop-item-26x20.txt", "item", 26, 20 },
      { "tests/ui/fixtures/shop-item-29x12.txt", "item", 29, 12 },
      { "tests/ui/fixtures/shop-item-100x38.txt", "item", 100, 38 },
      { "tests/ui/fixtures/shop-find-57x24.txt", "find", 57, 24 },
      { "tests/ui/fixtures/shop-find-39x19.txt", "find", 39, 19 },
      { "tests/ui/fixtures/shop-find-26x20.txt", "find", 26, 20 },
      { "tests/ui/fixtures/shop-find-29x12.txt", "find", 29, 12 },
      { "tests/ui/fixtures/shop-find-100x38.txt", "find", 100, 38 },
      { "tests/ui/fixtures/shop-results-57x24.txt", "results", 57, 24 },
      { "tests/ui/fixtures/shop-results-39x19.txt", "results", 39, 19 },
      { "tests/ui/fixtures/shop-results-26x20.txt", "results", 26, 20 },
      { "tests/ui/fixtures/shop-low-57x24.txt", "low", 57, 24 },
      { "tests/ui/fixtures/shop-mods-57x24.txt", "mods", 57, 24 },
    }) do
      local _, frame = scene(case[2], case[3], case[4])
      local diff = R.diff(case[1], capture(frame, case[3], case[4]))
      assert(#diff == 0, case[1] .. "\n" .. table.concat(diff, "\n"))
    end
  end)

  test("UI2c category table sorts real item ids", function()
    local s = setup()
    for _, item in ipairs(stock().items) do
      local cat, sub = s.S.kind(item.name)
      equal(cat .. "/" .. sub, item.kind, item.name)
    end
    for name, kind in pairs({
      ["minecraft:nether_quartz_ore"] = "ores/ore", ["minecraft:deepslate_diamond_ore"] = "ores/ore",
      ["minecraft:ancient_debris"] = "ores/ore", ["minecraft:raw_gold_block"] = "ores/block",
      ["minecraft:diamond_block"] = "ores/block", ["minecraft:quartz_block"] = "stone/build",
      ["minecraft:netherite_ingot"] = "ores/ingot", ["minecraft:glowstone_dust"] = "ores/dust",
      ["minecraft:redstone_block"] = "redstone/dust", ["minecraft:oak_button"] = "redstone/logic",
      ["minecraft:powered_rail"] = "redstone/motion", ["minecraft:sticky_piston"] = "redstone/motion",
      ["minecraft:golden_pickaxe"] = "tools/tools", ["minecraft:netherite_boots"] = "tools/armour",
      ["minecraft:spectral_arrow"] = "tools/weapons", ["minecraft:water_bucket"] = "tools/tools",
      ["minecraft:golden_apple"] = "food/meals", ["minecraft:cooked_salmon"] = "food/meals",
      ["minecraft:sweet_berries"] = "food/crops", ["minecraft:salmon"] = "food/meat",
      ["minecraft:stripped_oak_log"] = "wood/log", ["minecraft:crimson_stem"] = "wood/log",
      ["minecraft:mangrove_propagule"] = "wood/sapling", ["minecraft:dark_oak_door"] = "wood/crafted",
      ["minecraft:spruce_stairs"] = "wood/crafted", ["minecraft:cherry_leaves"] = "plants/leaves",
      ["minecraft:crimson_roots"] = "plants/plants", ["minecraft:red_tulip"] = "plants/flowers",
      ["minecraft:pumpkin_seeds"] = "plants/seeds", ["minecraft:short_grass"] = "plants/plants",
      ["minecraft:grass_block"] = "stone/earth", ["minecraft:warped_nylium"] = "stone/earth",
      ["minecraft:smooth_sandstone"] = "stone/stone", ["minecraft:crying_obsidian"] = "stone/stone",
      ["minecraft:stone_brick_stairs"] = "stone/build", ["minecraft:red_stained_glass"] = "stone/build",
      ["minecraft:lime_concrete_powder"] = "stone/build", ["minecraft:cobblestone_slab"] = "stone/build",
      ["minecraft:glass_bottle"] = "other/other", ["minecraft:ender_pearl"] = "mobs/hostile",
      ["minecraft:wither_skeleton_skull"] = "mobs/hostile", ["minecraft:glow_ink_sac"] = "mobs/passive",
      ["minecraft:armadillo_scute"] = "mobs/passive", ["minecraft:blaze_powder"] = "mobs/hostile",
      ["thermal:tin_ingot"] = "ores/ingot", ["mekanism:ingot_steel"] = "ores/ingot",
      ["create:crushed_raw_zinc"] = "mods/create", ["ae2:sky_stone_block"] = "mods/ae2",
      cobblestone = "stone/stone",
    }) do
      local cat, sub = s.S.kind(name)
      equal(cat .. "/" .. sub, kind, name)
    end
    s.mod.listen.roomsorter_stock(9, { totals = { ["farmersdelight:tomato"] = 3, ["ae2:silicon"] = 2 },
      tags = { ["farmersdelight:tomato"] = { "c:crops/tomato", "c:foods" }, ["ae2:silicon"] = { "ae2:misc" } } })
    equal({ s.S.kind("farmersdelight:tomato") }, { "food", "crops" })
    equal({ s.S.kind("ae2:silicon") }, { "mods", "ae2" })
    equal(#s.S.cats, 10)
  end)

  test("UI2c home totals, low and empty counts follow the stock", function()
    local s = loaded()
    local rows = s.S.summary(s.S.gather({ id = 2 }))
    local byId = {}
    for _, row in ipairs(rows) do byId[row.id] = row end
    equal(byId["cat:ores"].items, 25)
    equal(byId["cat:stone"].total, 19199)
    equal(byId.low.items, 21)
    equal(byId.empty.items, 4)
    local total = 0
    for _, item in ipairs(s.data.items) do total = total + item.count end
    local sum = 0
    for _, row in ipairs(rows) do sum = sum + (row.total or 0) end
    equal(sum, total)
  end)

  test("UI2c sort by count, name and trend and page through every item once", function()
    local s = loaded()
    local w, h = 39, 19
    tap(s, w, h, "all")
    for _, sort in ipairs({ "count", "name", "trend" }) do
      tap(s, w, h, "sort:" .. sort)
      local seen, order = {}, {}
      for page = 1, 20 do
        local frame = s.render(w, h, { id = 2 })
        for _, name in ipairs(ids(frame, "^item:(.+)$")) do
          assert(not seen[name], name); seen[name] = true; order[#order + 1] = name
        end
        if not has(frame, "next") or page == 20 then break end
        local before = text(frame)
        tap(s, w, h, "next")
        if text(s.render(w, h, { id = 2 })) == before then break end
      end
      equal(#order, #s.data.items, sort)
      local items = {}
      for _, item in ipairs(s.S.gather({ id = 2 }).all) do items[item.name] = item end
      for i = 2, #order do
        local a, b = items[order[i - 1]], items[order[i]]
        if sort == "count" then assert(a.count >= b.count, order[i])
        elseif sort == "name" then assert(a.label:lower() <= b.label:lower(), order[i])
        else assert(math.abs(a.rate) >= math.abs(b.rate), order[i]) end
      end
      for _ = 1, 20 do tap(s, w, h, "prev") end
      equal(s.S.view({ id = 2 }).page, 1)
    end
    tap(s, w, h, "back")
    tap(s, w, h, "cat:ores")
    tap(s, w, h, "sub:ingot")
    local names = ids(s.render(w, h, { id = 2 }), "^item:(.+)$")
    equal(#names, 6)
    for _, name in ipairs(names) do equal(select(2, s.S.kind(name)), "ingot") end
  end)

  test("UI2c search by keypad and by keyboard covers every category", function()
    local s = loaded()
    tap(s, 26, 20, "search")
    for _, key in ipairs({ "I", "R", "O", "N", "X", "DEL" }) do tap(s, 26, 20, "key:" .. key) end
    equal(s.S.view({ id = 2 }).search, "iron")
    assert(text(s.render(26, 20, { id = 2 })):find("14 FOUND", 1, true))
    tap(s, 26, 20, "found")
    local cats = {}
    local m = s.S.gather({ id = 2 })
    equal(#m.items, 14)
    for _, item in ipairs(m.items) do cats[item.cat] = true; assert(item.name:find("iron", 1, true)) end
    assert(cats.ores and cats.tools)
    tap(s, 26, 20, "back")
    equal(s.S.view({ id = 2 }).screen, "search")
    tap(s, 26, 20, "key:CLR")
    equal(s.S.view({ id = 2 }).search, "")
    s.input({ text = "copper ingot", session = { id = 2 } })
    m = s.S.gather({ id = 2 })
    equal(#m.items, 1); equal(m.items[1].name, "minecraft:copper_ingot")
    s.input({ text = "*", session = { id = 2 } })
    equal(#s.S.gather({ id = 2 }).items, #s.data.items)
    s.input({ text = "Basic Control", session = { id = 3 } })
    equal(s.S.gather({ id = 3 }).items[1].name, "mekanism:basic_control_circuit")
    equal(#s.S.gather({ id = 2 }).items, #s.data.items, "searches belong to each display")
  end)

  test("UI2c one tap sends one order for 1, 16, 64, a stack and all", function()
    for _, case in ipairs({ { "1", 1 }, { "16", 16 }, { "64", 64 }, { "stack", 16 }, { "all", 6 } }) do
      local s = loaded()
      tap(s, 57, 24, "cat:mobs")
      tap(s, 57, 24, "item:minecraft:ender_pearl")
      local n = #s.sends
      local id = "order:" .. case[1] .. ":minecraft:ender_pearl"
      local button = has(s.render(57, 24, { id = 2 }), id)
      assert(button and button.h == 3, id)
      s.input({ id = id, x = button.x, y = button.y, session = { id = 2 } })
      for _ = 1, 3 do s.render(57, 24, { id = 2 }) end
      equal(#s.sends, n + 1)
      local sent = s.sends[#s.sends]
      equal(sent.id, 9); equal(sent.protocol, "roomsorter")
      equal(sent.body.cmd, "order"); equal(sent.body.text, "minecraft:ender_pearl"); equal(sent.body.n, case[2])
      s.input({ id = id, x = button.x, y = button.y, session = { id = 2 } })
      equal(#s.sends, n + 2, "a second tap is a second order")
      s.input({ id = id, session = { id = 3 } })
      equal(#s.sends, n + 2, "another display has not opened the item")
      assert(text(s.render(57, 24, { id = 2 })):find("Order: sent " .. case[2], 1, true))
      local recent = s.S.recent["minecraft:ender_pearl"]
      equal(#recent, 2); equal(recent[1].hm, "21:14"); equal(recent[1].n, case[2])
      tap(s, 57, 24, "items")
      equal(s.S.view({ id = 2 }).screen, "list")
    end
    local s = loaded()
    tap(s, 57, 24, "empty")
    tap(s, 57, 24, "item:minecraft:quartz")
    local frame = s.render(57, 24, { id = 2 })
    assert(not has(frame, "order:all:minecraft:quartz") and has(frame, "order:16:minecraft:quartz"))
    local n = #s.sends
    s.input({ id = "order:all:minecraft:quartz", session = { id = 2 } })
    s.input({ id = "order:2:minecraft:quartz", session = { id = 2 } })
    equal(#s.sends, n)
  end)

  test("UI2c order replies update the page and the recent list", function()
    local s = loaded()
    tap(s, 26, 20, "cat:ores"); tap(s, 26, 20, "item:minecraft:iron_ingot")
    tap(s, 26, 20, "order:64:minecraft:iron_ingot")
    local rid = s.sends[#s.sends].body.rid
    s.mod.listen.roomsorter(9, { rid = rid, "Delivered 64 Iron ingot" })
    assert(text(s.render(26, 20, { id = 2 })):find("Order: delivered", 1, true))
    equal(s.S.recent["minecraft:iron_ingot"][1].status, "delivered")
    tap(s, 26, 20, "order:1:minecraft:iron_ingot")
    s.now = s.now + 120001; s.mod.tick(s.now)
    assert(text(s.render(26, 20, { id = 2 })):find("failed, timed out", 1, true))
    equal(s.S.recent["minecraft:iron_ingot"][1].status, "failed")
  end)

  test("UI2c shop.matches, shop.best and shop.order change no screen state", function()
    local s = setup()
    equal({ s.mod.order("iron", 16) }, { nil, "no match" })
    s.mod.listen.roomsorter_stock(9, { totals = { iron_b = 64, iron_a = 64, iron_c = 16, gold = 1000 },
      labels = { gold = "Shiny Metal" } })
    s.input({ text = "gold", session = { id = 2 } })
    tap(s, 57, 24, "item:gold")
    local before = s.render(57, 24, { id = 2 })
    local names = {}
    for _, item in ipairs(s.mod.matches("IRON", 2)) do names[#names + 1] = item.name .. "=" .. item.count end
    equal(names, { "iron_a=64", "iron_b=64" })
    equal(s.mod.matches("shiny", 5)[1], { name = "gold", count = 1000, label = "SHINY METAL" })
    equal({ s.mod.best("IRON") }, { "iron_a", 64 })
    equal({ s.mod.best("iron_c") }, { "iron_c", 16 })
    equal(s.mod.order("IRON", 16), "iron_a")
    equal(s.mod.order("iron_c", 64), "iron_c")
    equal(#s.sends, 2); equal(s.sends[1].body.text, "iron_a"); equal(s.sends[2].body.n, 64)
    equal(s.render(57, 24, { id = 2 }), before)
    for _, case in ipairs({ { "missing", 16 }, { "iron", 0 }, { "iron", 5 }, { false, 16 }, { "iron", "16" } }) do
      equal(s.mod.order(case[1], case[2]), nil)
    end
    equal(#s.sends, 2)
  end)

  test("UI2c every page stays inside bounds with readable contrast at odd sizes", function()
    for _, size in ipairs({ { 57, 24 }, { 39, 19 }, { 26, 20 }, { 29, 12 }, { 100, 38 }, { 15, 10 }, { 36, 10 },
        { 51, 19 }, { 164, 81 }, { 4, 5 }, { 1, 1 } }) do
      local w, h = size[1], size[2]
      for page in pairs(PAGES) do
        local s = loaded()
        for _, id in ipairs(PAGES[page]) do
          if id == "reply" then s.mod.listen.roomsorter(9, { rid = s.sends[#s.sends].body.rid, "Getting 16" })
          else s.input({ id = id, session = { id = 2 } }) end
        end
        local frame = s.render(w, h, { id = 2 })
        local out = capture(frame, w, h)
        if w >= 15 then
          contrast(out)
          assert(#frame.buttons > 0, page .. " " .. w .. "x" .. h)
          assert(text(frame):find(page == "item" and "IRON" or page == "find" and "FIND" or "%u"))
        end
      end
    end
  end)

  test("UI2c narrow screens keep item rows and move paging to its own row", function()
    for _, size in ipairs({ { 15, 10 }, { 15, 6 }, { 19, 8 } }) do
      local w, h = size[1], size[2]
      local s = loaded()
      s.input({ id = "all", session = { id = 2 } })
      local frame = s.render(w, h, { id = 2 })
      capture(frame, w, h)
      assert(#ids(frame, "^item:(.+)$") > 0, "no rows at " .. w .. "x" .. h)
      equal(has(frame, "back").y, h - 1)
      equal(has(frame, "next").y, h)
      s.input({ id = "back", session = { id = 2 } })
      frame = s.render(w, h, { id = 2 })
      capture(frame, w, h)
      equal(has(frame, "all").y, h - 1)
      equal(has(frame, "prev").y, h)
    end
  end)

  test("UI2c stale, lost and empty stock stay visible", function()
    local s = setup()
    assert(text(s.render(29, 12, { id = 2 })):find("Storage room not found", 1, true))
    s.mod.listen.roomsorter_stock(9, { totals = { ["minecraft:iron_ingot"] = 64 } })
    tap(s, 29, 12, "all")
    s.now = s.now + 30000
    assert(text(s.render(29, 12, { id = 2 })):find("STALE STOCK", 1, true))
    tap(s, 29, 12, "item:minecraft:iron_ingot")
    assert(text(s.render(29, 12, { id = 2 })):find("STALE STOCK", 1, true))
    s.S.sampleAt = nil
    s.S.history = { ["minecraft:iron_ingot"] = { 64 }, ["minecraft:quartz"] = { 20, 0 } }
    s.S.totals["minecraft:quartz"] = nil
    equal(s.S.gather({ id = 2 }).selected.count, 64)
    local states = {}
    for _, item in ipairs(s.S.gather({ id = 2 }).all) do states[item.name] = item.state end
    equal(states["minecraft:quartz"], "empty")
    s.S.history["minecraft:quartz"] = { 0 }
    s.S.sample(s.now)
    equal(s.S.history["minecraft:quartz"], nil, "an hour without stock forgets the item")
    s.now = s.now + 300000; s.mod.tick(s.now)
    tap(s, 29, 12, "back")
    assert(text(s.render(29, 12, { id = 2 })):find("Storage room not found", 1, true))
  end)

  test("UI2c roomsorter labels, stacks and tags are optional additions", function()
    local s = setup()
    s.mod.listen.roomsorter_stock(9, { totals = { ["minecraft:ender_pearl"] = 20, ["create:brass_ingot"] = 3,
      ["minecraft:iron_sword"] = 2 } })
    local items = {}
    for _, item in ipairs(s.S.gather({ id = 2 }).all) do items[item.name] = item end
    equal(items["minecraft:ender_pearl"].stack, 16)
    equal(items["minecraft:iron_sword"].stack, 1)
    equal(items["create:brass_ingot"].label, "Brass Ingot")
    s.mod.listen.roomsorter_stock(9, { totals = { ["create:brass_ingot"] = 3 },
      labels = { ["create:brass_ingot"] = "Brass Bar", [5] = "x" }, stacks = { ["create:brass_ingot"] = 32, bad = 99 },
      tags = { ["create:brass_ingot"] = { "c:ingots/brass", 7 } } })
    items = {}
    for _, item in ipairs(s.S.gather({ id = 2 }).all) do items[item.name] = item end
    equal(items["create:brass_ingot"].label, "Brass Bar")
    equal(items["create:brass_ingot"].stack, 32)
    equal(s.S.tags["create:brass_ingot"], { "c:ingots/brass" })
    equal(s.S.stacks.bad, nil)
  end)
end
