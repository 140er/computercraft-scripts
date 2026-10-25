local R = dofile("tests/ui/render.lua")
local Scene = dofile("tests/ui/scene.lua")

-- Literal paths, so part runs declare every fixture they read.
local FIXTURE = {
  page = "tests/ui/fixtures/pocket-shoppage-P.txt", low = "tests/ui/fixtures/pocket-shoplow-P.txt",
  qty = "tests/ui/fixtures/pocket-shopqty-P.txt", noroom = "tests/ui/fixtures/pocket-shopnoroom-P.txt",
  panelqty = "tests/ui/fixtures/panelqty-P.txt", panelnoroom = "tests/ui/fixtures/panelnoroom-P.txt",
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
  local s = { now = 1000, sends = {}, session = { id = 2 }, events = {}, values = {} }
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
  env.SO.mods.state = {
    get = function(key) return s.values[key] end,
    emit = function(kind, data)
      s.events[#s.events + 1] = { kind = kind, data = data }
      s.values[kind] = data
      return true
    end,
  }
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

local H = dofile("tests/so/harness.lua")
local function savedShop(files, enabled, values)
  local m = H.new().machine({id=1, capacity=16000000})
  m.install({"so-store.lua","so-ui.lua","so-mod-shop.lua","so-mod-panel.lua"})
  for name, bytes in pairs(files or {}) do m.files[name] = bytes end
  m.files["so-server.cfg"] = H.encode({shopSaved=enabled == true})
  local e, s = m.env, {machine=m, now=1000, values=values or {}, events={}, screens={}}
  e.SO = {store=e.dofile("so-store.lua"), now=function() return s.now end, mods={}}
  e.SO.mods.state = {
    get=function(key) return s.values[key] end,
    view=function() return {values=s.values} end,
    emit=function(key,value) s.values[key]=value s.events[#s.events+1]={key,value} return true end,
  }
  e.SO.mods.display = {screen=function(name,render,input)
    if render then s.screens[name]={render=render,input=input} end
    return s.screens[name]
  end}
  s.shop=e.dofile("so-mod-shop.lua") e.SO.mods.shop=s.shop
  s.shop.tick(s.now)
  s.panel=e.dofile("so-mod-panel.lua") e.SO.mods.panel=s.panel s.panel.tick()
  s.stock=function(totals) s.shop.listen.roomsorter_stock(9,{totals=totals}) end
  s.config=function(on) m.files["so-server.cfg"]=H.encode({shopSaved=on}) s.shop.tick(s.now) end
  s.frame=function(session,role,w,h) return s.screens[role or "pocket"].render(w or 26,h or 20,session) end
  s.tap=function(session,id,role)
    local frame=s.frame(session,role)
    for _,b in ipairs(frame.buttons) do
      if b.id==id then s.screens[role or "pocket"].input({session=session,id=id,x=b.x,y=b.y}) return end
    end
    error("control not drawn: "..id)
  end
  s.saved=function(kind) return assert(e.SO.store.read("so-data/shop-"..kind)).value end
  return s
end
local function savedGeneration(kind, entries, revision)
  return H.encode({schema=1,generation=1,value={v=1,kind=kind,revision=revision or 0,entries=entries}})
end

return function(test, equal)
  test("shop P-U2-14 full stock raises one standing alert and clears on false or missing full", function()
    local s = setup()
    local function stock(full)
      s.mod.listen.roomsorter_stock(9, { totals = {}, full = full })
    end
    equal(#s.events, 0)
    for _, clear in ipairs({ false, "missing" }) do
      stock(true)
      equal(s.values["shop.room.alert"], { text = "Storage room full" })
      local raised = #s.events
      stock(true)
      equal(#s.events, raised, "repeated full stock does not repeat the event")
      if clear == false then stock(false) else stock(nil) end
      equal(s.values["shop.room.alert"], false)
      equal(#s.events, raised + 1)
      stock(nil)
      equal(#s.events, raised + 1, "repeated clear stock does not repeat the event")
    end
    equal(s.events[1].kind, "shop.room.alert")
    equal(s.events[2], { kind = "shop.room.alert", data = false })
  end)

  test("shop P-U2-14 ignores other rooms and malformed stock and clears a retained alert", function()
    local s = setup()
    s.mod.listen.roomsorter_stock(10, { totals = {}, full = true })
    equal(#s.events, 0)
    s.mod.listen.roomsorter_stock(9, { totals = {}, full = true })
    s.mod.listen.roomsorter_stock(10, { totals = {}, full = false })
    s.mod.listen.roomsorter_stock(9, { full = false })
    s.mod.listen.roomsorter_stock(9, "bad stock")
    equal(#s.events, 1)
    equal(s.values["shop.room.alert"], { text = "Storage room full" })
    local fresh = setup()
    fresh.values["shop.room.alert"] = { text = "Storage room full" }
    fresh.mod.listen.roomsorter_stock(9, { totals = {} })
    equal(fresh.events, { { kind = "shop.room.alert", data = false } })
  end)

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
  test("shop P-U2-1 the legacy screen has no chip above the stack, and a forced 64 pearls sends nothing", function()
    local s = setup(true)
    s.mod.listen.roomsorter_stock(9, { totals = { ["minecraft:ender_pearl"] = 40, ["minecraft:iron_ingot"] = 64 } })
    local ids = {}
    for _, b in ipairs(s.render(39, 19, s.session).buttons) do ids[b.id] = true end
    assert(ids["order:16:minecraft:ender_pearl"] and not ids["order:64:minecraft:ender_pearl"])
    assert(ids["order:64:minecraft:iron_ingot"], "a 64-stack item keeps its 64 chip")
    local n = #s.sends
    s.input({ session = s.session, id = "order:64:minecraft:ender_pearl" })
    equal(#s.sends, n)
    s.input({ session = s.session, id = "order:16:minecraft:ender_pearl" })
    equal({ #s.sends, s.sends[#s.sends].body.n }, { n + 1, 16 })
  end)

  test("shop P-U2-1 and P-U2-8 the keyboard panel twin: a typed quantity and no room", function()
    local s = Scene.new({ panel = true, shop = true, facts = true })
    assert(s.d.assign(POCKET, "panel"))
    local function match(key)
      local fixture = R.load(FIXTURE[key])
      local diff = R.diff(fixture, Scene.capture(s.view(POCKET), fixture.w, fixture.h))
      assert(#diff == 0, key .. "\n" .. table.concat(diff, "\n"))
    end
    s.type(POCKET, "iron 37")
    match("panelqty")
    s.type(POCKET, "iron")
    s.env.SO.mods.shop = assert(loadfile("so-mod-shop.lua", "t", s.env))()
    match("panelnoroom")
    for _, b in ipairs(s.view(POCKET).buttons) do assert(not b.id:match("^order:"), b.id) end
  end)
  test("P-U2-5 and P-U2-11 default off creates no saved files, controls or watch alerts", function()
    local s=savedShop()
    s.stock({["minecraft:iron_ingot"]=0})
    equal({s.shop.setMinimum("minecraft:iron_ingot",32,0)},{false,"off"})
    equal({s.shop.setWatch("minecraft:iron_ingot",true,0)},{false,"off"})
    local session={id=7,keyboard=true,pocket={page="shop",search="iron"}}
    for _,b in ipairs(s.frame(session).buttons) do assert(not b.id:match("^saved:")) end
    for path in pairs(s.machine.files) do assert(not path:match("so%-data/shop%-"),path) end
    equal(#s.events,0)
  end)

  test("P-U2-5 shared minimums survive restart, bind revisions and keep old data on save failure", function()
    local s=savedShop(nil,true)
    s.stock({["minecraft:iron_ingot"]=24,["minecraft:ender_pearl"]=16})
    equal(#s.shop.lows(10),0)
    assert(s.shop.setMinimum("minecraft:iron_ingot",32,0))
    equal(s.shop.lows(10)[1].name,"minecraft:iron_ingot")
    equal({s.shop.setMinimum("minecraft:ender_pearl",20,0)},{false,"changed"})
    local copy=s.shop.saved("minimums") copy.entries["minecraft:iron_ingot"]=1
    equal(s.shop.minimum("minecraft:iron_ingot"),32)
    for _,value in ipairs({0/0,math.huge,-math.huge}) do
      equal({s.shop.setMinimum("minecraft:iron_ingot",value,1)},{false,"invalid"})
    end
    s.machine.capacity=0
    equal({s.shop.setMinimum("minecraft:iron_ingot",64,1)},{false,"save unavailable"})
    equal({s.shop.minimum("minecraft:iron_ingot"),s.shop.saved("minimums").revision},{32,1})
    s=savedShop(s.machine.files,true)
    equal({s.shop.minimum("minecraft:iron_ingot"),s.shop.saved("minimums").revision},{32,1})
    assert(s.shop.setMinimum("minecraft:iron_ingot",nil,1))
    equal(s.shop.minimum("minecraft:iron_ingot"),16)
    s.config(false)
    equal(s.shop.minimum("minecraft:ender_pearl"),16)
    s.config(true)
    equal(s.shop.saved("minimums").revision,2)
  end)

  test("D6 validator rejects malformed envelopes and recovers a valid generation", function()
    local item="minecraft:iron_ingot"
    local bad={
      {v=2,kind="minimums",revision=0,entries={}},
      {v=1,kind="minimums",revision=0,entries={},extra=true},
      {v=1,kind="watches",revision=0,entries={}},
      {v=1,kind="minimums",revision=-1,entries={}},
      {v=1,kind="minimums",revision=2147483648,entries={}},
      {v=1,kind="minimums",revision=0,entries={[item]=4097}},
      {v=1,kind="minimums",revision=0,entries={[item]=1.5}},
      {v=1,kind="minimums",revision=0,entries={[item]=0}},
      {v=1,kind="minimums",revision=0,entries={["Bad:Id"]=1}},
      {v=1,kind="minimums",revision=0,entries={["mod:"..string.rep("x",125)]=1}},
    }
    for _,v in ipairs(bad) do
      local bytes=H.encode({schema=1,generation=1,value=v})
      local s=savedShop({["so-data/shop-minimums"]=bytes},true)
      equal({s.shop.saved("minimums")},{nil,"save unavailable"})
      equal({s.shop.setMinimum(item,32,0)},{false,"save unavailable"})
      equal(s.machine.files["so-data/shop-minimums"],bytes)
    end
    for _,entries in ipairs({{item,item},{[2]=item},{["x"]=item},{"bad"}}) do
      local s=savedShop({["so-data/shop-watches"]=savedGeneration("watches",entries)},true)
      equal({s.shop.saved("watches")},{nil,"save unavailable"})
    end
    local s=savedShop({["so-data/shop-minimums"]=savedGeneration("watches",{}),
      ["so-data/shop-minimums.bak"]=H.encode({schema=1,generation=2,
        value={v=1,kind="minimums",revision=4,entries={[item]=31}}})},true)
    equal(s.shop.minimum(item),31)
    assert(s.shop.setMinimum(item,32,4))
    equal(s.saved("minimums").revision,5)
    s=savedShop({["so-data/shop-minimums"]=savedGeneration("minimums",{},2147483647)},true)
    equal({s.shop.setMinimum(item,1,2147483647)},{false,"save unavailable"})
  end)

  test("D6 caps both stores at 256 exact IDs and keeps generations below 64 KiB", function()
    local minimums,watches={},{}
    for i=1,256 do
      local id="mod:"..string.rep("x",120)..i
      minimums[id],watches[i]=4096,id
    end
    local s=savedShop({["so-data/shop-minimums"]=savedGeneration("minimums",minimums),
      ["so-data/shop-watches"]=savedGeneration("watches",watches)},true)
    assert(s.shop.setMinimum(watches[1],1,0))
    assert(s.shop.setWatch(watches[1],false,0))
    assert(s.shop.setWatch(watches[1],true,1))
    equal({s.shop.setMinimum("mod:overflow",1,1)},{false,"invalid"})
    equal({s.shop.setWatch("mod:overflow",true,2)},{false,"invalid"})
    for path,bytes in pairs(s.machine.files) do
      if path:match("so%-data/shop%-") then assert(#bytes<=65536,path) end
    end
  end)

  test("P-U2-11 two zero watches give independent ALERTS rows and clear with false", function()
    local a,b="minecraft:iron_ingot","minecraft:gold_ingot"
    local ka,kb="shop.watch."..a..".alert","shop.watch."..b..".alert"
    local s=savedShop(nil,true)
    assert(s.shop.setWatch(a,true,0)) assert(s.shop.setWatch(b,true,1))
    s.stock({[a]=0,[b]=0})
    equal(#s.events,2)
    s.stock({[a]=0,[b]=0}) equal(#s.events,2)
    s.panel.tick()
    local session={id=7,panel={page="alerts",search=""}}
    local lines={}
    for _,row in ipairs(s.frame(session,"panel",57,24).rows) do lines[#lines+1]=row.text end
    local text=table.concat(lines,"\n")
    assert(text:find(a.." empty",1,true) and text:find(b.." empty",1,true))
    s.stock({[a]=1,[b]=0}) equal(s.values[ka],false) assert(s.values[kb])
    s.machine.capacity=0
    equal({s.shop.setWatch(b,false,2)},{false,"save unavailable"}) assert(s.values[kb])
    s.machine.capacity=16000000
    assert(s.shop.setWatch(b,false,2)) equal(s.values[kb],false)
    s.stock({[a]=0,[b]=0}) assert(s.values[ka]) equal(s.values[kb],false)
    s.config(false) equal(s.values[ka],false)
  end)

  test("P-U2-11 boot reconciles restored watch keys on the first explicit fresh sample", function()
    local a,b="minecraft:iron_ingot","minecraft:gold_ingot"
    local ka,kb="shop.watch."..a..".alert","shop.watch."..b..".alert"
    local files={["so-data/shop-watches"]=savedGeneration("watches",{a,b})}
    local s=savedShop(files,true,{[ka]={text=a.." empty"},[kb]={text=b.." empty"},
      ["shop.watch.mod:removed.alert"]={text="old"}})
    s.stock({[a]=0,[b]=3})
    equal(s.values[kb],false) equal(s.values["shop.watch.mod:removed.alert"],false)
    equal(s.values[ka],{text=a.." empty"})
    assert(s.shop.setWatch("mod:unknown",true,0))
    s.stock({}) equal(s.values["shop.watch.mod:unknown.alert"],nil)
    s.stock({["mod:stale"]=0})
    s.now=s.now+30000
    assert(s.shop.setWatch("mod:stale",true,1))
    equal(s.values["shop.watch.mod:stale.alert"],nil)
    s=savedShop(files,true) s.stock({[a]=0}) assert(s.values[ka])
    s=savedShop(files,false,s.values) equal(s.values[ka],false)
  end)

  test("P-U2-5 panel and pocket controls share minimums and reject stale rendered edits", function()
    local s=savedShop(nil,true)
    local item="minecraft:iron_ingot"
    s.stock({[item]=24})
    local pocket={id=7,keyboard=true,pocket={page="shop",search="iron"}}
    local panel={id=8,keyboard=true,panel={page="main",search="iron"}}
    s.tap(pocket,"saved:min:0:"..item)
    s.tap(panel,"saved:min:0:"..item,"panel")
    s.screens.pocket.input({session=pocket,text="32"})
    s.tap(pocket,"saved:save")
    s.screens.panel.input({session=panel,text="64"})
    s.tap(panel,"saved:save","panel")
    equal(panel.panel.savedResult,"changed")
    equal(s.shop.minimum(item),32)
    s.tap(panel,"saved:back","panel")
    s.tap(pocket,"saved:watch:0:"..item)
    equal(s.shop.saved("watches").entries,{item})
    s.tap(panel,"saved:watch:1:"..item,"panel")
    equal(s.shop.saved("watches").entries,{})
    s.tap(pocket,"saved:min:1:"..item)
    s.tap(pocket,"saved:default") equal(s.shop.minimum(item),16)
    for _,size in ipairs({{26,20},{29,12},{57,24},{15,12}}) do
      local frame=s.frame(pocket,"pocket",size[1],size[2])
      for _,b in ipairs(frame.buttons) do
        if b.id:match("^saved:") then assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=size[1] and b.y<=size[2],b.id) end
      end
    end
  end)

  test("D6 enabled pocket and minimum editor match their route A twins", function()
    local s=savedShop(nil,true)
    s.stock({["minecraft:iron_ingot"]=24})
    local session={id=7,keyboard=true,pocket={page="shop",search="iron"}}
    local function match(path)
      local fixture=R.load(path)
      local diff=R.diff(fixture,Scene.capture(s.frame(session),fixture.w,fixture.h))
      assert(#diff==0,path.."\n"..table.concat(diff,"\n"))
    end
    match("tests/ui/fixtures/pocket-shopsaved-P.txt")
    s.tap(session,"saved:min:0:minecraft:iron_ingot")
    match("tests/ui/fixtures/pocket-shopminimum-P.txt")
    s.tap(session,"tab:jobs")
    equal({session.pocket.page,session.pocket.minimumDraft},{"jobs",nil})
    s.tap(session,"tab:shop")
    s.tap(session,"saved:min:0:minecraft:iron_ingot")
    s.config(false)
    for _,b in ipairs(s.frame(session).buttons) do assert(not b.id:match("^saved:")) end
  end)

  test("D6 stale watch taps return changed and disabled drafts cannot save", function()
    local s=savedShop(nil,true)
    local item="minecraft:iron_ingot"
    s.stock({[item]=0})
    local session={id=7,keyboard=true,pocket={page="shop",search="iron"}}
    local id="saved:watch:0:"..item
    local tapped
    for _,b in ipairs(s.frame(session).buttons) do if b.id==id then tapped=b end end
    assert(tapped)
    assert(s.shop.setWatch("mod:other",true,0))
    s.screens.pocket.input({session=session,id=id,x=tapped.x,y=tapped.y})
    equal(session.pocket.savedResult,"changed")
    equal(s.shop.saved("watches").entries,{"mod:other"})
    s.tap(session,"saved:min:0:"..item)
    local frame=s.frame(session)
    for _,b in ipairs(frame.buttons) do if b.id=="saved:save" then tapped=b end end
    s.config(false)
    s.screens.pocket.input({session=session,id="saved:save",x=tapped.x,y=tapped.y})
    equal(s.machine.files["so-data/shop-minimums"],nil)
    for _,b in ipairs(s.frame(session).buttons) do assert(not b.id:match("^saved:")) end
  end)

  test("D6 keyboard panel renders when the shop module is absent", function()
    local s=savedShop()
    s.machine.env.SO.mods.shop=nil
    s.screens.shop=nil
    s.panel.tick()
    local session={id=7,keyboard=true,panel={page="main",search=""}}
    for _,size in ipairs({{26,20},{29,12}}) do
      local frame=s.frame(session,"panel",size[1],size[2])
      equal(#frame.rows,size[2])
      assert(frame.rows[1].text:find("PANEL",1,true))
      for _,b in ipairs(frame.buttons) do assert(not b.id:match("^saved:")) end
    end
  end)

  test("D6 rejected rename generations cannot win after reboot", function()
    for _,kind in ipairs({"minimums","watches"}) do
      local s=savedShop(nil,true)
      local item,path="minecraft:iron_ingot","so-data/shop-"..kind
      local function edit(value,revision)
        if kind=="minimums" then return s.shop.setMinimum(item,value,revision) end
        return s.shop.setWatch(item,value,revision)
      end
      assert(edit(kind=="minimums" and 32 or true,0))
      local before=s.shop.saved(kind)
      local move=s.machine.env.fs.move
      local failed=false
      s.machine.env.fs.move=function(from,to)
        if not failed and from==path..".tmp" and to==path then failed=true error("injected final rename failure") end
        return move(from,to)
      end
      equal({edit(kind=="minimums" and 64 or false,1)},{false,"save unavailable"})
      assert(failed)
      equal(s.shop.saved(kind),before)
      s=savedShop(s.machine.files,true)
      equal(s.shop.saved(kind),before)
      if kind=="minimums" then assert(s.shop.setMinimum(item,48,1))
      else assert(s.shop.setWatch(item,false,1)) end
      equal(s.shop.saved(kind).revision,2)
    end
  end)

  test("D6 failed first edit restores the empty committed revision", function()
    local s=savedShop(nil,true)
    local path="so-data/shop-minimums"
    local move=s.machine.env.fs.move
    s.machine.env.fs.move=function(from,to)
      local pending=s.machine.env.SO.store.read(path..".tmp")
      if from==path..".tmp" and to==path and pending and pending.value.revision==1 then
        error("reject the edited generation")
      end
      return move(from,to)
    end
    equal({s.shop.setMinimum("minecraft:iron_ingot",32,0)},{false,"save unavailable"})
    s=savedShop(s.machine.files,true)
    equal(s.shop.saved("minimums"),{v=1,kind="minimums",revision=0,entries={}})
  end)

  test("D6 failed rollback marks the file unavailable and refuses further edits", function()
    local s=savedShop(nil,true)
    local item,path="minecraft:iron_ingot","so-data/shop-minimums"
    assert(s.shop.setMinimum(item,32,0))
    local move=s.machine.env.fs.move
    s.machine.env.fs.move=function(from,to)
      if from==path..".tmp" and to==path then error("all final renames fail") end
      return move(from,to)
    end
    equal({s.shop.setMinimum(item,64,1)},{false,"save unavailable"})
    equal(s.shop.minimum(item),32)
    equal({s.shop.saved("minimums")},{nil,"save unavailable"})
    local before=H.encode(s.machine.files)
    equal({s.shop.setMinimum(item,48,1)},{false,"save unavailable"})
    equal(H.encode(s.machine.files),before)
    s=savedShop(s.machine.files,true)
    equal({s.shop.minimum(item),s.shop.saved("minimums").revision},{32,1})
  end)

  test("D6 preflight rejects oversized and wrong-kind newer generations", function()
    for _,kind in ipairs({"minimums","watches"}) do
      local path="so-data/shop-"..kind
      local good=savedGeneration(kind,{})
      for _,suffix in ipairs({"",".tmp",".bak"}) do
        local oversized=good..string.rep(" ",65537-#good)
        local s=savedShop({[path..suffix]=oversized},true)
        equal({s.shop.saved(kind)},{nil,"save unavailable"})
        local ok,why
        if kind=="minimums" then ok,why=s.shop.setMinimum("mod:item",32,0)
        else ok,why=s.shop.setWatch("mod:item",true,0) end
        equal({ok,why},{false,"save unavailable"})
        equal(s.machine.files[path..suffix],oversized)
      end
      for _,bad in ipairs({
        H.encode({schema=1,generation=2,value={v=1,kind=kind,revision=1,entries={}}})..string.rep(" ",65536),
        H.encode({schema=1,generation=2,value={v=1,kind=kind=="minimums" and "watches" or "minimums",revision=1,entries={}}}),
        "unreadable",
      }) do
        local s=savedShop({[path]=bad,[path..".bak"]=good},true)
        equal({s.shop.saved(kind)},{nil,"save unavailable"})
        equal(s.machine.files[path],bad)
      end
    end
  end)

  test("D6 LOW pocket twin uses the saved item minimum", function()
    local s=savedShop(nil,true)
    local item="minecraft:iron_ingot"
    assert(s.shop.setMinimum(item,32,0))
    s.stock({[item]=24})
    local session={id=7,keyboard=true,pocket={page="shop",search="iron",filter="low"}}
    local fixture=R.load("tests/ui/fixtures/pocket-shopsaved-low-P.txt")
    local diff=R.diff(fixture,Scene.capture(s.frame(session),fixture.w,fixture.h))
    assert(#diff==0,table.concat(diff,"\n"))
  end)

end
