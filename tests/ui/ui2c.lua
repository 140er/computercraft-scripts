-- Shop in route A: fixtures at every size, the category table, browsing, search and orders.
-- The stock comes from tests/ui/shop-stock.tsv, which docs/ui/schematic/shop.py also reads.
local R = dofile("tests/ui/render.lua")
local NOW = 72840000 -- 21:14 in Amsterdam
local WIDE = 52

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
  s.mod, s.env = assert(loadfile("so-mod-shop.lua", "t", env))(), env
  s.mod.tick(s.now)
  for i = 1, 30 do
    local name, value = debug.getupvalue(s.render, i)
    if name == "S" then s.S = value break end
  end
  return s
end

-- The scene stock: id, count, history, stack, category/sub; plus recent orders and recipes.
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

-- The route A contrast rule (docs/ui/SCHEMATIC-SPEC.md section 3) on every cell.
local STRUCTURE = { ["-"] = true, ["|"] = true, ["+"] = true, ["\183"] = true, ["\166"] = true }
local DARK = { ["0"] = true, ["3"] = true, ["8"] = true, ["9"] = true, d = true, ["1"] = true, e = true, b = true,
  a = true, ["2"] = true }
local function contrast(out, name)
  for y, row in ipairs(out.cells) do
    for x, cell in ipairs(row) do
      local ch, fg, bg = cell[1], cell[2], cell[3]
      local ok = ch == " " or (bg == "f" or bg == "7") and (DARK[fg] or fg == "c" and STRUCTURE[ch])
        or bg == "c" and (fg == "0" or fg == "3") or bg ~= "f" and bg ~= "7" and bg ~= "c" and fg == "f"
      assert(ok, string.format("%s contrast %s on %s at %d,%d (%q)", name, fg, bg, x, y, ch))
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

-- The taps that reach each fixture page; narrow screens open the category picker first.
local PAGES = {
  browse = { "cat:ores" },
  item = { "cat:ores", "item:minecraft:iron_ingot", "order:16:minecraft:iron_ingot", "reply" },
  low = { "tab:low" },
  find = { "tab:find", "key:I", "key:R", "key:O", "key:N" },
  pick = { "cat:ores", "pick:cats" },
}

local function scene(page, w, h)
  local s = loaded()
  for _, id in ipairs(PAGES[page]) do
    if id == "reply" then
      s.mod.listen.roomsorter(9, { rid = s.sends[#s.sends].body.rid, "Getting 16 Iron ingot..." })
    else
      if id:match("^cat:") and w < WIDE then tap(s, w, h, "pick:cats") end
      tap(s, w, h, id)
    end
  end
  return s, s.render(w, h, { id = 2 })
end

-- Literal paths, so part runs declare every fixture they read.
local FIXTURES = {
  { "tests/ui/fixtures/shop-browse-57x24.txt", "browse", 57, 24 },
  { "tests/ui/fixtures/shop-browse-39x19.txt", "browse", 39, 19 },
  { "tests/ui/fixtures/shop-browse-100x38.txt", "browse", 100, 38 },
  { "tests/ui/fixtures/shop-browse-29x12.txt", "browse", 29, 12 },
  { "tests/ui/fixtures/shop-browse-26x20.txt", "browse", 26, 20 },
  { "tests/ui/fixtures/shop-item-57x24.txt", "item", 57, 24 },
  { "tests/ui/fixtures/shop-item-39x19.txt", "item", 39, 19 },
  { "tests/ui/fixtures/shop-item-100x38.txt", "item", 100, 38 },
  { "tests/ui/fixtures/shop-item-29x12.txt", "item", 29, 12 },
  { "tests/ui/fixtures/shop-item-26x20.txt", "item", 26, 20 },
  { "tests/ui/fixtures/shop-low-57x24.txt", "low", 57, 24 },
  { "tests/ui/fixtures/shop-low-39x19.txt", "low", 39, 19 },
  { "tests/ui/fixtures/shop-low-100x38.txt", "low", 100, 38 },
  { "tests/ui/fixtures/shop-low-29x12.txt", "low", 29, 12 },
  { "tests/ui/fixtures/shop-low-26x20.txt", "low", 26, 20 },
  { "tests/ui/fixtures/shop-find-57x24.txt", "find", 57, 24 },
  { "tests/ui/fixtures/shop-find-39x19.txt", "find", 39, 19 },
  { "tests/ui/fixtures/shop-find-100x38.txt", "find", 100, 38 },
  { "tests/ui/fixtures/shop-find-29x12.txt", "find", 29, 12 },
  { "tests/ui/fixtures/shop-find-26x20.txt", "find", 26, 20 },
  { "tests/ui/fixtures/shop-pick-39x19.txt", "pick", 39, 19 },
  { "tests/ui/fixtures/shop-pick-29x12.txt", "pick", 29, 12 },
  { "tests/ui/fixtures/shop-pick-26x20.txt", "pick", 26, 20 },
  -- The Big Tiles names, kept because test files are never deleted, now hold route A pages.
  { "tests/ui/fixtures/shop-M.txt", "browse", 57, 24 },
  { "tests/ui/fixtures/shoporder-M.txt", "item", 57, 24 },
  { "tests/ui/fixtures/shop-compact.txt", "browse", 29, 12 },
  { "tests/ui/fixtures/shop-pocket.txt", "browse", 26, 20 },
  { "tests/ui/fixtures/shop-large.txt", "browse", 100, 38 },
}

local function read(path)
  local f = assert(io.open(path, "rb"))
  local body = f:read("*a")
  f:close()
  return body
end

return function(test, equal)
  test("UI2c every shop page matches its route A fixture at every size, contrast included", function()
    for _, case in ipairs(FIXTURES) do
      local _, frame = scene(case[2], case[3], case[4])
      local out = capture(frame, case[3], case[4])
      local diff = R.diff(case[1], out)
      assert(#diff == 0, case[1] .. "\n" .. table.concat(diff, "\n"))
      contrast(out, case[1])
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

  test("UI2c categories, subs, low and empty filter the list and the picker counts them", function()
    local s = loaded()
    local want, low, empty = {}, 0, 0
    for _, item in ipairs(s.data.items) do
      local cat = item.kind:match("^(%a+)/")
      want[cat] = (want[cat] or 0) + 1
      if item.count == 0 then empty = empty + 1
      elseif item.count < math.min(16, item.stack) then low = low + 1 end
    end
    for _, cat in ipairs(s.S.cats) do
      tap(s, 57, 24, "cat:" .. cat[1])
      local m = s.S.gather({ id = 2 })
      equal(#m.items, want[cat[1]] or 0, cat[1])
      for _, item in ipairs(m.items) do equal(item.cat, cat[1]) end
    end
    tap(s, 57, 24, "cat:ores"); tap(s, 57, 24, "sub:ingot")
    local names = ids(s.render(57, 24, { id = 2 }), "^item:(.+)$")
    equal(#names, 6)
    for _, name in ipairs(names) do equal(select(2, s.S.kind(name)), "ingot") end
    tap(s, 57, 24, "cat:mods")
    equal(ids(s.render(57, 24, { id = 2 }), "^sub:(.+)$"), { "all", "create", "ae2", "computercraft", "mekanism" })
    tap(s, 57, 24, "tab:low")
    equal(#s.S.gather({ id = 2 }).items, low + empty)
    tap(s, 57, 24, "low:empty")
    equal(#s.S.gather({ id = 2 }).items, empty)
    tap(s, 57, 24, "low:low")
    equal(#s.S.gather({ id = 2 }).items, low)
    -- The narrow picker shows the same counts and opens the category it names.
    tap(s, 26, 20, "tab:items"); tap(s, 26, 20, "pick:cats")
    local picker = text(s.render(26, 20, { id = 2 }))
    assert(picker:find("ores \183+ " .. want.ores), picker)
    assert(picker:find("all \183+ " .. #s.data.items), picker)
    tap(s, 26, 20, "cat:wood")
    equal(s.S.view({ id = 2 }).pick, nil)
    equal(#s.S.gather({ id = 2 }).items, want.wood)
    tap(s, 26, 20, "pick:subs"); tap(s, 26, 20, "sub:planks")
    equal(ids(s.render(26, 20, { id = 2 }), "^item:(.+)$"), { "minecraft:oak_planks", "minecraft:spruce_planks" })
  end)

  test("UI2c sort by count, name and trend from the column head and page through every item once", function()
    local s = loaded()
    local w, h = 39, 19
    for _, sort in ipairs({ "count", "name", "trend" }) do
      if sort ~= "count" then tap(s, w, h, "sort:" .. sort) end
      local seen, order = {}, {}
      for page = 1, 40 do
        local frame = s.render(w, h, { id = 2 })
        for _, name in ipairs(ids(frame, "^item:(.+)$")) do
          assert(not seen[name], name); seen[name] = true; order[#order + 1] = name
        end
        if not has(frame, "next") then break end
        assert(page < 40, "paging never ends")
        tap(s, w, h, "next")
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
      local frame = s.render(w, h, { id = 2 })
      assert(text(frame):find(s.S.view({ id = 2 }).page .. " of " .. s.S.view({ id = 2 }).page, 1, true))
      for _ = 1, 40 do
        if not has(s.render(w, h, { id = 2 }), "prev") then break end
        tap(s, w, h, "prev")
      end
      equal(s.S.view({ id = 2 }).page, 1)
    end
    -- At 100x38 the list balances two columns and pages hold both.
    local wide = s.render(100, 38, { id = 2 })
    local xs = {}
    for _, b in ipairs(wide.buttons) do if b.id:match("^item:") then xs[b.x] = (xs[b.x] or 0) + 1 end end
    equal(xs, { [2] = 16, [52] = 16 })
  end)

  test("UI2c search by keypad and by keyboard covers every category", function()
    local s = loaded()
    tap(s, 26, 20, "tab:find")
    for _, key in ipairs({ "I", "R", "O", "N", "X", "DEL" }) do tap(s, 26, 20, "key:" .. key) end
    equal(s.S.view({ id = 2 }).search, "iron")
    local m = s.S.gather({ id = 2 })
    equal(#m.items, 14)
    local cats = {}
    for _, item in ipairs(m.items) do cats[item.cat] = true; assert(item.name:find("iron", 1, true)) end
    assert(cats.ores and cats.tools)
    assert(text(s.render(26, 20, { id = 2 })):find("> IRON_", 1, true))
    tap(s, 26, 20, "keys")
    local frame = s.render(26, 20, { id = 2 })
    assert(not has(frame, "key:A") and #ids(frame, "^item:") > 7, "the field hides the keypad")
    tap(s, 26, 20, "keys"); tap(s, 26, 20, "key:CLR")
    equal(s.S.view({ id = 2 }).search, "")
    s.input({ text = "copper ingot", session = { id = 2 } })
    m = s.S.gather({ id = 2 })
    equal(#m.items, 1); equal(m.items[1].name, "minecraft:copper_ingot")
    equal(s.S.view({ id = 2 }).tab, "find")
    s.input({ text = "*", session = { id = 2 } })
    equal(#s.S.gather({ id = 2 }).items, #s.data.items)
    s.input({ text = "Basic Control", session = { id = 3 } })
    equal(s.S.gather({ id = 3 }).items[1].name, "mekanism:basic_control_circuit")
    equal(#s.S.gather({ id = 2 }).items, #s.data.items, "searches belong to each display")
  end)

  test("UI2c one tap sends one order for 1, 16, 64, a stack and all", function()
    for _, size in ipairs({ { 57, 24 }, { 26, 20 } }) do
      local w, h = size[1], size[2]
      for _, case in ipairs({ { "1", 1 }, { "16", 16 }, { "64", 64 }, { "stack", 16 }, { "all", 6 } }) do
        local s = loaded()
        if w < WIDE then tap(s, w, h, "pick:cats") end
        tap(s, w, h, "cat:mobs")
        tap(s, w, h, "item:minecraft:ender_pearl")
        local n = #s.sends
        local id = "order:" .. case[1] .. ":minecraft:ender_pearl"
        local frame = s.render(w, h, { id = 2 })
        local button = has(frame, id)
        assert(button and button.h == 1, id)
        if w >= WIDE then assert(has(frame, "item:minecraft:bone"), "the list stays beside the item") end
        s.input({ id = id, x = button.x, y = button.y, session = { id = 2 } })
        for _ = 1, 3 do s.render(w, h, { id = 2 }) end
        equal(#s.sends, n + 1)
        local sent = s.sends[#s.sends]
        equal(sent.id, 9); equal(sent.protocol, "roomsorter")
        equal(sent.body.cmd, "order"); equal(sent.body.text, "minecraft:ender_pearl"); equal(sent.body.n, case[2])
        s.input({ id = id, x = button.x, y = button.y, session = { id = 2 } })
        equal(#s.sends, n + 2, "a second tap is a second order")
        s.input({ id = id, session = { id = 3 } })
        equal(#s.sends, n + 2, "another display has not opened the item")
        assert(text(s.render(w, h, { id = 2 })):find("\7 " .. case[2] .. " sent", 1, true))
        local recent = s.S.recent["minecraft:ender_pearl"]
        equal(#recent, 2); equal(recent[1].hm, "21:14"); equal(recent[1].n, case[2])
        tap(s, w, h, "items")
        equal(s.S.view({ id = 2 }).selected, nil)
      end
    end
    local s = loaded()
    tap(s, 57, 24, "tab:low"); tap(s, 57, 24, "low:empty")
    tap(s, 57, 24, "item:minecraft:quartz")
    local frame = s.render(57, 24, { id = 2 })
    assert(not has(frame, "order:all:minecraft:quartz") and has(frame, "order:16:minecraft:quartz"))
    local n = #s.sends
    s.input({ id = "order:all:minecraft:quartz", session = { id = 2 } })
    s.input({ id = "order:2:minecraft:quartz", session = { id = 2 } })
    equal(#s.sends, n)
    tap(s, 57, 24, "item:minecraft:quartz")
    equal(s.S.view({ id = 2 }).selected, nil, "a second tap on the open row closes the item")
  end)

  test("UI2c order replies update the recent list", function()
    local s = loaded()
    tap(s, 26, 20, "pick:cats"); tap(s, 26, 20, "cat:ores"); tap(s, 26, 20, "item:minecraft:iron_ingot")
    tap(s, 26, 20, "order:64:minecraft:iron_ingot")
    local rid = s.sends[#s.sends].body.rid
    s.mod.listen.roomsorter(9, { rid = rid, "Delivered 64 Iron ingot" })
    assert(text(s.render(26, 20, { id = 2 })):find("\7 64 delivered", 1, true))
    equal(s.S.recent["minecraft:iron_ingot"][1].status, "delivered")
    tap(s, 26, 20, "order:1:minecraft:iron_ingot")
    s.now = s.now + 120001; s.mod.tick(s.now)
    assert(text(s.render(26, 20, { id = 2 })):find("\7 1 failed", 1, true))
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
    for _, size in ipairs({ { 57, 24 }, { 39, 19 }, { 26, 20 }, { 26, 19 }, { 29, 12 }, { 100, 38 }, { 15, 10 },
        { 36, 10 }, { 51, 19 }, { 52, 16 }, { 164, 81 }, { 4, 5 }, { 1, 1 } }) do
      local w, h = size[1], size[2]
      for page in pairs(PAGES) do
        local s = loaded()
        for _, id in ipairs(PAGES[page]) do
          if id == "reply" then s.mod.listen.roomsorter(9, { rid = s.sends[#s.sends].body.rid, "Getting 16" })
          else s.input({ id = id, session = { id = 2 } }) end
        end
        local frame = s.render(w, h, { id = 2 })
        local ok, out = pcall(capture, frame, w, h)
        assert(ok, page .. " " .. w .. "x" .. h .. ": " .. tostring(out))
        if w >= 15 then
          contrast(out, page .. " " .. w .. "x" .. h)
          assert(#frame.buttons > 0, page .. " " .. w .. "x" .. h)
        end
        if w >= 26 then
          local want = { browse = "COAL", item = "IRON INGOT", low = "BASIC", find = "> IRON", pick = "ores" }
          assert(text(frame):find(want[page], 1, true), page .. " " .. w .. "x" .. h)
        end
      end
    end
  end)

  test("UI2c big walls with long item names stay under the frame budget and keep the footer", function()
    local s = loaded()
    local P = assert(loadfile("so-proto.lua", "t", setmetatable({ SO = {} }, { __index = _G })))()
    s.env.SO.proto = P
    local totals = {}
    for name, count in pairs(s.S.totals) do totals[name] = count end
    for i = 1, 200 do totals["somemod:a_very_long_item_name_to_test_the_frame_budget_" .. i] = i end
    s.mod.listen.roomsorter_stock(9, { totals = totals })
    for _, size in ipairs({ { 100, 38 }, { 121, 54 }, { 164, 81 }, { 89, 81 }, { 52, 81 } }) do
      for i, taps in ipairs({ {}, { "item:minecraft:iron_ingot" }, { "tab:find" }, { "tab:low" } }) do
        local session = { id = 10 + i }
        for _, id in ipairs(taps) do s.input({ id = id, session = session }) end
        local frame = s.render(size[1], size[2], session)
        local bytes = #P.ser(frame)
        assert(bytes <= 15000, size[1] .. "x" .. size[2] .. " " .. i .. " " .. bytes .. " bytes")
        equal(has(frame, "next").y, size[2])
        capture(frame, size[1], size[2])
      end
    end
  end)

  test("UI2c many mod namespaces, stale sub taps, craftable 0 and direct orders", function()
    local s = loaded()
    local P = assert(loadfile("so-proto.lua", "t", setmetatable({ SO = {} }, { __index = _G })))()
    s.env.SO.proto = P
    local totals = {}
    for name, count in pairs(s.S.totals) do totals[name] = count end
    for i = 1, 90 do
      for j = 1, 4 do totals["mod" .. i .. ":part_" .. j] = i + j end
    end
    s.mod.listen.roomsorter_stock(9, { totals = totals })
    -- Wide screens swap a sub chip row of more than two rows for the picker chip.
    for _, size in ipairs({ { 57, 24 }, { 100, 38 }, { 164, 81 } }) do
      local w, h = size[1], size[2]
      local session = { id = 30 + w }
      tap(s, w, h, "cat:mods", session)
      local frame = s.render(w, h, session)
      assert(#P.ser(frame) <= 15000, w .. "x" .. h)
      equal(ids(frame, "^sub:(.+)$"), {})
      assert(#ids(frame, "^item:") >= 8, "the list keeps its rows at " .. w .. "x" .. h)
      equal(has(frame, "next").y, h)
      tap(s, w, h, "pick:subs", session)
      capture(s.render(w, h, session), w, h)
      tap(s, w, h, "sub:mod1", session)
      equal(#s.S.gather(session).items, 4)
    end
    -- Narrow pickers keep 12-cell columns and drop what does not fit.
    for _, size in ipairs({ { 29, 12 }, { 26, 20 }, { 39, 19 } }) do
      local w, h = size[1], size[2]
      local session = { id = 40 + w }
      tap(s, w, h, "pick:cats", session); tap(s, w, h, "cat:mods", session); tap(s, w, h, "pick:subs", session)
      local frame = s.render(w, h, session)
      capture(frame, w, h)
      for _, b in ipairs(frame.buttons) do assert(b.w >= 12 or not b.id:match("^sub:"), b.id) end
    end
    -- A sub tap from an older frame does not filter another category.
    local session = { id = 50 }
    tap(s, 57, 24, "cat:ores", session)
    s.input({ id = "cat:all", session = session })
    s.input({ id = "sub:ingot", session = session })
    equal(s.S.view(session).sub, "all")
    s.input({ id = "cat:wood", session = session })
    s.input({ id = "sub:ingot", session = session })
    equal(s.S.view(session).sub, "all")
    -- Rooms list recipes they cannot make now with can = 0; the pane leaves those out.
    s.mod.listen.roomsorter(9, { rid = (function() s.S.stockAt = nil; s.mod.tick(s.now); return s.sends[#s.sends].body.rid end)(),
      totals = totals, recipes = { { name = "minecraft:iron_ingot", can = 0 } } })
    tap(s, 57, 24, "cat:ores", session); tap(s, 57, 24, "item:minecraft:iron_ingot", session)
    local before = s.render(57, 24, session)
    assert(not text(before):find("craftable", 1, true))
    -- shop.order for the open item leaves the pane as it was.
    equal(s.mod.order("minecraft:iron_ingot", 16), "minecraft:iron_ingot")
    equal(s.render(57, 24, session), before)
  end)

  test("UI2c stale, missing and empty stock stay visible", function()
    local s = setup()
    for _, size in ipairs({ { 57, 24 }, { 29, 12 }, { 26, 20 } }) do
      local frame = text(s.render(size[1], size[2], { id = 2 }))
      assert(frame:find("storage room not found", 1, true), size[1])
    end
    assert(text(s.render(57, 24, { id = 2 })):find("missing", 1, true))
    s.mod.listen.roomsorter_stock(9, { totals = { ["minecraft:iron_ingot"] = 64 } })
    assert(text(s.render(57, 24, { id = 2 })):find("stock 21:14", 1, true))
    s.now = s.now + 30000
    for _, size in ipairs({ { 57, 24 }, { 39, 19 }, { 29, 12 }, { 26, 20 } }) do
      assert(text(s.render(size[1], size[2], { id = 2 })):find("stale", 1, true), "stale at " .. size[1])
    end
    tap(s, 29, 12, "item:minecraft:iron_ingot")
    assert(text(s.render(26, 20, { id = 2 })):find("stale", 1, true))
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
    assert(text(s.render(29, 12, { id = 2 })):find("storage room not found", 1, true))
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

  test("UI2c the schematic generator reproduces every shop fixture", function()
    local started, pipe = pcall(io.popen, "pwd")
    local root = started and pipe and pipe:read("*l")
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= "/" or not os.execute("python3 -V > /dev/null 2>&1") then
      return dofile("tests/skips.lua").record("UI2c shop generator", "needs host processes, a POSIX shell and python3")
    end
    local dir = os.tmpname()
    os.remove(dir)
    local names = {}
    for _, case in ipairs(FIXTURES) do names[#names + 1] = case[1]:match("([%w%-]+)%.txt$") end
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' "
      .. table.concat(names, " ") .. " > /dev/null"))
    for i, case in ipairs(FIXTURES) do equal(read(dir .. "/" .. names[i] .. ".txt"), read(case[1])) end
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)
end
