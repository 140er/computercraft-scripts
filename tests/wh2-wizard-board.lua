local function source(path)
  if io then
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end
  local f = assert(fs.open(path, "r"))
  local text = f.readAll()
  f.close()
  return text
end

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 print("PASS " .. name)
  else failed = failed + 1 print("FAIL " .. name .. "\n" .. tostring(err)) end
end

local function fixture(width, height)
  local f = { calls = {}, providerCalls = {}, revision = 2, classes = {}, questions = {}, rows = {} }
  local mocks=dofile("tests/mocks.lua")
  function f.question(item)
    return {v=1,id="item:"..item,item=item,state="open",revision=1,firstSeen=0,sampleLocationId=false,draft=false}
  end
  for _, item in ipairs({ "example:raw_tin", "minecraft:sand" }) do
    f.questions[item] = f.question(item)
  end
  f.classes["minecraft:coal"] = { v=1,item = "minecraft:coal", class = "fuel", route = "fuel", storeCategory = "fuel", recipeId = false,
    source="wizard",revision=1,updatedBy=17 }
  local x, y = 1, 1
  local terminal = {
    getSize = function() return width or 26, height or 20 end,
    setBackgroundColor = function() end, setTextColor = function() end, setCursorBlink = function() end,
    clear = function() f.rows = {} end,
    setCursorPos = function(xx, yy)
      assert(xx >= 1 and xx <= (width or 26) and yy >= 1 and yy <= (height or 20), "Drawing outside terminal")
      x, y = xx, yy
    end,
    write = function(text)
      assert(x + #text - 1 <= (width or 26), "Text exceeds terminal")
      f.rows[y] = (f.rows[y] or "") .. text
    end,
  }
  local client,domain = {},nil
  function client.call(op, body)
    assert(body.wh2 == 1)
    assert(not f.handling, "Network call inside input handler")
    f.calls[#f.calls + 1] = { op = op, body = body }
    if f.fail then return { ok = false, code = f.fail, error = "Server rejected answer" } end
    if op == "wh2-get" then
      local list = {}
      for _, record in pairs(body.topic == "questions" and f.questions or f.classes) do list[#list + 1] = record end
      table.sort(list, function(a, b) return a.item < b.item end)
      local cursor = body.cursor
      return { ok = true, revision = body.topic == "questions" and f.revision or "7:" .. f.revision,
        records = list[cursor + 1] and { list[cursor + 1] } or {}, cursor = cursor + 1 < #list and cursor + 1 or 0 }
    elseif op == "wh2-class" then
      local state={wh2={schema=1,wizard={v=1,revision=f.revision,classes=f.classes,questions=f.questions}}}
      local result=domain.run(state,17,{op=op,body=body},{now=0,epoch=3,config={enabled=true,operators={["17"]=true}}})
      f.revision,f.classes,f.questions=state.wh2.wizard.revision,state.wh2.wizard.classes,state.wh2.wizard.questions
      return result
    elseif op == "wh2-recipe" then
      if f.remote then return f.remote(body) end
      return { ok = false, code = "recipe_unavailable", error = "Recipe provider unavailable" }
    end
    error("Unexpected operation " .. tostring(op))
  end
  local provider = {
    getUsesOf = function(item)
      assert(not f.handling, "Provider call inside input handler")
      f.providerCalls[#f.providerCalls + 1] = { "getUsesOf", item }
      return { recipes = { { id = "example:tin_craft", type = "minecraft:crafting" },
        { id = "example:tin_heat", type = "minecraft:smelting" } } }
    end,
    getRecipe = function(id)
      f.providerCalls[#f.providerCalls + 1] = { "getRecipe", id }
      return { id = id, type = id == "example:tin_heat" and "minecraft:blasting" or "minecraft:crafting",
        inputs = { { item = "example:raw_tin", count = 1 } }, outputs = { { item = "example:tin_ingot", count = 1, chance = 1 } } }
    end,
  }
  local env = setmetatable({
    colors = { black = 1, white = 2, yellow = 3, red = 4, lime = 5, lightBlue = 6, gray = 7 },
    keys = { up = 1, down = 2, enter = 3, backspace = 4, escape = 5 },
    term = { current = function() return terminal end },
    peripheral = { find = function() return nil end },
    rednet = setmetatable({}, { __index = function() error("Raw transport forbidden") end }),
    os = { getComputerID = function() return 17 end },
    textutils={serialize=mocks.encode,unserialize=function(data) return assert(load("return "..data,"cache","t",{}))() end},
  }, { __index = _G })
  local modules = {}
  env.require = function(name)
    if not modules[name] then modules[name] = assert(load(source(name .. ".lua"), "@" .. name, "t", env))() end
    return modules[name]
  end
  domain=env.require("wh2-wizard")
  f.cache={value={v=1,draft=false}}
  f.cache.save=function(value)
    if f.cacheFail then return false,"disk full" end
    f.cache.value=assert(load("return "..mocks.encode(value),"cache","t",{}))()
    return true
  end
  f.context = { enabled = true, client = client, recipeIndex = provider, term = terminal,cache=f.cache }
  f.board = env.require("wh2-board").open(f.context)
  f.adapter = env.require("wh2-wizard-adapter")
  function f.event(...)
    f.handling = true
    f.board.handle(...)
    f.handling = false
    f.board.draw(terminal, "term")
  end
  function f.recipes() for _ = 1, 5 do f.board.tick() end end
  function f.text()
    local rows = {}
    for line = 1, height or 20 do rows[line] = f.rows[line] or "" end
    return table.concat(rows, "\n")
  end
  f.terminal, f.env, f.client = terminal, env, client
  return f
end

local function application(path,f,enabled)
  local mocks=dofile("tests/mocks.lua")
  local m=mocks.new(false,{})
  local native=m.env.term.native()
  setmetatable(m.env.term,{__index=native})
  m.env.term.current=function() return native end
  m.env.term.isColour=native.isColor
  m.env.term.setCursorBlink=function() end
  m.env.settings={get=function(_,default) if enabled==nil then return default end return enabled end}
  m.env.sleep=function() m.env.os.pullEvent("wizard_test_tick") end
  m.boardLoads=0
  m.env.require=function(name)
    assert(name=="wh2-board","Unavailable optional module")
    m.boardLoads=m.boardLoads+1
    return {open=function(context)
      context.client,context.recipeIndex,context.cache=f.client,f.context.recipeIndex,f.cache
      f.board=f.env.require("wh2-board").open(context)
      return f.board
    end}
  end
  m.start(source(path))
  return m
end

test("pocket lists paged questions, skips locally, and restores skipped items", function()
  local f = fixture()
  f.board.tick()
  f.board.draw()
  assert(f.text():find("example:raw_tin", 1, true))
  assert(f.text():find("Questions 2", 1, true))
  f.event("char", "s")
  assert(f.board.state.skipped["example:raw_tin"] and #f.board.state.queue == 1)
  assert(f.questions["example:raw_tin"].state == "open")
  f.event("char", "k")
  f.board.tick()
  assert(#f.board.state.queue == 2)
  f.board.draw()
  f.event("mouse_click", 1, 2, 3)
  assert(f.board.state.draft.item == "example:raw_tin")
  f.event("key", f.env.keys.backspace)
  assert(f.board.state.view == "queue")
end)

test("keyboard cooking selection uses authoritative type and commits only on save", function()
  local f = fixture(51, 19)
  f.board.tick()
  f.event("key", f.env.keys.enter)
  local calls = #f.calls
  f.recipes()
  assert(f.providerCalls[1][1] == "getUsesOf")
  assert(#f.providerCalls == 3)
  f.event("key", f.env.keys.enter)
  assert(f.board.state.draft.route == "blast")
  assert(f.board.state.draft.recipeId == "example:tin_heat")
  f.event("char", "c")
  assert(f.cache.value.draft.value.answers.storeCategory==f.board.state.draft.storeCategory)
  calls=#f.calls
  f.event("char", "s")
  f.event("char", "2")
  f.board.tick()
  assert(f.classes["example:raw_tin"].route == "blast", "Saving must freeze the draft")
  assert(f.classes["example:raw_tin"].recipeId == "example:tin_heat")
  assert(f.questions["example:raw_tin"].state == "resolved")
  f.board.tick()
  assert(#f.board.state.queue == 1)
  assert(f.calls[calls + 1].op == "wh2-class")
end)

test("cooking suggestions include later provider pages", function()
  local f = fixture()
  local pages = 0
  f.context.recipeIndex.getUsesOf = function(_, page)
    pages = pages + 1
    return { pages = 2, recipes = { { id = page == 1 and "example:tin_craft" or "example:tin_heat" } } }
  end
  f.board.tick()
  f.event("key", f.env.keys.enter)
  for _ = 1, 8 do f.board.tick() end
  f.event("key", f.env.keys.enter)
  assert(pages == 2)
  assert(f.board.state.draft.route == "blast")
  assert(f.board.state.draft.recipeId == "example:tin_heat")
end)

test("monitor changes prior answers and fuel clears cooking recipe", function()
  local f = fixture(80, 40)
  f.board.tick()
  f.board.draw(f.terminal, "monitor_1")
  f.event("monitor_touch", "other_monitor", 2, 34)
  assert(f.board.state.view == "queue")
  f.event("monitor_touch", "monitor_1", 2, 34)
  assert(f.board.state.view == "edit")
  f.board.draw(f.terminal, "monitor_1")
  f.event("monitor_touch", "monitor_1", 2, 3)
  assert(f.board.state.draft.item == "minecraft:coal")
  f.event("char", "1")
  f.event("char", "s")
  f.board.tick()
  f.board.tick()
  assert(f.classes["minecraft:coal"].route == "store")
  assert(f.classes["minecraft:coal"].recipeId == false)
  f.event("key", f.env.keys.enter)
  f.event("char", "2")
  f.event("char", "s")
  f.board.tick()
  assert(f.classes["minecraft:coal"].route == "fuel")
end)

test("stale edits and forbidden saves remain visible without losing the draft", function()
  local f = fixture()
  f.board.tick()
  f.event("key", f.env.keys.enter)
  f.revision = f.revision + 1
  f.event("char", "s")
  f.board.tick()
  f.board.draw()
  assert(f.text():find("Stale edit", 1, true))
  assert(f.board.state.draft.stale)
  local calls = #f.calls
  f.event("char", "s")
  f.board.tick()
  assert(#f.calls == calls)
  f.event("char", "b")
  f.event("char", "r")
  f.board.tick()
  f.event("key", f.env.keys.enter)
  f.fail = "forbidden"
  f.event("char", "s")
  f.board.tick()
  f.board.draw()
  assert(f.text():find("Server rejected answer", 1, true))
  assert(f.board.state.view == "answer" and f.board.state.draft)
end)

test("missing client and provider fail visibly without raw transport or recipe guesses", function()
  local f = fixture()
  local disabled = f.adapter.open({ client = f.client })
  local result, _, code = disabled.snapshot()
  assert(result == nil and code == "disabled" and #f.calls == 0)
  f.context.client = nil
  local missing = f.env.require("wh2-board").open(f.context)
  missing.tick()
  missing.draw()
  assert(f.text():find("Authenticated wh2-client", 1, true))
  f = fixture()
  f.context.recipeIndex = nil
  f.board = f.env.require("wh2-board").open(f.context)
  f.board.tick()
  f.event("key", f.env.keys.enter)
  f.board.tick()
  f.board.draw()
  assert(f.text():find("Recipe provider unavailabl", 1, true))
  assert(f.board.state.draft.recipeId == false and f.board.state.draft.route == "store")
end)

test("touch and scroll reach questions beyond the first pocket page", function()
  local f = fixture()
  for n = 1, 16 do
    local item = string.format("a:item%02d", n)
    f.questions[item] = f.question(item)
  end
  f.board.tick()
  f.board.draw()
  for _ = 1, 12 do f.event("mouse_click", 1, 22, 12) end
  assert(f.board.state.selection == 13)
  assert(f.text():find("a:item13", 1, true))
  f.event("mouse_scroll", -1, 2, 4)
  assert(f.board.state.selection == 12)
  f.event("key", f.env.keys.enter)
  assert(f.board.state.draft.item == "a:item12")
  f.event("char", "3")
  f.event("char", "s")
  f.board.tick()
  assert(f.classes["a:item12"].route == "unknown")
end)

test("remote recipe fragments use tickets, advance, and release", function()
  local f = fixture()
  f.context.recipeIndex = nil
  local encoded = '{recipes={{id="example:heat"}}}'
  f.env.textutils.unserialize = function(data)
    if data == encoded then return { recipes = { { id = "example:heat" } } } end
    if data == "recipe" then return { id = "example:heat", type = "minecraft:smelting",
      inputs = {{item="example:raw_tin",count=1}},outputs = {{item="example:tin_ingot",count=1,chance=1}} } end
  end
  local stage, offset, releases = nil, 0, 0
  f.remote = function(body)
    if body.action == "query" then
      stage, offset = body.method, 0
      return { ok = true, ticket = "ticket:1" }
    elseif body.action == "release" then releases = releases + 1 return { ok = true }
    elseif body.action == "advance" then assert(body.nextOffset == offset) return { ok = true }
    elseif body.action == "read" then
      local data = stage == "getUsesOf" and encoded or "recipe"
      local part = data:sub(offset + 1, offset + 8)
      local start = offset
      offset = offset + #part
      return { ok = true, fragment = { generation = "hub:1", offset = start,
        nextOffset = offset, totalBytes = #data, data = part, encoding = "lua" } }
    end
    error("Unexpected recipe action")
  end
  f.board = f.env.require("wh2-board").open(f.context)
  f.board.tick()
  f.event("key", f.env.keys.enter)
  for _ = 1, 12 do f.board.tick() end
  f.event("key", f.env.keys.enter)
  assert(f.board.state.draft.route == "furnace")
  assert(f.board.state.draft.recipeId == "example:heat")
  assert(releases == 2)
end)

test("back releases a pending recipe ticket from the worker", function()
  local f = fixture()
  f.context.recipeIndex = nil
  local released = false
  f.remote = function(body)
    if body.action == "query" then return { ok = true, ticket = "ticket:pending" } end
    assert(body.action == "release" and body.ticket == "ticket:pending")
    released = true
    return { ok = true }
  end
  f.board = f.env.require("wh2-board").open(f.context)
  f.board.tick()
  f.event("key", f.env.keys.enter)
  f.board.tick()
  f.event("char", "b")
  assert(not released)
  f.board.tick()
  assert(released and f.questions["example:raw_tin"].state == "answering")
end)

test("hub opens the opt-in board through its actual event loop and keeps fleet keys out", function()
  local mocks = dofile("tests/mocks.lua")
  local f = fixture()
  local m = mocks.new(false, {})
  m.env.settings = { get = function(key, default) if key == "wh2.enabled" then return true end return default end }
  m.env.sleep = function() m.env.os.pullEvent("wizard_test_tick") end
  m.env.require = function(name)
    assert(name == "wh2-board", "Unexpected extension")
    return { open = function(context)
      context.client, context.recipeIndex = f.client, f.context.recipeIndex
      context.cache=f.cache
      f.board = f.env.require("wh2-board").open(context)
      return f.board
    end }
  end
  m.files["views.cfg"] = mocks.encode({ enabled = false })
  m.start(source("hub.lua"))
  assert(f.board and #f.board.state.queue==2,"Hub boot must read and show pending questions")
  local bootCalls=#f.calls
  m.push("char", "i")
  assert(#f.calls == bootCalls)
  m.push("wizard_test_tick")
  assert(#f.board.state.queue == 2)
  m.push("monitor_touch", "dashboard", 2, 3)
  m.push("char", "1")
  m.push("char", "s")
  assert(not m.env.textutils.unserialize(m.files["hub.state"]).recallAll)
  m.push("wizard_test_tick")
  assert(f.classes["example:raw_tin"].route == "store")
  m.push("wizard_test_tick")
  m.push("char", "q")
  assert(coroutine.status(m.app) ~= "dead", "Closing the board must return to the hub")
  m.push("char", "q")
  assert(coroutine.status(m.app) == "dead")
end)

test("panel opens the opt-in board and returns to its tabs", function()
  local mocks = dofile("tests/mocks.lua")
  local f = fixture()
  local m = mocks.new(false, {})
  local native = m.env.term.native()
  setmetatable(m.env.term, { __index = native })
  m.env.term.current = function() return native end
  m.env.term.isColour = native.isColor
  m.env.term.setCursorBlink = function() end
  m.env.settings = { get = function(key, default) if key == "wh2.enabled" then return true end return default end }
  m.env.sleep = function() m.env.os.pullEvent("wizard_test_tick") end
  m.env.require = function(name)
    assert(name == "wh2-board")
    return { open = function(context)
      context.client, context.recipeIndex = f.client, f.context.recipeIndex
      context.cache=f.cache
      f.board = f.env.require("wh2-board").open(context)
      return f.board
    end }
  end
  m.start(source("panel.lua"))
  assert(f.board and #f.board.state.queue==2,"Panel boot must read and show pending questions")
  m.push("char", "i")
  m.push("wizard_test_tick")
  m.push("mouse_click", 1, 2, 3)
  m.push("char", "2")
  m.push("char", "s")
  m.push("wizard_test_tick")
  assert(f.classes["example:raw_tin"].route == "fuel")
  m.push("wizard_test_tick")
  m.push("char", "q")
  assert(coroutine.status(m.app) ~= "dead")
  m.push("char", "q")
  assert(coroutine.status(m.app) == "dead")
end)

test("hub and panel leave the wizard disabled by default on boot",function()
  for _,path in ipairs({"hub.lua","panel.lua"}) do
    local f=fixture()
    local m=application(path,f)
    assert(m.boardLoads==0 and #f.calls==0)
  end
end)

test("empty and failed boot probes preserve the normal screen and later manual entry",function()
  for _,path in ipairs({"hub.lua","panel.lua"}) do
    for _,failed in ipairs({false,true}) do
      local f=fixture()
      f.questions={}
      if failed then f.fail="unavailable" end
      local m=application(path,f,true)
      assert(f.board.state.closed)
      assert(not table.concat(m.output,"\n"):find("Material wizard",1,true))
      m.push("char","i")
      assert(not f.board.state.closed and m.boardLoads==2)
      assert(table.concat(m.output,"\n"):find("Material wizard",1,true))
    end
  end
end)

test("new material selects cooking without overwriting a route picked during lookup", function()
  local f = fixture()
  f.board.tick()
  f.event("key", f.env.keys.enter)
  for _ = 1,6 do f.board.tick() end
  assert(f.board.state.draft.route == "blast")
  assert(f.board.state.draft.recipeId == "example:tin_heat")
  f = fixture()
  f.board.tick()
  f.event("key", f.env.keys.enter)
  f.event("char", "1")
  for _ = 1,6 do f.board.tick() end
  assert(f.board.state.draft.route == "store" and f.board.state.draft.recipeId == false)
end)

test("an open queue polls for later arrivals without reopening skipped items", function()
  local f = fixture()
  local now = 0
  f.context.now = function() return now end
  f.board = f.env.require("wh2-board").open(f.context)
  f.board.tick()
  f.event("char", "s")
  f.questions["example:new_ore"] = f.question("example:new_ore")
  f.revision = f.revision + 1
  now = 2999
  f.board.tick()
  assert(#f.board.state.queue == 1)
  now = 3000
  f.board.tick()
  assert(#f.board.state.queue == 2)
  assert(f.board.state.queue[1] == "example:new_ore")
end)

test("accepted edits reach the local cache before display and disk failure keeps the prior value",function()
  local f=fixture()
  f.board.tick()
  f.event("key",f.env.keys.enter)
  local calls=#f.calls
  f.event("char","2")
  assert(#f.calls==calls)
  assert(f.cache.value.draft.value.answers.route=="fuel")
  assert(f.board.state.draft.route=="fuel")
  f.cacheFail=true
  f.event("char","1")
  assert(f.board.state.draft.route=="fuel" and f.board.state.failure)
  assert(f.cache.value.draft.value.answers.route=="fuel")
end)

test("reboot restores unacknowledged text and fields before uploading the draft",function()
  local f=fixture()
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.event("char","2")
  f.event("char","/")
  f.event("paste","tin choice")
  f.event("key",f.env.keys.enter)
  local saved=f.env.textutils.serialize(f.cache.value)
  assert(f.questions["example:raw_tin"].draft==false)
  f.board=f.env.require("wh2-board").open(f.context)
  f.board.tick()
  assert(f.board.state.view=="answer")
  assert(f.board.state.draft.route=="fuel" and f.board.state.draft.text=="tin choice")
  assert(f.board.state.draft.step=="review" and not f.board.state.draft.stale)
  assert(f.env.textutils.serialize(f.cache.value)==saved)
  f.board.tick()
  local q=f.questions["example:raw_tin"]
  assert(q.state=="answering" and q.draft.editor==17)
  assert(q.draft.answers.route=="fuel" and q.draft.text=="tin choice")
  assert(f.classes["example:raw_tin"]==nil)
end)

test("boot resumes an owned server draft even without the local cache",function()
  local f=fixture()
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.event("char","2")
  f.event("char","c")
  f.board.tick()
  local q=f.questions["example:raw_tin"]
  local revision=q.draft.revision
  f.cache.value={v=1,draft=false}
  f.board=f.env.require("wh2-board").open(f.context)
  f.board.tick()
  assert(f.board.state.view=="answer" and f.board.state.draft.item==q.item)
  assert(f.board.state.draft.route=="fuel" and f.board.state.draft.step=="category")
  assert(f.board.state.draft.draftRevision==revision and not f.board.state.draft.dirty)
end)

test("a conflict preserves local text until the operator explicitly takes over",function()
  local f=fixture()
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.event("char","/")
  f.event("paste","local text")
  f.event("key",f.env.keys.enter)
  local q=f.questions["example:raw_tin"]
  q.state,q.revision="answering",2
  q.draft={v=1,editor=5,revision=1,step="route",updatedAt=0,answers={route="store"},text="server text"}
  f.revision=f.revision+1
  f.board=f.env.require("wh2-board").open(f.context)
  f.board.tick()
  assert(f.board.state.draft.stale and f.board.state.draft.text=="local text")
  local calls=#f.calls
  f.board.tick()
  assert(#f.calls==calls and q.draft.editor==5 and q.draft.text=="server text")
  f.event("char","t")
  f.board.tick()
  q=f.questions["example:raw_tin"]
  assert(q.draft.editor==17 and q.draft.text=="local text")
  assert(not f.board.state.draft.stale and not f.board.state.draft.foreign)
end)

test("discard clears the server draft and cache while keeping the open question",function()
  local f=fixture()
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.event("char","2")
  f.board.tick()
  assert(f.questions["example:raw_tin"].state=="answering")
  f.event("char","x")
  f.board.tick()
  assert(f.questions["example:raw_tin"].state=="open")
  assert(f.questions["example:raw_tin"].draft==false and f.cache.value.draft==false)
  assert(f.classes["example:raw_tin"]==nil)
end)

test("input class and destination category can be changed independently",function()
  local f=fixture()
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.event("char","a")
  assert(f.board.state.draft.class=="any" and f.board.state.draft.storeCategory=="misc")
  f.event("char","a")
  for _=1,3 do f.event("char","c") end
  assert(f.board.state.draft.class=="ores" and f.board.state.draft.storeCategory=="ingots")
  f.event("char","1")
  f.event("char","s")
  f.board.tick()
  local row=f.classes["example:raw_tin"]
  assert(row.class=="ores" and row.storeCategory=="ingots")
end)

test("an acknowledged draft is reconciled after a crash before the local acknowledgement",function()
  local f=fixture()
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.event("char","2")
  local unacknowledged=f.cache.value
  f.board.tick()
  local revision=f.revision
  f.cache.value=unacknowledged
  f.board=f.env.require("wh2-board").open(f.context)
  f.board.tick()
  assert(not f.board.state.draft.stale and not f.board.state.draft.dirty)
  assert(f.board.state.draft.route=="fuel" and f.board.state.draft.draftRevision==1)
  f.board.tick()
  assert(f.revision==revision,"Reboot must not upload an acknowledged draft again")
end)

test("a resolved answer is reconciled after a crash before clearing the local draft",function()
  local f=fixture()
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.event("char","2")
  f.board.tick()
  local pending=f.cache.value
  f.event("char","s")
  f.board.tick()
  assert(f.questions["example:raw_tin"].state=="resolved")
  local revision=f.revision
  f.cache.value=pending
  f.board=f.env.require("wh2-board").open(f.context)
  f.board.tick()
  assert(f.cache.value.draft==false and f.board.state.draft==false)
  assert(f.board.state.view=="queue" and f.revision==revision)
end)

test("recipe suggestions reject the wrong ingredient and unsupported outputs",function()
  for _,recipe in ipairs({
    {id="example:tin_heat",type="minecraft:blasting",inputs={{item="minecraft:sand",count=1}},outputs={{item="example:tin_ingot",count=1,chance=1}}},
    {id="example:tin_heat",type="minecraft:blasting",inputs={{item="example:raw_tin",count=1}},outputs={}},
    {id="example:tin_heat",type="minecraft:blasting",inputs={{item="example:raw_tin",count=1}},outputs={{item="example:tin_ingot",count=1,chance=false}}},
  }) do
    local f=fixture()
    f.context.recipeIndex.getUsesOf=function() return {pages=1,recipes={{id="example:tin_heat"}}} end
    f.context.recipeIndex.getRecipe=function() return recipe end
    f.board.tick()
    f.event("key",f.env.keys.enter)
    f.recipes()
    assert(f.board.state.draft.route=="store" and f.board.state.draft.recipeId==false)
  end
end)

test("cooking suggestions use tag membership and preserve indexed capped alternatives",function()
  for _,input in ipairs({{count=1,tag="example:tin_ores"},
    {count=1,items={"example:other_ore"},more=true}}) do
    local f=fixture()
    f.context.recipeIndex.getUsesOf=function() return {pages=1,recipes={{id="example:tin_heat"}}} end
    f.context.recipeIndex.getRecipe=function()
      return {id="example:tin_heat",type="minecraft:blasting",inputs={input},
        outputs={{item="example:tin_ingot",count=1,chance=1}}}
    end
    f.context.recipeIndex.resolveTag=function(tag)
      assert(tag=="example:tin_ores")
      return {"example:other_ore","example:raw_tin"}
    end
    f.board.tick()
    f.event("key",f.env.keys.enter)
    f.recipes()
    assert(f.board.state.draft.route=="blast" and f.board.state.draft.recipeId=="example:tin_heat")
  end
end)

test("false recipe API fields stay invalid instead of acquiring defaults",function()
  local f=fixture()
  f.context.recipeIndex.getUsesOf=function() return {pages=false,recipes={}} end
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.board.tick()
  assert(f.board.state.failure and f.board.state.draft.route=="store")
  for _,field in ipairs({"time","fluids","steps"}) do
    f=fixture()
    f.context.recipeIndex.getUsesOf=function() return {pages=1,recipes={{id="example:tin_heat"}}} end
    f.context.recipeIndex.getRecipe=function()
      local recipe={id="example:tin_heat",type="minecraft:blasting",inputs={{item="example:raw_tin",count=1}},
        outputs={{item="example:tin_ingot",count=1,chance=1}}}
      recipe[field]=false
      return recipe
    end
    f.board.tick()
    f.event("key",f.env.keys.enter)
    f.recipes()
    assert(f.board.state.draft.route=="store" and f.board.state.draft.recipeId==false)
  end
end)

test("malformed and sparse server pages fail before entering the queue",function()
  for _,mutate in ipairs({
    function(reply) reply.records[1].draft=nil end,
    function(reply) reply.records[1].v=2 end,
    function(reply) reply.records[3]=reply.records[1] end,
    function(reply) reply.cursor=0.5 end,
  }) do
    local f=fixture()
    local original=f.client.call
    f.client.call=function(op,body)
      local reply=original(op,body)
      if op=="wh2-get" and body.topic=="questions" then mutate(reply) end
      return reply
    end
    f.board.tick()
    assert(f.board.state.failure and #f.board.state.queue==0)
  end
end)

test("the real atomic cache recovers the last accepted input after a reboot",function()
  local mocks=dofile("tests/mocks.lua")
  local disk=mocks.new(false)
  local f=fixture()
  f.env.fs=disk.env.fs
  f.context.cache=nil
  f.board=f.env.require("wh2-board").open(f.context)
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.event("char","2")
  local saved=f.env.textutils.unserialize(assert(disk.files["wh2-wizard.cache"]))
  assert(saved.value.draft.value.answers.route=="fuel")
  assert(disk.files["wh2-wizard.cache.bak"])
  f.board=f.env.require("wh2-board").open(f.context)
  f.board.tick()
  assert(f.board.state.draft.route=="fuel" and f.board.state.draft.dirty)
  f.env.fs.getFreeSpace=function() return 0 end
  f.event("char","1")
  assert(f.board.state.draft.route=="fuel" and f.board.state.failure)
  local retained=f.env.textutils.unserialize(disk.files["wh2-wizard.cache"])
  assert(retained.value.draft.value.answers.route=="fuel")
end)

test("oversized text is rejected before it can poison the local cache",function()
  local mocks=dofile("tests/mocks.lua")
  local disk=mocks.new(false)
  local f=fixture()
  f.env.fs=disk.env.fs
  f.context.cache=nil
  f.board=f.env.require("wh2-board").open(f.context)
  f.board.tick()
  f.event("key",f.env.keys.enter)
  f.event("paste",string.rep("x",4096))
  assert(f.board.state.draft.text=="" and f.board.state.failure)
  f.event("paste","valid text")
  assert(f.board.state.draft.text=="valid text")
  local stored=f.env.textutils.unserialize(disk.files["wh2-wizard.cache"])
  assert(stored.value.draft.value.text=="valid text")
end)

print(string.format("Wizard board %d passed, %d failed", passed, failed))
assert(failed == 0, "Wizard board checks failed")
return { passed = passed, failed = failed }
