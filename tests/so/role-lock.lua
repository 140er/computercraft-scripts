-- R1: a display shows one role. Only the server command changes it.
local H = dofile("tests/so/harness.lua")

local function install(machine, files)
  machine.install(files)
  for _, name in ipairs({"x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing"}) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local file = assert(io.open(path, "rb"))
    machine.files[path] = file:read("*a")
    file:close()
  end
end

local function setup(w, h)
  local net = H.new()
  local s = { net = net }
  s.server = net.machine({id=1, modem=true})
  install(s.server, {"so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua",
    "so-plan.lua", "so-mine-plan.lua", "so-lumber-plan.lua", "so-mod-state.lua", "so-mod-display.lua",
    "so-mod-drops.lua", "so-mod-mine.lua", "so-mod-lumber.lua", "so-mod-shop.lua", "so-mod-ar.lua",
    "so-mod-cells.lua", "so-mod-lease.lua", "so-ui.lua", "so-mod-panel.lua", "so-mod-daily.lua", "so-mod-map.lua"})
  s.server.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld", x=0, y=64, z=0}})
  s.server.boot("so-server.lua")
  net.flush()
  assert(not s.server.error, tostring(s.server.error))
  if w then
    s.client = net.machine({id=2, modem=true, width=w, height=h, capacity=1000000})
    install(s.client, {"display.lua", "so-proto.lua", "so-pair.lua", "so-store.lua"})
    local key = string.rep("a", 64)
    assert(s.server.env.SO.pair.remember(s.client.id, key))
    s.client.files["so-keys"] = H.encode({schema=1, generation=1, value={keys={["1"]=key}}})
    s.client.boot("display.lua")
    net.flush()
    net.advance(2)
  end
  s.display = function() return s.server.env.SO.mods.display end
  s.saved = function(id)
    local file = s.server.env.SO.store.read("so-display")
    return file and file.value and file.value.roles[tostring(id)]
  end
  -- The newest frame the paired client received.
  s.frame = function()
    assert(not s.server.error, tostring(s.server.error))
    assert(not s.client.error, tostring(s.client.error))
    for i = #s.server.sent, 1, -1 do
      local packet = s.server.sent[i]
      if packet.id == s.client.id and packet.payload.t == "view.frame" then return packet.payload.body end
    end
    error("display received no frame")
  end
  -- Handlers run inside the server's coroutine in game; SO.breathe yields there.
  s.run = function(fn, ...)
    local co, args = coroutine.create(fn), table.pack(...)
    while true do
      local ok, err = coroutine.resume(co, table.unpack(args, 1, args.n))
      assert(ok, err)
      if coroutine.status(co) == "dead" then return end
      args = table.pack("so-breathe")
    end
  end
  s.get = function(id)
    local got
    s.run(s.display().handlers["view.get"], {from=id}, function(_, body) got = body end)
    return got
  end
  s.input = function(id, body) s.run(s.display().handlers.input, {from=id, body=body}) end
  return s
end

-- Taps every drawn button on every page the role can reach from its own controls.
local function walk(s, equal, id, w, h, role)
  local D = s.display()
  D.handlers.hello({from=id, body={w=w, h=h, keyboard=w == 26}})
  if role then
    local ok, text = D.command(id .. " " .. role)
    assert(ok, text)
  end
  local expected = role == "drops" and "generic" or role or (w == 26 and h == 20 and "pocket" or "unassigned")
  local saved = s.saved(id)
  local tapped, backs, count, pages = {}, {}, 0, {}
  for _ = 1, 400 do
    local f = s.get(id)
    equal(f.role, expected, "role changed at " .. w .. "x" .. h)
    equal(s.saved(id), saved, "saved role changed at " .. w .. "x" .. h)
    -- Route A screens name the page in row 1 before a hairline (the map before its controls);
    -- Big Tiles headers sit in row 2.
    local head = f.rows[1] and f.rows[1].text or ""
    local row = (head:find("%-%-%-") or head:find("^ MAP ")) and head or (f.rows[2] and f.rows[2].text or "")
    local page = (row .. "  "):match("^%s*(.-)%s%s") or ""
    pages[page] = true
    local pick
    for _, b in ipairs(f.buttons) do
      if not tapped[page .. "|" .. b.id] and not b.id:match("^dug%.") then
        pick, tapped[page .. "|" .. b.id] = b, true
        break
      end
    end
    if not pick then
      for _, b in ipairs(f.buttons) do
        if b.id:match("back") or b.id == "items" or b.id == "list" or b.id == "glance" then pick = b break end
      end
      backs[page] = (backs[page] or 0) + 1
      if not pick or backs[page] > 3 then break end
    end
    s.input(id, {id=pick.id, x=pick.x, y=pick.y})
    count = count + 1
  end
  for _, text in ipairs({"status", id .. " mining", "panel", "-"}) do
    s.input(id, {text=text, x=1, y=1})
    equal(s.get(id).role, expected)
    equal(s.saved(id), saved)
  end
  return count, pages
end

return function(test, equal)
  test("role-lock: tapping every button on every role at M, L, P and XS never changes a role", function()
    local s = setup()
    local totals = {}
    for i = 1, 12 do totals["minecraft:item_" .. i] = i * 3 end
    totals["minecraft:iron_ingot"] = 64
    s.server.env.SO.mods.shop.listen.roomsorter_stock(90, {totals=totals})
    for i = 1, 3 do
      assert(s.server.env.SO.mods.drops.add({id="drop" .. i, dim=0, x=i, y=64, z=0, side="down", kind="ore"}))
    end
    s.server.env.SO.mods.state.emit("mine.alert", {text="ore chest full"})
    -- Mining STOP clears mine.alert during the walk; an alert no control clears keeps status
    -- drawing its alert rows at every size.
    s.server.env.SO.mods.state.emit("walk.alert", {text="walk check"})
    s.net.advance(1)
    local roles = {"status", "pocket", "mining", "lumber", "shop", "drops", "ar", "panel", "map", false}
    local reached = {}
    for si, size in ipairs({{57,24}, {39,19}, {26,20}, {15,10}}) do
      for ri, role in ipairs(roles) do
        local id = 100 + si * 20 + ri
        local count, pages = walk(s, equal, id, size[1], size[2], role or nil)
        if role and role ~= "pocket" or size[1] == 26 and not role then
          assert(count > 0, tostring(role) .. " drew no buttons at " .. size[1] .. "x" .. size[2])
        end
        for page in pairs(pages) do reached[page] = true end
      end
    end
    -- Status is STATUS at every size since route A; the pocket's FLEET tab is in tests/ui/r3pocket.lua.
    -- The route A shop names its role, not the page; its tabs and item pane are in tests/ui/ui2c.lua.
    -- Mining and lumber name both of their tabs MINING and LUMBER since route A.
    for _, page in ipairs({"STATUS", "PANEL", "MINING", "LUMBER", "SHOP",
        "DROP POINTS", "ADD DROP POINT", "AR GOGGLES", "MAP", "UNASSIGNED"}) do
      local found = false
      for name in pairs(reached) do found = found or name:sub(1, #page) == page end
      assert(found, "unreached page " .. page)
    end
  end)

  test("role-lock: the server command assigns, changes, rejects and clears; frames and restarts follow it", function()
    local s = setup(57, 24)
    local f = s.frame()
    equal(f.role, "unassigned")
    equal(#f.buttons, 0)
    assert(f.rows[1].text:find("UNASSIGNED", 1, true))
    local D = s.display()
    equal({D.command("2 mining")}, {true, "display 2: mining"})
    s.net.advance(1)
    equal(s.frame().role, "mining")
    equal(s.saved(2), "mining")
    equal({D.assign(2, "drops")}, {true, "display 2: drops"})
    s.net.advance(1)
    equal(s.frame().role, "generic")
    equal(s.saved(2), "generic")
    for _, case in ipairs({{"2 bogus", "roles: status pocket mining lumber shop drops ar panel map health attention alerts events errors disk build"},
        {"77 shop", "no display 77"}, {"x shop", "use <id> <role> or <id> -"}, {"2", "use <id> <role> or <id> -"},
        {"2 shop extra", "use <id> <role> or <id> -"}}) do
      equal({D.command(case[1])}, {false, case[2]})
    end
    equal({D.assign(2.5, "shop")}, {false, "bad display id"})
    equal({D.assign(-1, "shop")}, {false, "bad display id"})
    equal(s.saved(2), "generic")
    assert(D.command("2 shop"))
    s.net.kill(s.server)
    s.server = s.net.boot(s.server)
    s.net.flush()
    s.net.advance(40)
    equal(s.frame().role, "shop", "saved role survives a server restart")
    equal({s.display().command("2 -")}, {true, "display 2: cleared"})
    s.net.advance(1)
    equal(s.frame().role, "unassigned")
    equal(s.saved(2), nil)
  end)

  test("role-lock: R on the server terminal opens the role prompt", function()
    local s = setup(39, 19)
    local function event(...) s.server.inbox[#s.server.inbox + 1] = table.pack(...) end
    local function typed(text) for c in text:gmatch(".") do event("char", c) end end
    event("key", 19, false); event("char", "r")
    typed("2 lum")
    s.net.flush()
    assert(s.server.env.SO.pairCode(2), "panel code request")
    equal(s.server.env.SO.terminal.mode, "role", "a panel code request left the prompt")
    typed("ber"); event("key", 28, false)
    s.net.flush()
    local v = s.server.env.SO.terminal
    equal(v.mode, "role")
    equal(v.notice, "display 2: lumber")
    equal(v.input, "")
    s.net.advance(1)
    equal(s.frame().role, "lumber")
    typed("2 zz"); event("key", 28, false); s.net.flush()
    equal(v.notice, "roles: status pocket mining lumber shop drops ar panel map health attention alerts events errors disk build")
    equal(v.input, "2 zz")
    event("key", 14, false); event("key", 14, false); event("key", 25, false); typed("map"); event("key", 28, false)
    s.net.flush()
    equal(v.notice, "display 2: map")
    equal(s.server.env.SO.terminal.code, s.server.env.SO.pair.pending(), "P inside the prompt renewed pairing")
    s.net.advance(1)
    equal(s.frame().role, "map")
    event("key", 1, false); s.net.flush()
    equal(v.mode, "normal")
    equal(s.saved(2), "map")
  end)

  test("role-lock: terminal role list and unassigned screens match their fixtures", function()
    local R = dofile("tests/ui/render.lua")
    local s = setup()
    s.net.advance(1)
    local D = s.display()
    local function capture(frame, w, h)
      local out = R.capture(w, h)
      for y, row in ipairs(frame.rows) do
        local fg, bg = {}, {}
        for _, run in ipairs(row.runs or {}) do fg[#fg+1], bg[#bg+1] = string.rep(run[2], run[1]), string.rep(run[3], run[1]) end
        fg, bg = table.concat(fg), table.concat(bg)
        if not row.runs then
          fg = #row.fg == 1 and string.rep(row.fg, #row.text) or row.fg
          bg = #row.bg == 1 and string.rep(row.bg, #row.text) or row.bg
        end
        out.setCursorPos(1, y); out.blit(row.text .. string.rep(" ", #fg - #row.text), fg, bg)
      end
      return out
    end
    local view = {id=1, uptime="up 3h12", mode="role", input="6 shop", notice="display 7: status", displays={
      {id=1, size="57x24", role="status"}, {id=2, size="26x20", role="pocket"}, {id=5, size="57x24", role="mining"},
      {id=6, size="57x24", role="unassigned"}, {id=7, size="15x10", role="status"}, {id=9, size="-", role="drops"}}}
    equal(R.diff("tests/ui/fixtures/roles-T.txt", capture(D.terminal({tiles={}}, view, 51, 19), 51, 19)), {})
    for _, size in ipairs({{57, 24, "M"}, {15, 10, "XS"}}) do
      D.handlers.hello({from=6, body={w=size[1], h=size[2]}})
      local frame = s.get(6)
      equal(frame.role, "unassigned")
      equal(R.diff("tests/ui/fixtures/unassigned-" .. size[3] .. ".txt", capture(frame, size[1], size[2])), {})
    end
    D.handlers.hello({from=6, body={w=26, h=20}})
    equal(s.get(6).role, "pocket")
    D.handlers.hello({from=8, body={w=57, h=24}})
    assert(D.assign(8, "drops"))
    local term = s.server.env.term
    term.blit = function() end
    local v = s.server.env.SO.terminal
    v.mode = "role"
    D.drawTerminal(0)
    equal(v.displays, {{id=6, size="26x20", role="pocket"}, {id=8, size="57x24", role="drops"}})
  end)

  test("role-lock: a tap on the previous role's frame is ignored until the new frame arrives", function()
    local s = setup(57, 24)
    local D = s.display()
    assert(D.command("2 mining"))
    s.net.advance(1)
    local start
    for _, b in ipairs(s.frame().buttons) do if b.id == "start" then start = b end end
    assert(start, "mining START")
    local hits = 0
    local lumber = D.screen("lumber")
    D.screen("lumber", lumber.render, function() hits = hits + 1 end)
    assert(D.command("2 lumber"))
    s.client.inbox[#s.client.inbox + 1] = table.pack("mouse_click", 1, start.x, start.y)
    s.net.flush()
    equal(hits, 0)
    s.net.advance(1)
    equal(s.frame().role, "lumber")
    s.client.inbox[#s.client.inbox + 1] = table.pack("mouse_click", 1, start.x, start.y)
    s.net.flush()
    equal(hits, 1)
  end)

  test("role-lock: pockets drop navigation roles saved before R1; other displays keep theirs", function()
    local m = H.new().machine({id=1, capacity=16000000})
    m.install({"so-store.lua", "so-ui.lua", "so-mod-display.lua"})
    local e = m.env
    e.SO = {now=function() return e.os.epoch("utc") end, mods={}, store=e.dofile("so-store.lua"),
      proto={ser=H.encode}, pair={key=function() return "key" end}}
    assert(e.SO.store.store("so-display", function() return true end).save({roles={["2"]="panel", ["3"]="mining",
      ["4"]="status"}, far={}}))
    local function boot()
      local d = e.dofile("so-mod-display.lua")
      for _, role in ipairs({"panel", "mining"}) do d.screen(role, function() return {rows={}, buttons={}} end) end
      local function frame(id, w, h)
        d.handlers.hello({from=id, body={w=w, h=h, fullH=h}})
        local got
        d.handlers["view.get"]({from=id}, function(_, body) got = body end)
        return got
      end
      return d, frame
    end
    local d, frame = boot()
    equal(frame(2, 26, 20).role, "pocket")
    equal(frame(3, 57, 24).role, "mining")
    local old = frame(4, 26, 19)
    equal(old.role, "pocket")
    equal(#old.rows, 19)
    assert(old.rows[1].text:find("^ FLEET"), "26x19 pockets keep the fleet page")
    equal({d.assign(2, "panel")}, {true, "display 2: panel"})
    equal(frame(2, 26, 20).role, "panel")
    d, frame = boot()
    equal(frame(2, 26, 20).role, "panel", "a commanded pocket role survives restart")
    equal(frame(4, 26, 20).role, "pocket")
    equal(frame(3, 57, 24).role, "mining")
  end)

  test("role-lock: kit-free servers still draw the role prompt", function()
    local m = H.new().machine({id=1, capacity=16000000})
    m.install({"so-store.lua", "so-mod-display.lua"})
    local e = m.env
    e.SO = {now=function() return 0 end, mods={}, store=e.dofile("so-store.lua"), proto={ser=H.encode},
      pair={key=function() return "key" end}}
    local d = e.dofile("so-mod-display.lua")
    local frame = d.terminal({tiles={}}, {mode="role", input="8 drops", notice="no display 9",
      displays={{id=8, size="29x12", role="unassigned"}}}, 51, 19)
    local text = {}
    for _, row in ipairs(frame.rows) do text[#text + 1] = row.text end
    equal(text, {"roles", "8 29x12 unassigned", "no display 9", "> 8 drops_"})
  end)

  test("role-lock: long notices wrap and long display lists end with a count", function()
    local s = setup()
    local view = {id=1, mode="role", input="", notice="roles: status pocket mining lumber shop drops ar panel map health attention alerts events errors disk build",
      displays={}}
    for i = 1, 20 do view.displays[i] = {id=i, size="57x24", role="status"} end
    local frame = s.display().terminal({tiles={}}, view, 51, 19)
    local text = {}
    for y, row in ipairs(frame.rows) do text[y] = row.text end
    assert(text[17]:find("roles: status pocket mining", 1, true), text[17])
    assert(text[18]:find("panel map", 1, true), text[18])
    assert(text[16]:find("+", 1, true) and text[16]:find("more", 1, true), text[16])
    assert(text[15]:find("^ +12 "), text[15])
  end)
end
