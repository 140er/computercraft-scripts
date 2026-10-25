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

local function setup(w, h, existing)
  local net = existing and existing.net or H.new()
  local server = existing and existing.server or net.machine({id=1, modem=true})
  if not existing then
  install(server, {"so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua",
    "so-plan.lua", "so-mine-plan.lua", "so-lumber-plan.lua", "so-mod-state.lua", "so-mod-display.lua",
    "so-mod-drops.lua", "so-mod-mine.lua", "so-mod-lumber.lua", "so-mod-shop.lua", "so-mod-ar.lua",
    "so-mod-cells.lua", "so-mod-lease.lua"})
  server.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld", x=0, y=64, z=0}})
  server.boot("so-server.lua")
  net.flush()
  assert(not server.error, tostring(server.error))
  end
  local client = net.machine({id=existing and 3 or 2, modem=true, monitor=w==29, width=w, height=h, capacity=1000000})
  install(client, {"display.lua", "so-proto.lua", "so-pair.lua", "so-store.lua"})
  client.env.term.write = function(text)
    local x, y = client.cx or 1, client.cy or 1
    local row = (client.screen[y] or "") .. string.rep(" ", w)
    client.screen[y] = (row:sub(1, x-1) .. text .. row:sub(x+#text)):sub(1, w)
    client.cx = x + #text
  end
  local key = string.rep("a", 64)
  assert(server.env.SO.pair.remember(client.id, key))
  client.files["so-keys"] = H.encode({schema=1, generation=1, value={keys={["1"]=key}}})
  client.boot("display.lua")
  net.flush()
  net.advance(2)
  assert(server.env.SO.mods.display.assign(client.id, "drops"))
  net.advance(1)
  local function frame()
    assert(not server.error, tostring(server.error))
    assert(not client.error, tostring(client.error))
    for i=#server.sent,1,-1 do
      local packet = server.sent[i]
      if packet.id==client.id and packet.payload.t=="view.frame" then return packet.payload.body end
    end
    error("display received no frame")
  end
  local function button(label)
    local picture = frame()
    for _, b in ipairs(picture.buttons) do
      if b.label==label and b.x>=1 and b.y>=1 and b.y<=h and b.x+b.w-1<=w and #b.label<=b.w then
        assert((client.screen[b.y] or ""):sub(b.x,b.x+#label-1)==label, label .. " is overwritten")
        for _, other in ipairs(picture.buttons) do
          if other~=b and other.y==b.y then
            assert(b.x+b.w<=other.x or other.x+other.w<=b.x, label .. " overlaps another button")
          end
        end
        return b
      end
    end
    error("no visible " .. label .. " button on " .. picture.role .. " at " .. w .. "x" .. h)
  end
  local function press(label)
    local b = button(label)
    client.inbox[#client.inbox+1] = table.pack(w==29 and "monitor_touch" or "mouse_click",
      w==29 and "monitor" or 1, b.x, b.y)
    net.flush()
  end
  local function typeText(text)
    for ch in text:gmatch(".") do client.inbox[#client.inbox+1] = table.pack("char", ch) end
    client.inbox[#client.inbox+1] = table.pack("key", 28)
    net.flush()
  end
  return {net=net, server=server, client=client, frame=frame, button=button, press=press, typeText=typeText}
end

-- The route A drops screen on a bare machine, with an idle turtle 12 at 118,64,-336.
local R = dofile("tests/ui/render.lua")
local function routeA()
  local m = H.new().machine({id=1, capacity=16000000})
  m.install({"so-store.lua", "so-ui.lua", "so-mod-drops.lua"})
  m.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld", x=0, y=64, z=0}, setupMovement=true})
  local e = m.env
  local t = {alerts = {}}
  e.SO = {now=function() return 1000 end, mods={}, store=e.dofile("so-store.lua"), pair={key=function() return "key" end}}
  e.SO.mods.state = {emit=function(key, value) if key == "drops.alert" then t.alerts[#t.alerts+1] = value end end}
  e.SO.mods.display = {screen=function(_, render, input) t.render, t.input = render, input end}
  e.SO.mods.lease = {candidates=function() return {12} end, status=function() return {} end,
    world=function(id) if id == 12 then return {dim="minecraft:overworld", x=118, y=64, z=-336} end return nil, "turtle not paired" end}
  t.mod = e.dofile("so-mod-drops.lua")
  t.mod.tick()
  for i = 1, 30 do
    local name, value = debug.getupvalue(t.mod.tick, i)
    if name == "S" then t.S = value break end
  end
  t.tap = function(session, id) t.input({id=id, session=session, from=session.id}) end
  t.type = function(session, text) t.input({text=text, session=session, from=session.id}) end
  t.ids = function(session, w, h)
    local out = {}
    for _, b in ipairs(t.render(w or 26, h or 20, session).buttons) do out[b.id] = b end
    return out
  end
  t.text = function(session, w, h)
    local out = {}
    for y, row in ipairs(t.render(w or 26, h or 20, session).rows) do out[y] = row.text end
    return table.concat(out, "\n")
  end
  return t
end

local function capture(frame, w, h)
  local out = R.capture(w, h)
  for y, row in ipairs(frame.rows) do
    local fg, bg = {}, {}
    for _, r in ipairs(row.runs or {}) do fg[#fg+1] = string.rep(r[2], r[1]) bg[#bg+1] = string.rep(r[3], r[1]) end
    fg, bg = table.concat(fg), table.concat(bg)
    out.setCursorPos(1, y)
    out.blit(row.text .. string.rep(" ", #fg - #row.text), fg, bg)
  end
  return out
end

-- B3-U: the real cells, lease and drops modules on one server, with worker 9 paired, fenced and
-- silent for five minutes. cfg is so-server.cfg; reboot keeps the files.
local function cellsRig(cfg, files)
  local net = H.new()
  local m = net.machine({id=1, directories=true, capacity=16000000})
  m.install({"so-store.lua", "so-ui.lua", "so-plan.lua", "so-mod-cells.lua", "so-mod-lease.lua", "so-mod-drops.lua"})
  for path, bytes in pairs(files or {}) do m.files[path] = bytes end
  cfg.pos = cfg.pos or {dim="minecraft:overworld", x=0, y=64, z=0}
  m.files["so-server.cfg"] = H.encode(cfg)
  local e, t = m.env, {net=net, m=m, sent={}}
  e.rednet.send = function(_, wire) t.sent[#t.sent+1] = wire return true end
  e.SO = {now=function() return net.time end, mods={}, store=e.dofile("so-store.lua"), breathe=function() end,
    pair={key=function() return "key" end},
    proto={build=function(_, kind, body) return {t=kind, body=body} end, encode=function(v) return v end}}
  e.SO.mods.state = {emit=function() end}
  e.SO.mods.display = {screen=function(_, render, input) t.render, t.input = render, input end}
  t.cells = e.dofile("so-mod-cells.lua") e.SO.mods.cells = t.cells
  t.lease = e.dofile("so-mod-lease.lua") e.SO.mods.lease = t.lease
  t.mod = e.dofile("so-mod-drops.lua") e.SO.mods.drops = t.mod
  t.lease.handlers.hello({from=9, body={role="worker", dim="minecraft:overworld",
    capabilities={setupFence=true, parkBatch=true}, journal={id="before", pose={x=0,y=0,z=0,f=0}}}})
  net.time = net.time + 300000
  t.mod.tick()
  t.report = function(lid, change)
    local body = {lease=lid, journal="after", pose={x=0,y=0,z=0,f=0},
      results={{ok=true, data={dim="minecraft:overworld", x=4, y=5, z=6}}}}
    if change then change(body) end
    t.lease.handlers["step.report"]({from=9, body=body}, function() end)
    t.mod.tick()
  end
  t.config = function(next)
    next.pos = cfg.pos
    m.files["so-server.cfg"] = H.encode(next)
    for i = 1, 30 do
      local name, value = debug.getupvalue(t.mod.tick, i)
      if name == "S" then value.ctx = nil end
    end
  end
  t.tap = function(session, id) t.input({id=id, session=session, from=session.id}) end
  t.ids = function(session, w, h)
    local out = {}
    for _, b in ipairs(t.render(w or 26, h or 20, session).buttons) do out[b.id] = b end
    return out
  end
  t.text = function(session, w, h)
    local out = {}
    for y, row in ipairs(t.render(w or 26, h or 20, session).rows) do out[y] = row.text end
    return table.concat(out, "\n")
  end
  return t
end

return function(test, equal)
  for _, size in ipairs({{26,20}, {29,12}}) do
    test("paged drop editor and typed input at " .. size[1] .. "x" .. size[2], function()
      local s = setup(size[1], size[2])
      local drops = s.server.env.SO.mods.drops
      local function check()
        for _, b in ipairs(s.frame().buttons) do
          assert(b.w == #b.label and b.x + b.w - 1 <= size[1] and b.y < size[2])
          assert((s.client.screen[b.y] or ""):sub(b.x,b.x+b.w-1)==b.label, "button is overwritten")
          for _, other in ipairs(s.frame().buttons) do
            if other~=b and other.y==b.y then
              assert(b.x+b.w<=other.x or other.x+other.w<=b.x, "buttons overlap")
            end
          end
        end
        for _, label in ipairs({"prev", "next",
            "kind", "side", "add", "dim+", "dim-", "x+", "x-", "y+", "y-", "z+", "z-"}) do s.button(label) end
        for _, b in ipairs(s.frame().buttons) do
          for _, role in ipairs({"mining", "lumber", "shop", "status", "ar", "generic"}) do assert(b.id ~= role, role) end
        end
      end
      check()
      s.typeText("1250 72 -900")
      s.press("add")
      equal(#drops.list(), 1)
      equal({drops.list()[1].x, drops.list()[1].y, drops.list()[1].z}, {1250,72,-900})
      s.typeText("-1 -1200 70 100")
      s.press("side")
      s.press("add")
      equal(drops.list()[2].dim, -1)
      equal(drops.list()[2].side, "down")
      s.typeText("add fuel 1300 64 -910 front 1")
      equal(#drops.list(), 3)
      equal(drops.list()[3].kind, "fuel")
      equal(drops.list()[3].dim, 1)
      for _, text in ipairs({"add bad 1 2 3", "1 2 nope", "0 1.5 2 3", "add ore 1 2 3 up 0", "1 2"}) do
        s.typeText(text)
        equal(#drops.list(), 3, "bad command added a point")
        local message = s.frame().rows[#s.frame().rows].text
        assert(message:find("bad") or message:find("integers") or message:find("use"), message)
      end
      s.press("add")
      equal(#drops.list(), 3, "invalid input changed the draft")
      for i=4,20 do assert(drops.add({id="point" .. i, dim=0, x=i, y=64, z=0, side="front", kind="ore"})) end
      s.net.advance(1)
      local seen = {}
      for page=1,20 do
        check()
        for _, b in ipairs(s.frame().buttons) do
          local id = b.id:match("^fix:(.+)$")
          if id then seen[id]=true end
        end
        s.press("next")
      end
      local count=0
      for _ in pairs(seen) do count=count+1 end
      equal(count,20,"some points cannot be reached")
      s.press("prev")
      check()
      local picture=s.frame()
      local file=assert(io.open("tests/evidence/drop-editor/" .. size[1] .. "x" .. size[2] .. ".txt", "w"))
      file:write("Mock display client, " .. size[1] .. "x" .. size[2] .. "; bottom row reserved for input\n")
      for y=1,size[2] do file:write(string.format("%02d |%-" .. size[1] .. "s|\n",y,s.client.screen[y] or "")) end
      file:close()
      local target
      for _, b in ipairs(picture.buttons) do if b.label=="fix" then target=b.id:sub(5) break end end
      for i=1,3 do assert(drops.note(target,nil)) end
      s.press("fix")
      for _, p in ipairs(drops.list()) do if p.id==target then equal(p.broken,false) end end
      s.press("remove")
      equal(#drops.list(),20)
      s.press("confirm")
      equal(#drops.list(),19)
      check()
    end)
  end
  test("drop paging is independent between pocket and monitor", function()
    local monitor = setup(29,12)
    local pocket = setup(26,20,monitor)
    for i=1,20 do assert(monitor.server.env.SO.mods.drops.add({id="p" .. i,
      dim=0,x=i,y=64,z=0,side="front",kind="ore"})) end
    monitor.net.advance(1)
    for i=1,19 do
      pocket.press("prev")
      monitor.press("next")
    end
    local found=false
    for _, b in ipairs(monitor.frame().buttons) do if b.id=="remove:p20" then found=true end end
    assert(found,"monitor cannot reach last point while pocket is subscribed")
    monitor.press("remove")
    monitor.press("confirm")
    equal(#monitor.server.env.SO.mods.drops.list(),19)
    pocket.press("next")
    pocket.button("remove")
  end)

  test("U4-A typed test 2 and room 2 on use the list number; test 9 with two points is missing", function()
    local t = routeA()
    local a = {id=7}
    assert(t.mod.add({id="p1", kind="ore", dim=0, x=110, y=64, z=-340, side="front"}))
    assert(t.mod.add({id="p2", kind="wood", dim=0, x=112, y=64, z=-340, side="front"}))
    local tested, run = {}, t.S.testPoint
    t.S.testPoint = function(id, turtle) tested[#tested+1] = t.S.find(id) and id return run(id, turtle) end
    t.type(a, "test p2")
    local byId = t.S.message
    t.type(a, "test 2")
    equal(tested, {"p2", "p2"})
    equal(t.S.message, byId)
    t.type(a, "test 9")
    equal({#tested, t.S.message}, {2, "missing point"})
    t.type(a, "room 2 on")
    equal({t.S.message, t.mod.list()[2].room}, {"room saved", true})
    t.type(a, "room 9 on")
    equal(t.S.message, "missing point")
  end)

  test("U4-A a found chest opens with the display's last kind, and ADD returns to FOUND", function()
    local t = routeA()
    local a, b = {id=7}, {id=8}
    t.S.candidates = {{dim=0, x=121, y=64, z=-340, side="down", block="minecraft:chest"}}
    -- No earlier draft: ore.
    t.tap(b, "testing")
    t.tap(b, "candidate:1")
    equal(t.S.views[8].draft.kind, "ore")
    -- BACK from a FOUND editor goes back to chest setup.
    t.tap(b, "list")
    equal({t.S.views[8].testing, t.S.views[8].editing}, {true, false})
    -- After a fuel point, the next found chest opens as fuel.
    t.type(a, "add fuel 100 64 -340")
    equal(t.mod.list()[1].kind, "fuel")
    t.tap(a, "testing")
    t.tap(a, "candidate:1")
    equal(t.S.views[7].draft.kind, "fuel")
    t.tap(a, "add")
    equal({#t.mod.list(), t.mod.list()[2].kind, t.mod.list()[2].side}, {2, "fuel", "down"})
    equal({t.S.views[7].testing, t.S.views[7].editing}, {true, false})
    -- The chest stays listed, so a second kind can go on it.
    assert(t.ids(a)["candidate:1"], "found chest gone after ADD")
    t.tap(a, "candidate:1")
    t.tap(a, "kind")
    t.tap(a, "add")
    equal({#t.mod.list(), t.mod.list()[3].kind, t.mod.list()[3].x}, {3, "ore", 121})
    assert(t.text(a):find("CHEST SETUP", 1, true) or t.text(a):find("SETUP", 1, true))
    -- An editor opened with NEW still stays open after ADD.
    t.tap(a, "list")
    t.tap(a, "new")
    t.tap(a, "x+")
    t.tap(a, "add")
    equal({#t.mod.list(), t.S.views[7].editing}, {4, true})
  end)

  test("U4-A TEST uses the turtle chosen on the setup page, and a bad choice is refused", function()
    local t = routeA()
    local a = {id=7}
    assert(t.mod.add({id="p1", kind="ore", dim=0, x=110, y=64, z=-340, side="front"}))
    local used, begin = {}, t.S.beginSetup
    t.S.beginSetup = function(id, point, facing) used[#used+1] = id return begin(id, point, facing) end
    t.tap(a, "testing")
    assert(t.ids(a)["turtle:12"], "turtle row cannot be chosen")
    t.tap(a, "turtle:12")
    equal(t.S.views[7].turtle, 12)
    t.tap(a, "test")
    equal(used, {12})
    -- Turtle 12 runs an old worker, so the setup checks refuse it.
    equal(t.S.message, "update worker for setup safety")
    -- A turtle that is no longer idle is refused by the same checks.
    t.S.views[7].turtle = 99
    t.tap(a, "test")
    equal({used[2], t.S.message}, {99, "no unassigned idle turtle"})
    t.type(a, "test 1")
    equal(used[3], 99)
    -- A second tap on the chosen row clears it; TEST then takes the first idle turtle.
    t.S.views[7].turtle = 12
    t.tap(a, "turtle:12")
    equal(t.S.views[7].turtle, nil)
  end)

  test("U4-A PREVIEW shows the chosen chest, the fallback or HOLD and emits no alert", function()
    local t = routeA()
    local a = {id=7}
    assert(t.mod.add({id="o1", kind="ore", dim=0, x=110, y=64, z=-340, side="front"}))
    assert(t.mod.add({id="a1", kind="any", dim=0, x=130, y=64, z=-340, side="front"}))
    assert(t.mod.add({id="j1", kind="junk", dim=0, x=125, y=64, z=-336, side="front"}))
    for _ = 1, 3 do t.mod.note("j1") end
    t.tap(a, "testing")
    t.tap(a, "select:o1")
    t.tap(a, "turtle:12")
    local text = t.text(a)
    assert(text:find("PREVIEW #12", 1, true), text)
    assert(text:find(" ore  1 ore 110,64,-340", 1, true), text)
    -- fuel has no chest of its own: the any chest is the fallback.
    for _ = 1, 5 do t.tap(a, "preview-kind") end
    equal(t.S.views[7].previewKind, "fuel")
    assert(t.text(a, 57, 24):find(" fuel  2 any 130,64,-340", 1, true), t.text(a, 57, 24))
    -- junk's own chest is broken, so the any chest serves it; without that one it holds.
    t.S.views[7].previewKind = "junk"
    assert(t.text(a, 57, 24):find(" junk  2 any 130,64,-340", 1, true), t.text(a, 57, 24))
    assert(t.mod.remove("a1"))
    text = t.text(a, 57, 24)
    assert(text:find(" junk  HOLD 2 broken", 1, true), text)
    t.S.views[7].previewKind = "wood"
    text = t.text(a, 57, 24)
    assert(text:find(" wood  HOLD no wood chest set", 1, true), text)
    equal(#t.alerts, 0)
    -- choose is the same selection as pick, without the alert.
    local near = {dim=0, x=118, y=64, z=-336}
    equal(t.mod.choose("junk", near), {chain={{kind="junk", usable=false}, {kind="any", usable=false}, "hold"},
      reason="broken", failedPoint={id="j1", dim=0, x=125, y=64, z=-336, side="front", kind="junk"},
      alert="junk #j1 broken at 125,64,-336"})
    equal(#t.alerts, 0)
    local picked = t.mod.pick("junk", near)
    equal({picked.reason, picked.alert, #t.alerts}, {"broken", "junk #j1 broken at 125,64,-336", 1})
    equal(t.mod.choose("ore", near).point.id, t.mod.pick("ore", near).point.id)
    equal(#t.alerts, 1)
  end)

  test("U4-A the dimension filter is per display, filters before paging and keeps point numbers", function()
    local t = routeA()
    local a, b = {id=7}, {id=8}
    assert(t.mod.add({id="w1", kind="ore", dim=0, x=5, y=64, z=5, side="front"}))
    assert(not t.ids(a).dims, "filter shown with one dimension")
    assert(t.mod.add({id="n1", kind="ore", dim=-1, x=5, y=64, z=5, side="front"}))
    for i = 1, 30 do assert(t.mod.add({id="w" .. (i + 1), kind="fuel", dim=0, x=10 + i, y=64, z=5, side="front"})) end
    assert(t.mod.add({id="e1", kind="ore", dim=1, x=5, y=64, z=5, side="front"}))
    local function listed(session)
      local out = {}
      for _, row in ipairs(t.render(26, 20, session).rows) do
        local n = row.text:match("^ (%d+) ")
        if n then out[#out+1] = tonumber(n) end
      end
      return out
    end
    assert(t.ids(a).dims, "no filter with three dimensions")
    t.tap(a, "dims")
    equal(t.S.views[7].dim, 0)
    assert(t.text(a):find("WORLD", 1, true))
    local world = listed(a)
    equal(world[1], 1)
    for _, n in ipairs(world) do assert(n ~= 2 and n ~= 33, "other dimension on WORLD") end
    t.tap(a, "dims")
    equal(listed(a), {2})
    assert(t.ids(a)["select:n1"] and not t.ids(a)["select:w1"], "same coordinates shown in both dimensions")
    t.tap(a, "dims")
    equal(listed(a), {33})
    -- The other display still lists every point from page 1.
    equal(listed(b)[1], 1)
    t.tap(a, "dims")
    equal(t.S.views[7].dim, nil)
    -- The selection stays inside the filter: REMOVE on NETHER removes the nether point.
    t.tap(a, "select:w1")
    t.tap(a, "dims")
    t.tap(a, "dims")
    t.tap(a, "remove")
    t.tap(a, "remove")
    equal(#t.mod.list(), 32)
    for _, p in ipairs(t.mod.list()) do assert(p.id ~= "n1") end
  end)

  test("U4-A the NETHER filter and PREVIEW match their fixtures", function()
    local s3 = dofile("tests/ui/s3.lua")
    local drops
    for i = 1, 40 do local k, v = debug.getupvalue(s3, i) if k == "drops" then drops = v end end
    local paths = {["dropsdim-P"] = "tests/ui/fixtures/dropsdim-P.txt",
      ["dropspreview-M"] = "tests/ui/fixtures/dropspreview-M.txt", ["dropspreview-P"] = "tests/ui/fixtures/dropspreview-P.txt"}
    local t = assert(drops, "s3 drops")()
    local env
    for i = 1, 30 do local k, v = debug.getupvalue(t.mod.tick, i) if k == "_ENV" then env = v end end
    env.SO.mods.lease.world = function() return {dim="minecraft:overworld", x=118, y=64, z=-336} end
    t.S.points[3].dim = -1
    local a = {id=21}
    t.tap(a, "dims")
    t.tap(a, "dims")
    equal(R.diff(paths["dropsdim-P"], capture(t.render(26, 20, a), 26, 20)), {})
    t.S.points[3].dim = 0
    for i, c in ipairs({{"dropspreview-M", 57, 24}, {"dropspreview-P", 26, 20, true}}) do
      local session = {id=30 + i}
      t.tap(session, "testing")
      t.tap(session, "turtle:12")
      if c[4] then t.tap(session, "preview-kind") end
      equal(R.diff(paths[c[1]], capture(t.render(c[2], c[3], session), c[2], c[3])), {})
    end
    equal(t.saves, 0)
    local started, pipe = pcall(io.popen, "pwd")
    local root = started and pipe and pipe:read("*l")
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= "/" or not os.execute("python3 -V > /dev/null 2>&1") then
      return dofile("tests/skips.lua").record("U4-A drops generator", "needs host processes, a POSIX shell and python3")
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' dropsdim-P dropspreview-M dropspreview-P > /dev/null"))
    for name, path in pairs(paths) do
      local f1, f2 = assert(io.open(dir .. "/" .. name .. ".txt", "rb")), assert(io.open(path, "rb"))
      equal(f1:read("*a"), f2:read("*a"))
      f1:close()
      f2:close()
    end
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)

  test("U4-A a number names only a list row: with a point whose id is 9, test 9 and room 9 on are missing", function()
    local t = routeA()
    local a = {id=7}
    assert(t.mod.add({id="p1", kind="ore", dim=0, x=110, y=64, z=-340, side="front"}))
    assert(t.mod.add({id="9", kind="ore", dim=0, x=112, y=64, z=-340, side="front"}))
    local tested, run = {}, t.S.testPoint
    t.S.testPoint = function(id, turtle) tested[#tested+1] = id return run(id, turtle) end
    t.type(a, "test 9")
    equal({tested[1], t.S.message}, {false, "missing point"})
    t.type(a, "room 9 on")
    equal({t.S.message, t.mod.list()[2].room}, {"missing point", nil})
    t.type(a, "test 2")
    equal(tested[2], "9")
    t.type(a, "test p1")
    equal(tested[3], "p1")
  end)

  test("U4-A the dimension filter stays on screen through all four states at 15x10", function()
    local t = routeA()
    local a = {id=7}
    assert(t.mod.add({id="n1", kind="ore", dim=-1, x=5, y=64, z=5, side="front"}))
    for i = 1, 20 do assert(t.mod.add({id="w" .. i, kind="fuel", dim=0, x=10 + i, y=64, z=5, side="front"})) end
    for _, want in ipairs({{0, "OVW"}, {-1, "NTH"}, {1, "END"}, {nil, "ALL"}}) do
      local before = t.ids(a, 15, 10).dims
      assert(before, "no filter at 15x10")
      t.tap(a, "dims")
      equal(t.S.views[7].dim, want[1])
      local frame = t.render(15, 10, a)
      local chip
      for _, b in ipairs(frame.buttons) do if b.id == "dims" then chip = b end end
      assert(chip and chip.label == want[2], "filter chip missing or wrong on " .. want[2])
      for _, b in ipairs(frame.buttons) do
        assert(b == chip or b.y ~= 1 or b.x > chip.x + chip.w - 1, "filter chip overlaps " .. b.id)
      end
    end
  end)

  test("B8-U saved FOUND and suspension screens match the twin at every size", function()
    local s3 = dofile("tests/ui/s3.lua")
    local drops
    for i = 1, 40 do local k, v = debug.getupvalue(s3, i) if k == "drops" then drops = v end end
    local paths = {"tests/ui/fixtures/dropssaved-M.txt", "tests/ui/fixtures/dropssaved-P.txt", "tests/ui/fixtures/dropssaved-XS.txt"}
    for i, size in ipairs({{57,24}, {26,20}, {15,10}}) do
      local t, a = assert(drops)(), {id=7}
      local env
      for j = 1, 30 do local k,v = debug.getupvalue(t.mod.tick,j) if k == "_ENV" then env=v end end
      local read = env.SO.store.read
      env.SO.store.read = function(path)
        local value = read(path)
        if path == "so-server.cfg" then value.dropsSavedSetup = true end
        return value
      end
      for _, p in ipairs(t.S.points) do p.suspended = i > 1 or nil end
      t.tap(a,"testing")
      local frame = t.render(size[1],size[2],a)
      equal(R.diff(paths[i],capture(frame,size[1],size[2])),{})
      assert(#H.encode(frame) < 16000, "oversized frame")
      for _, b in ipairs(frame.buttons) do
        assert(b.x >= 1 and b.y >= 1 and b.x+b.w-1 <= size[1] and b.y <= size[2],b.id)
        for _, other in ipairs(frame.buttons) do
          assert(b == other or b.y ~= other.y or b.x+b.w <= other.x or other.x+other.w <= b.x,b.id .. " overlaps " .. other.id)
        end
      end
      local found = false
      for _=1,20 do
        for _, b in ipairs(t.render(size[1],size[2],a).buttons) do if b.id == "candidate:1" then found=true end end
        t.tap(a,"from-next")
      end
      assert(found,"FOUND unreachable")
    end
  end)


  test("B3-U a kept setup route RELEASE waits for the fenced GPS fix and keeps the route until then", function()
    local t, a = cellsRig({worldEdits=true}), {id=7}
    assert(t.cells.reserveMany("setup:9", {{"minecraft:overworld",4,5,6}, {"minecraft:overworld",7,5,6}}))
    t.tap(a, "testing")
    equal(t.ids(a)["kept:9"].label, "release")
    assert(t.text(a):find("KEPT", 1, true) and t.text(a):find("#9 2", 1, true), t.text(a))
    -- The first tap takes the cells module's token and sends nothing; another tap disarms.
    t.tap(a, "kept:9")
    equal(#t.sent, 0)
    equal(t.ids(a)["kept:9"].label, "CONFIRM")
    t.tap(a, "turtle:9")
    equal(t.ids(a)["kept:9"].label, "release")
    t.tap(a, "kept:9")
    equal(#t.sent, 0)
    t.tap(a, "kept:9")
    equal(#t.sent, 1)
    equal(t.sent[1].body.steps, {{op="gps", park=true}})
    equal(t.cells.owner(7,5,6), "setup:9")
    equal(t.cells.owner(4,5,6), "setup:9")
    assert(t.text(a):find("#9 2 WAIT GPS", 1, true), t.text(a))
    equal(t.ids(a)["kept:9"], nil)
    t.report(t.sent[1].body.lease)
    equal(t.cells.owner(7,5,6), nil)
    equal(t.cells.owner(4,5,6), "gps:9")
    assert(not t.text(a):find("KEPT", 1, true), t.text(a))
  end)

  test("B3-U a failed fenced GPS fix keeps the kept route and offers RELEASE again", function()
    local t, a = cellsRig({worldEdits=true}), {id=7}
    assert(t.cells.reserveMany("setup:9", {{"minecraft:overworld",4,5,6}, {"minecraft:overworld",7,5,6}}))
    t.tap(a, "testing")
    t.tap(a, "kept:9")
    t.tap(a, "kept:9")
    t.report(t.sent[1].body.lease, function(body) body.journal = "before" end)
    equal(t.cells.owner(7,5,6), "setup:9")
    equal(t.cells.owner(4,5,6), "setup:9")
    assert(t.text(a):find("#9 2 HELD", 1, true), t.text(a))
    equal(t.ids(a)["kept:9"].label, "release")
  end)

  test("B3-U no kept route, AREAS or box control is drawn or acts while its flag is off", function()
    local t, a = cellsRig({}), {id=7}
    assert(t.cells.reserveMany("setup:9", {{"minecraft:overworld",4,5,6}}))
    t.tap(a, "testing")
    local ids = t.ids(a)
    equal(ids["kept:9"], nil)
    equal(ids.areas, nil)
    assert(not t.text(a):find("KEPT", 1, true))
    t.tap(a, "kept:9") t.tap(a, "kept:9")
    t.tap(a, "areas")
    equal(t.ids(a)["area-protect"], nil)
    t.tap(a, "area-protect") t.tap(a, "area-keep") t.tap(a, "clear-marks") t.tap(a, "clear-marks")
    equal(#t.sent, 0)
    equal(t.cells.owner(4,5,6), "setup:9")
    equal(#t.cells.protected().boxes, 0)
    equal(#t.cells.keep(), 0)
    -- protectedAreas alone draws PROTECT, not KEEP, CLEAR MARKS or the kept list.
    t.config({protectedAreas=true})
    ids = t.ids(a)
    equal(ids["kept:9"], nil)
    t.tap(a, "areas")
    ids = t.ids(a)
    assert(ids["area-protect"])
    equal(ids["area-keep"], nil)
    equal(ids["clear-marks"], nil)
    t.tap(a, "area-keep")
    equal(#t.cells.keep(), 0)
  end)

  test("B3-U AREAS protects, keeps and clears marks with two-tap removal and the cells confirmation", function()
    local t, a = cellsRig({protectedAreas=true, worldEdits=true}), {id=7}
    t.tap(a, "testing")
    t.tap(a, "areas")
    -- The draft starts at 0,64,0; z2 moves to 1.
    for _ = 1, 6 do t.tap(a, "area-field") end
    t.tap(a, "area+")
    t.tap(a, "area-protect")
    local boxes = t.cells.protected().boxes
    equal(#boxes, 1)
    equal({boxes[1].id, boxes[1].x1, boxes[1].y1, boxes[1].z1, boxes[1].z2}, {"p1", 0, 64, 0, 1})
    assert(t.text(a):find("PROTECTED 1", 1, true), t.text(a))
    t.tap(a, "unprotect:p1")
    equal(#t.cells.protected().boxes, 1)
    equal(t.ids(a)["unprotect:p1"].label, "CONFIRM")
    t.tap(a, "unprotect:p1")
    equal(#t.cells.protected().boxes, 0)
    t.tap(a, "area-keep")
    equal(t.cells.keep()[1].id, "k1")
    t.tap(a, "unkeep:k1")
    t.tap(a, "area-field")
    t.tap(a, "unkeep:k1")
    equal(#t.cells.keep(), 1)
    t.tap(a, "unkeep:k1") t.tap(a, "unkeep:k1")
    equal(#t.cells.keep(), 0)
    assert(t.cells.markDug(0, 64, 1))
    t.cells.tick(t.net.time)
    t.tap(a, "clear-marks")
    equal(t.cells.isDug(0, 64, 1), true)
    equal(t.ids(a)["clear-marks"].label, "CONFIRM")
    t.tap(a, "clear-marks")
    equal(t.cells.isDug(0, 64, 1), false)
    assert(t.text(a):find("marks cleared", 1, true), t.text(a))
  end)


  test("B3-U kept-route and AREAS screens match the twin fixtures", function()
    local s3 = dofile("tests/ui/s3.lua")
    local drops
    for i = 1, 40 do local k, v = debug.getupvalue(s3, i) if k == "drops" then drops = v end end
    local function rig(flags)
      local t, env = assert(drops)(), nil
      for j = 1, 30 do local k, v = debug.getupvalue(t.mod.tick, j) if k == "_ENV" then env = v end end
      local read = env.SO.store.read
      env.SO.store.read = function(path)
        local value = read(path)
        if path == "so-server.cfg" then for k, v in pairs(flags) do value[k] = v end end
        return value
      end
      local held = {}
      for _, k in ipairs({{9, 6}, {14, 3}, {21, 11}}) do
        for i = 1, k[2] do held[#held+1] = {x=i, y=64, z=k[1], who="setup:" .. k[1]} end
      end
      env.SO.mods.cells = {
        reserved = function(dim) return dim == "minecraft:overworld" and held or {} end,
        releaseStatus = function(who) return ({["setup:9"]={status="pending"}, ["setup:14"]={status="held"}})[who] end,
        releaseRequest = function() return {status="confirm", token="t"} end,
        clearMarks = function() return {status="confirm", token="t", sections=2} end,
        protect = function() return true end,
        protected = function() return {boxes={{id="p1", dim="minecraft:overworld", x1=100, y1=60, z1=-350, x2=130, y2=90, z2=-320},
          {id="p2", dim="minecraft:the_nether", x1=-20, y1=40, z1=10, x2=-10, y2=50, z2=20}}} end,
        keep = function() return {{id="k1", dim="minecraft:overworld", x1=140, y1=-60, z1=-380, x2=170, y2=-40, z2=-360}} end,
      }
      return t
    end
    local cases = {{"dropskept-M", 57, 24, false, "tests/ui/fixtures/dropskept-M.txt"},
      {"dropskept-P", 26, 20, true, "tests/ui/fixtures/dropskept-P.txt"},
      {"dropskept-XS", 15, 10, false, "tests/ui/fixtures/dropskept-XS.txt"},
      {"dropsareas-M", 57, 24, false, "tests/ui/fixtures/dropsareas-M.txt"},
      {"dropsareas-P", 26, 20, true, "tests/ui/fixtures/dropsareas-P.txt"},
      {"dropsareas-XS", 15, 10, false, "tests/ui/fixtures/dropsareas-XS.txt"}}
    for _, c in ipairs(cases) do
      local areas = c[1]:match("areas") ~= nil
      local t, a = rig(areas and {protectedAreas=true, worldEdits=true} or {worldEdits=true}), {id=7}
      t.tap(a, "testing")
      if areas then
        t.tap(a, "areas")
        t.S.views[7].box = {dim="minecraft:overworld", x1=110, y1=64, z1=-340, x2=126, y2=80, z2=-330}
        t.tap(a, "area-field")
        if c[4] then t.tap(a, "clear-marks") end
      elseif c[4] then t.tap(a, "kept:21") end
      local frame = t.render(c[2], c[3], a)
      equal(R.diff(c[5], capture(frame, c[2], c[3])), {})
      assert(#H.encode(frame) < 16000, "oversized frame")
      for _, b in ipairs(frame.buttons) do
        assert(b.x >= 1 and b.y >= 1 and b.x+b.w-1 <= c[2] and b.y <= c[3], b.id)
        for _, other in ipairs(frame.buttons) do
          assert(b == other or b.y ~= other.y or b.x+b.w <= other.x or other.x+other.w <= b.x, b.id .. " overlaps " .. other.id)
        end
      end
    end
    local started, pipe = pcall(io.popen, "pwd")
    local root = started and pipe and pipe:read("*l")
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= "/" or not os.execute("python3 -V > /dev/null 2>&1") then
      return dofile("tests/skips.lua").record("B3-U drops generator", "needs host processes, a POSIX shell and python3")
    end
    local dir = os.tmpname()
    os.remove(dir)
    local names = {}
    for _, c in ipairs(cases) do names[#names+1] = c[1] end
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' " .. table.concat(names, " ") .. " > /dev/null"))
    for _, c in ipairs(cases) do
      local f1, f2 = assert(io.open(dir .. "/" .. c[1] .. ".txt", "rb")), assert(io.open(c[5], "rb"))
      equal(f1:read("*a"), f2:read("*a"))
      f1:close()
      f2:close()
    end
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)

end
