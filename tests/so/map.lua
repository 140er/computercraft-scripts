local H = dofile("tests/so/harness.lua")
local R = dofile("tests/ui/render.lua")
local U = dofile("so-ui.lua")

-- tests/ui/map-scene.txt is the one scene behind the generator's fixtures and these tests.
local FIXTURES = {["26x20"]="tests/ui/fixtures/map-26x20.txt", ["29x12"]="tests/ui/fixtures/map-29x12.txt",
  ["57x24"]="tests/ui/fixtures/map-57x24.txt", ["39x19"]="tests/ui/fixtures/map-39x19.txt",
  ["15x10"]="tests/ui/fixtures/map-15x10.txt", ["100x38"]="tests/ui/fixtures/map-100x38.txt"}

local function loadScene()
  local s = {dug={}, reserve={}, turtles={}, drops={}, spots={}, views={}}
  for line in io.lines("tests/ui/map-scene.txt") do
    local a, n = {}, {}
    for word in line:gmatch("%S+") do
      a[#a+1] = word
      if #a > 1 and word:match("^%-?%d+$") then n[#n+1] = tonumber(word) end
    end
    if a[1] == "server" then s.server = {dim="minecraft:overworld", x=n[1], y=n[2], z=n[3]}
    elseif a[1] == "mine" then
      s.mine = {dim="minecraft:overworld", home={x=n[1], y=n[2], z=n[3], facing=n[4]}, homeSet=true,
        bottom=n[5], length=n[6], mode=a[8], branches=n[7], turtles={}}
    elseif a[1] == "dug" or a[1] == "reserve" then
      local b = {}
      for i = #a - 5, #a do b[#b+1] = tonumber(a[i]) end
      for x = b[1], b[4] do for y = b[2], b[5] do for z = b[3], b[6] do
        if a[1] == "dug" then s.dug[#s.dug+1] = {x=x, y=y, z=z}
        else s.reserve[#s.reserve+1] = {x=x, y=y, z=z, who=a[2], dim="minecraft:overworld"} end
      end end end
    elseif a[1] == "turtle" then
      s.turtles[#s.turtles+1] = {id=n[1], pose={x=n[2], y=n[3], z=n[4], facing=n[5]}, state=a[7], open=a[8] == "open"}
    elseif a[1] == "drop" then
      s.drops[#s.drops+1] = {kind=a[2], dim=0, x=n[1], y=n[2], z=n[3], broken=a[6] == "broken"}
    elseif a[1] == "saplings" then s.saplings = {x=n[1], y=n[2], z=n[3]}
    elseif a[1] == "farm" then s.area, s.ground = {x1=n[1], z1=n[2], x2=n[3], z2=n[4]}, n[5]
    elseif a[1] == "spot" then s.spots[#s.spots+1] = {x=n[1], z=n[2], ready=a[4] == "ready"}
    elseif a[1] == "view" then
      local w, h = a[2]:match("(%d+)x(%d+)")
      local v = {w=tonumber(w), h=tonumber(h), map={level=a[3] == "all" and "all" or tonumber(a[3]), fit=a[4] == "fit", zoom=0, cx=0, cz=0}}
      local rest = 5
      if a[4] == "zoom" then v.map.zoom, v.map.cx, v.map.cz, rest = tonumber(a[5]), tonumber(a[6]), tonumber(a[7]), 8 end
      if a[rest] == "focus" then v.map.focus = {x=tonumber(a[rest+1]), z=tonumber(a[rest+2])} end
      s.views[#s.views+1] = v
    end
  end
  return s
end

local function setup(opts)
  opts = opts or {}
  local scene = loadScene()
  local net = H.new()
  local m = net.machine({id=1, modem=true, directories=true, monitor=opts.monitor, width=26, height=20})
  m.install({"so-store.lua","so-mod-map.lua","so-mod-display.lua","so-ui.lua","so-proto.lua","so-mod-cells.lua"})
  if opts.monitor then
    local target = R.capture(26,20)
    target.setTextScale = function() end
    local find = m.env.peripheral.find
    m.env.peripheral.find = function(kind) if kind == "monitor" then return target end return find(kind) end
    m.env.peripheral.getName = function() return "monitor" end
  end
  m.files["so-server.cfg"] = H.encode({pos=scene.server})
  local t = {scene=scene, machine=m, net=net, calls=0, lost=nil}
  local lumber = {dim="minecraft:overworld", area=scene.area, ground=scene.ground, spots=scene.spots, saplings=scene.saplings}
  local open = {}
  for _, row in ipairs(scene.turtles) do
    if row.state == "lumber" then lumber.turtle = {id=row.id, pose=row.pose, state=row.state}
    else scene.mine.turtles[row.id] = {pose=row.pose, state=row.state, dim="minecraft:overworld"} end
    open[row.id] = row.open
  end
  t.mine, t.lumber = scene.mine, lumber
  local store = m.env.dofile("so-store.lua")
  m.env.SO = {now=function() return m.env.os.epoch("utc") end, store=store, proto=m.env.dofile("so-proto.lua"),
    breathe=function() end, pair={key=function() return "key" end}, mods={
    mine={mapView=function() return t.mine end}, lumber={mapView=function() return t.lumber end},
    state={get=function() return {} end},
    lease={status=function(id) return {open=open[id] and "l" or nil, lost=t.lost==id or nil} end, inRange=function() return true end},
    drops={list=function() return scene.drops end}}}
  local cells = m.env.dofile("so-mod-cells.lua")
  for _, p in ipairs(scene.dug) do assert(cells.markDug(p.x, p.y, p.z)) end
  local byWho = {}
  for _, c in ipairs(scene.reserve) do byWho[c.who] = byWho[c.who] or {} table.insert(byWho[c.who], c) end
  for who, list in pairs(byWho) do assert(cells.reserveMany(who, list)) end
  local real = cells.dugBits
  t.probes = 0
  cells.dugBits = function(...)
    if select(5, ...) then t.probes = t.probes + 1 else t.calls = t.calls + 1 end
    return real(...)
  end
  m.env.SO.mods.cells = cells
  t.cells = cells
  local d = m.env.dofile("so-mod-display.lua")
  m.env.SO.mods.display = d
  local map = m.env.dofile("so-mod-map.lua")
  m.env.SO.mods.map = map
  map.tick(0)
  d.tick(0)
  t.map, t.display, t.screen = map, d, d.screen("map")
  t.now = 0
  t.step = function() t.now = t.now + 1000 map.tick(m.env.SO.now()) end
  -- Renders until every dug plane in view is loaded; returns the frame and the per-frame reads.
  t.settle = function(w, h, session, limit)
    local frame, most = nil, 0
    for _ = 1, limit or 60 do
      local before = t.calls
      frame = t.screen.render(w, h, session)
      most = math.max(most, t.calls - before)
      if session.map.ready then break end
      t.step()
    end
    assert(session.map.ready, "dug planes never finished loading")
    return frame, most
  end
  return t
end

local function picture(frame,w,h)
  local out=R.capture(w,h)
  for y,row in ipairs(frame.rows) do
    local fg,bg="",""
    if row.runs then
      for _,r in ipairs(row.runs) do fg=fg..string.rep(r[2],r[1]) bg=bg..string.rep(r[3],r[1]) end
    else
      fg=#row.fg==1 and string.rep(row.fg,#row.text) or row.fg
      bg=#row.bg==1 and string.rep(row.bg,#row.text) or row.bg
    end
    out.setCursorPos(1,y)
    out.blit(row.text..string.rep(" ",#fg-#row.text),fg,bg)
  end
  return out
end
-- Whether the sextant pixel for block x,z is lit; nil under a marker or outside the map.
local function lit(out, v, x, z)
  local px, pz = math.floor((x - v.left) / v.scale), math.floor((z - v.top) / v.scale)
  if px < 0 or pz < 0 or px >= v.pw or pz >= v.ph then return nil end
  local cell = out.cells[v.L.my + math.floor(pz / 3)][v.L.mx + math.floor(px / 2)]
  local byte = cell[1]:byte()
  if byte == 32 then return false, cell end
  if byte < 128 or byte > 159 then return nil end
  local bits = byte - 128
  if cell[2] == "f" and cell[3] ~= "f" then bits = 63 - bits end
  return math.floor(bits / 2 ^ ((pz % 3) * 2 + px % 2)) % 2 == 1, cell
end
local function button(frame,id,w,h)
  for _,b in ipairs(frame.buttons) do if b.id==id then
    assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,"button bounds")
    if id ~= "map-pick" then
      local row=frame.rows[b.y+math.floor((b.h or 1)/2)].text
      assert(row:sub(b.x,b.x+b.w-1):find("%S"),"button is drawn")
    end
    for _,other in ipairs(frame.buttons) do if b~=other then
      assert(b.x+b.w<=other.x or other.x+other.w<=b.x or b.y+(b.h or 1)<=other.y
        or other.y+(other.h or 1)<=b.y,"overlapping map control")
    end end
    return b
  end end
  error("missing drawn button "..id)
end
local CONTROLS = {"map-fit","map-in","map-out","map-n","map-s","map-w","map-e","map-level","map-pick"}

return function(test,equal)
  for index = 1, #loadScene().views do
    local view = loadScene().views[index]
    local w, h = view.w, view.h
    test("map fixture "..w.."x"..h.." draws the scene from real dug marks", function()
      local s = setup()
      local session = {map={}}
      for k, value in pairs(view.map) do session.map[k] = value end
      local frame, most = s.settle(w, h, session)
      assert(most <= 16 + 24, "dug reads per frame "..most)
      local out = picture(frame, w, h)
      local diffs = R.diff(R.load(assert(FIXTURES[w.."x"..h], "fixture path")), out.picture())
      equal(#diffs, 0, table.concat(diffs, "\n"))
      local v, level, area = session.map, session.map.level, s.scene.area
      local farm = level == "all" or level >= s.scene.ground and level <= s.scene.ground + 8
      local checked = 0
      for _, p in ipairs(s.scene.dug) do
        local inFarm = farm and p.x >= area.x1 and p.x <= area.x2 and p.z >= area.z1 and p.z <= area.z2
        if (level == "all" or p.y == level) and not inFarm then
          local on = lit(out, v, p.x, p.z)
          if on ~= nil then equal(on, true, "tunnel pixel at "..p.x..","..p.y..","..p.z) checked = checked + 1 end
        end
      end
      assert(checked > 0, "no dug marks in view")
      if v.scale <= 1 then
        for _, p in ipairs({{150,-347},{175,-363},{130,-379}}) do
          if lit(out, v, p[1], p[2]) ~= nil then equal(lit(out, v, p[1], p[2]), false, "solid rock at "..p[1]..","..p[2]) end
        end
      end
      for _, id in ipairs(CONTROLS) do if id ~= "map-up" then button(frame, id, w, h) end end
      if w >= 23 then button(frame, "map-up", w, h) button(frame, "map-down", w, h) end
    end)
  end

  test("map pan, zoom and FIT move the view and keep the focus in place", function()
    local s = setup()
    local session = {}
    s.settle(57, 24, session)
    local v = session.map
    equal(v.fit, true) equal(v.zoom, 0) equal(v.cx, 140) equal(v.cz, -359)
    local function press(id, x, y) s.screen.input({id=id, x=x, y=y, session=session}) return s.settle(57, 24, session) end
    press("map-e") equal(v.fit, false) equal(v.cx, 140 + math.floor(v.pw / 3)) equal(v.cz, -359)
    press("map-s") equal(v.cz, -359 + math.floor(v.ph / 3))
    press("map-w") press("map-n") equal(v.cx, 140) equal(v.cz, -359)
    press("map-out") equal(v.zoom, 1) equal(v.scale, 2)
    for _ = 1, 12 do press("map-out") end
    equal(v.zoom, 8)
    for _ = 1, 12 do press("map-in") end
    equal(v.zoom, -1) equal(v.scale, 0.5)
    press("map-fit") equal(v.fit, true) equal(v.zoom, 0) equal(v.cx, 140)
    -- Tap a turtle, then zoom: it stays in the same character.
    local x, y = v.L.mx + math.floor((160 - v.left) / 2), v.L.my + math.floor((-373 - v.top) / 3)
    local frame = press("map-pick", x, y)
    assert(frame.rows[2].text:find("#2 MINING 160,-58,-373", 1, true), "turtle readout")
    for _, id in ipairs({"map-in", "map-out", "map-out"}) do
      frame = press(id)
      local cx, cy = math.floor(math.floor((v.focus.x - v.left) / v.scale) / 2), math.floor(math.floor((v.focus.z - v.top) / v.scale) / 3)
      assert(math.abs(cx - (x - v.L.mx)) <= 1 and math.abs(cy - (y - v.L.my)) <= 1, id .. " keeps the focus")
    end
    press("map-fit")
    frame = press("map-pick", x, y)
    equal(v.focus, nil, "second tap clears the focus")
    equal(frame.rows[2].text:match("^%s*MAP%s*$") ~= nil, true, "empty readout")
  end)

  test("map level control steps, cycles and filters by y", function()
    local s = setup()
    local session = {}
    local frame = s.settle(39, 19, session)
    local v = session.map
    local function press(id) s.screen.input({id=id, session=session}) return s.settle(39, 19, session) end
    local function label() local b = button(frame, "map-level", 39, 19) return frame.rows[b.y].text:sub(b.x, b.x + b.w - 1):match("%S+") end
    equal(v.level, "all") equal(label(), "ALL")
    frame = press("map-level") equal(v.level, -58) equal(label(), "Y-58")
    frame = press("map-up") equal(v.level, -57)
    local out = picture(frame, 39, 19)
    v = session.map
    equal(select(1, lit(out, v, 136, -350)), true, "vein above the branch at y -57")
    equal(lit(out, v, 150, -345), false, "branch 0 is not on y -57")
    frame = press("map-down") frame = press("map-down") equal(v.level, -59)
    out = picture(frame, 39, 19)
    equal(lit(out, v, 165, -346), true, "pocket below the level")
    frame = press("map-level") equal(v.level, "all")
    frame = press("map-level") equal(v.level, -58)
    frame = press("map-level") equal(v.level, 64) equal(label(), "Y64")
    out = picture(frame, 39, 19)
    local found
    for _, row in ipairs(frame.rows) do if row.text:find("O", 1, true) then found = true end end
    assert(found, "surface level shows the ore drop")
    frame = press("map-level") equal(v.level, "all")
    -- ALL is a max projection: the y -59 pocket and the y -58 branches both show.
    out = picture(frame, 39, 19)
    equal(lit(out, v, 165, -346), true)
  end)

  test("map work per tick is bounded and an idle map does no dug reads", function()
    local s = setup()
    local session = {map={level="all", fit=false, zoom=-1, cx=140, cz=-360}}
    local frame, most = s.settle(164, 81, session)
    assert(most <= 16 + 24, "cold frame reads "..most)
    -- Nothing changed: after the first sweep the same frame comes back and no section is read.
    for _ = 1, 10 do s.step() s.screen.render(164, 81, session) end
    frame = s.screen.render(164, 81, session)
    local before = s.calls
    for _ = 1, 5 do s.step() equal(s.screen.render(164, 81, session), frame) end
    equal(s.calls, before, "idle map read dug sections")
    local probes = s.probes
    for _ = 1, 3 do s.step() end
    equal(s.probes, probes, "idle map probed dug sections")
    -- A new dug mark beside turtle #2 shows within two ticks, with bounded reads.
    equal(lit(picture(frame, 164, 81), session.map, 165, -374), false, "rock before the mark")
    assert(s.cells.markDug(165, -58, -374))
    for _ = 1, 2 do
      local reads, probes = s.calls, s.probes
      s.step()
      frame = s.screen.render(164, 81, session)
      assert(s.calls - reads <= 16 + 24, "update reads "..(s.calls - reads))
      assert(s.probes - probes <= 64 + 24, "update probes "..(s.probes - probes))
    end
    local out = picture(frame, 164, 81)
    equal(lit(out, session.map, 165, -374), true, "new tunnel pixel")
  end)

  test("map shows marks in sections that left the cells cache before the sweep", function()
    local s = setup()
    local session = {map={level=-58, fit=false, zoom=0, cx=150, cz=-370}}
    local frame = s.settle(29, 12, session)
    equal(lit(picture(frame, 29, 12), session.map, 165, -374), false)
    assert(s.cells.markDug(165, -58, -374))
    -- Planning reads elsewhere push the section out of the 256-section cache.
    local version = s.cells.dugVersion()
    for i = 1, 300 do s.cells.isDug(5000 + i * 16, 0, 5000) end
    equal(s.cells.dugVersion(), version, "probed empty sections stay out of the column index")
    for _ = 1, 4 do s.step() frame = s.screen.render(29, 12, session) end
    equal(lit(picture(frame, 29, 12), session.map, 165, -374), true, "new tunnel pixel after eviction")
  end)

  test("map orders numeric and named turtle ids without failing", function()
    local s = setup()
    for _, id in ipairs({"9", "10", "1a", "b"}) do
      s.mine.turtles[id] = {pose={x=130, y=-58, z=-347, facing=0}, state="mining"}
    end
    s.step()
    s.settle(57, 24, {})
  end)

  test("map dug reads stay inside the budget at the widest zoom", function()
    local s = setup()
    for x = 0, 40 do assert(s.cells.markDug(x * 16, 0, x * 16)) end
    local session = {map={level="all", fit=false, zoom=8, cx=0, cz=0}}
    local _, most = s.settle(164, 81, session)
    assert(most <= 16 + 24, "reads per frame "..most)
  end)

  test("cells map queries are read-only and do not load sections", function()
    local s = setup()
    local cells = s.cells
    local columns = cells.dugColumns("minecraft:overworld", 7, -24, 7, -22)
    local found
    for _, col in ipairs(columns) do if col.sx == 7 and col.sz == -22 then found = col end end
    assert(found, "shaft column listed")
    equal(found.sy[1], -4) equal(found.sy[#found.sy], 4)
    local bits = cells.dugBits("minecraft:overworld", 7, -4, -22)
    equal(#bits, 1024)
    equal(cells.dugBits("minecraft:overworld", 70, 0, 70), nil)
    local list = cells.reserved("minecraft:overworld")
    equal(cells.reserved("minecraft:overworld"), list, "cached until reservations change")
    assert(cells.reserve("mine:9", 0, 0, 0))
    assert(cells.reserved("minecraft:overworld") ~= list, "new list after a reservation")
    -- Push the oldest section out of the 256-section cache; the map still reads it from disk.
    for i = 1, 260 do assert(cells.markDug(1000 + i * 16, 0, 1000)) end
    assert(cells.tick(0))
    local column = cells.dugColumns("minecraft:overworld", 7, -22, 7, -22)[1]
    local evicted
    for _, sy in ipairs(column.sy) do
      if cells.dugBits("minecraft:overworld", 7, sy, -22, true) == false then evicted = sy break end
    end
    assert(evicted, "a shaft section left the cache")
    local files = {}
    for path, bytes in pairs(s.machine.files) do files[path] = bytes end
    local _, marks = cells.dugVersion()
    equal(#cells.dugBits("minecraft:overworld", 7, evicted, -22), 1024)
    equal(cells.dugBits("minecraft:overworld", 7, evicted, -22, true), false, "disk read does not cache")
    for path, bytes in pairs(s.machine.files) do equal(files[path], bytes, "map query wrote "..path) end
    equal(select(2, cells.dugVersion()), marks)
  end)

  test("map view state and caches belong to each display", function()
    local s, a, b = setup(), {}, {}
    s.screen.render(26,20,a) s.screen.render(26,20,b)
    s.screen.input({id="map-out",session=a}) s.screen.input({id="map-e",session=a})
    s.screen.input({id="map-level",session=a})
    equal(b.map.fit,true) equal(b.map.level,"all")
    s.screen.render(29,12,b)
    equal(a.map.level,-58)
    assert(a.map.raster ~= b.map.raster)
  end)

  test("map taps under a retirement banner hit the right cell", function()
    local s = setup()
    local session = {h=24}
    s.settle(57, 22, session)
    local v = session.map
    local x, y = v.L.mx + math.floor((160 - v.left) / 2), v.L.my + math.floor((-373 - v.top) / 3)
    s.screen.input({id="map-pick", x=x, y=y + 2, session=session})
    local frame = s.settle(57, 22, session)
    assert(frame.rows[2].text:find("#2 MINING", 1, true), "banner offset applied")
  end)

  test("map turtle colours follow state and lost leases", function()
    local s = setup()
    s.mine.turtles[2].state = "idle" s.mine.turtles[2].pose.facing = 0
    s.lost = 3
    local session = {map={level=-58, fit=false, zoom=0, cx=150, cz=-370}}
    s.step()
    local out = picture(s.settle(29, 12, session), 29, 12)
    local v = session.map
    for _, t in ipairs({{160,-373,"^","1"},{142,-377,">","e"}}) do
      local cell = out.cells[v.L.my + math.floor((t[2] - v.top) / 3)][v.L.mx + math.floor((t[1] - v.left) / 2)]
      equal(cell[1], t[3]) equal(cell[3], t[4])
    end
  end)

  test("map follows a kit header on row 2 and other headers carry no MAP link", function()
    local s = setup()
    s.display.screen("panel", function(cw, ch) local c = U.canvas(cw, ch) c.header("PANEL", "22:14") return c.frame() end, function() end)
    s.display.handlers.hello({from=22,body={w=26,h=20,fullH=20}})
    assert(s.display.assign(22,"panel"))
    local frame
    s.display.handlers["view.get"]({from=22,body={}},function(_,body) frame=body end)
    for _,b in ipairs(frame.buttons) do assert(b.id~="map","header MAP link") end
    local session={}
    frame=s.screen.render(26,20,session)
    equal(session.map.headerRow,2)
    equal(frame.rows[1].text:match("%S"),nil,"blank padding above map")
    assert(frame.rows[2].text:find("MAP",1,true),"map header stays on row 2")
  end)

  test("map snapshots copy mining and lumber world data, with tree spots", function()
    local s = setup()
    local m = s.machine
    m.install({"so-plan.lua","so-mine-plan.lua","so-lumber-plan.lua","so-mod-mine.lua","so-mod-lumber.lua"})
    local mine = m.env.dofile("so-mod-mine.lua")
    local lumber = m.env.dofile("so-mod-lumber.lua")
    mine.mapView().home.x = 999
    equal(mine.mapView().home.x, 0)
    local input
    m.env.SO.mods.display = {screen=function(role,_,i) if role=="lumber" then input=i end end}
    m.env.SO.mods.lease = nil
    lumber.tick(0)
    input({text="area -5 -3 -3 -1 64"})
    input({text="saplings -1 64 2 front"})
    local view = lumber.mapView()
    equal(view.area.x1,-5) equal(view.ground,64) equal(view.saplings.z,2)
    equal(type(view.spots), "table")
    view.area.x1 = 999 view.saplings.z = 999
    equal(lumber.mapView().area.x1,-5) equal(lumber.mapView().saplings.z,2)
  end)

  test("local monitor map controls keep a separate session",function()
    local s=setup({monitor=true})
    local D
    for i=1,20 do
      local name,value=debug.getupvalue(s.display.monitorTouch,i)
      if name=="D" then D=value break end
    end
    assert(D and D.monitor,"local monitor discovered")
    local function press(id)
      local b=button(D.monitor.frame,id,26,20)
      s.display.monitorTouch("monitor",b.x,b.y)
      s.display.tick(1000)
    end
    assert(s.display.assign(1,"map")) s.display.tick(1000) equal(D.monitor.role,"map")
    press("map-out") press("map-e") press("map-level")
    equal(D.monitor.session.map.fit,false)
    local other={}
    s.screen.render(26,20,other)
    equal(other.map.fit,true) equal(other.map.level,"all")
    for _,b in ipairs(D.monitor.frame.buttons) do assert(b.id~="map-back","map links back") end
    assert(s.display.assign(1,"-")) s.display.tick(2000) equal(D.monitor.role,"status")
  end)

  test("map renders complete large frames inside the protocol limit",function()
    local s=setup()
    -- A dense mine: 40 branches dug side by side.
    for k = 1, 40 do for x = 121, 184 do assert(s.cells.markDug(x, -58, -341 - 2 * k)) end end
    s.step()
    for _, view in ipairs({{164,81,{}}, {164,81,{map={level="all",fit=false,zoom=-1,cx=150,cz=-380}}}, {100,38,{}}, {57,24,{}}}) do
      local w, h, session = view[1], view[2], view[3]
      s.settle(w,h,session)
      s.display.handlers.hello({from=22,body={w=w,h=h,fullH=h}})
      assert(s.display.assign(22,"map"))
      local frame
      s.display.handlers["view.get"]({from=22,body={}},function(_,body) frame=body end)
      local proto=s.machine.env.SO.proto
      local wire,err=proto.encode(proto.build(string.rep("a",64),"view.frame",frame))
      assert(wire,w.."x"..h.." frame does not fit: "..tostring(err))
      equal(#frame.rows,h)
      for _, id in ipairs(CONTROLS) do button(frame,id,w,h) end
    end
  end)

  test("map generator writes every map fixture and the map mockups", function()
    local started, pipe = pcall(io.popen, "pwd")
    local root = started and pipe and pipe:read("*l")
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= "/" or not os.execute("test -f docs/ui/mockup-gen.py && python3 -V > /dev/null 2>&1") then
      return dofile("tests/skips.lua").record("map generator writes every map fixture and the map mockups",
        "needs a POSIX shell and python3")
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "/fixtures'"))
    local command = "cd '" .. dir .. "' && python3 -I '" .. root .. "/docs/ui/mockup-gen.py'"
    assert(os.execute(command .. " > /dev/null"))
    assert(os.execute(command .. " --fixtures fixtures"))
    local function same(a, b) return os.execute("cmp -s '" .. a .. "' '" .. b .. "'") end
    assert(same(dir .. "/map-mockups.md", root .. "/docs/ui/map-mockups.md"), "map-mockups.md differs from the generator")
    for _, v in ipairs(loadScene().views) do
      local name = "map-" .. v.w .. "x" .. v.h .. ".txt"
      assert(FIXTURES[v.w .. "x" .. v.h], "fixture path for " .. name)
      assert(same(dir .. "/fixtures/" .. name, root .. "/tests/ui/fixtures/" .. name), name .. " differs from the generator")
    end
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)

  for _,size in ipairs({{26,20},{29,12},{57,24}}) do
    local w,h=size[1],size[2]
    test("real display client opens and controls the map at "..w.."x"..h,function()
      local net=H.new()
      local server=net.machine({id=1,modem=true})
      local client=net.machine({id=2,modem=true,monitor=w~=26,width=w,height=h,capacity=1000000})
      local function install(machine,files)
        machine.install(files)
        for _,name in ipairs({"x25519","random","blake3","chacha20","config","internal/util",
          "internal/hw","internal/curve25519","internal/fp","internal/edwards25519","internal/packing"}) do
          local path="lib/ccryptolib/"..name..".lua"
          local f=assert(io.open(path,"rb")) machine.files[path]=f:read("*a") f:close()
        end
      end
      install(server,{"so-server.lua","so-proto.lua","so-pair.lua","so-store.lua","so-log.lua",
        "so-plan.lua","so-mine-plan.lua","so-lumber-plan.lua","so-ui.lua","so-mod-state.lua",
        "so-mod-lease.lua","so-mod-cells.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-map.lua",
        "so-mod-mine.lua","so-mod-lumber.lua","so-mod-shop.lua","so-mod-ar.lua","so-mod-panel.lua"})
      server.files["so-server.cfg"]=H.encode({pos={dim="minecraft:overworld",x=0,y=64,z=0}})
      server.boot("so-server.lua") net.flush()
      assert(not server.error,tostring(server.error))
      install(client,{"display.lua","so-proto.lua","so-pair.lua","so-store.lua"})
      local key=string.rep("a",64)
      assert(server.env.SO.pair.remember(2,key))
      client.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
      client.boot("display.lua") net.flush() net.advance(2)
      local function frame()
        assert(not server.error,tostring(server.error)) assert(not client.error,tostring(client.error))
        for i=#server.sent,1,-1 do
          local p=server.sent[i]
          if p.id==2 and p.payload.t=="view.frame" then return p.payload.body end
        end
        error("no map frame")
      end
      local function press(id)
        local b=button(frame(),id,w,h)
        client.inbox[#client.inbox+1]=table.pack(w==26 and "mouse_click" or "monitor_touch",
          w==26 and 1 or "monitor",b.x,b.y)
        net.flush()
      end
      equal(frame().role,w==26 and "pocket" or "unassigned")
      assert(server.env.SO.mods.display.command("2 map")) net.advance(1)
      equal(frame().role,"map") equal(#frame().rows,h)
      for _,id in ipairs({"map-out","map-in","map-n","map-w","map-s","map-e","map-level","map-up","map-down","map-pick","map-fit"}) do
        press(id) equal(frame().role,"map")
      end
      for _,b in ipairs(frame().buttons) do assert(b.id~="map-back","map links back") end
      assert(not server.error and not client.error,"map event loop remains healthy")
    end)
  end
  for _,size in ipairs({{26,20},{29,12},{57,24},{39,19},{15,10}}) do
    local w,h=size[1],size[2]
    test("map is a role of its own and no screen links to it at "..w.."x"..h,function()
      local s=setup()
      local d=s.display
      for _,role in ipairs({"status","generic","mining","lumber","shop","ar","panel"}) do
        d.screen(role,function(cw,ch)
          local c=U.canvas(cw,ch) c.header(role:upper(),"ok")
          return c.frame()
        end,function() end)
      end
      d.handlers.hello({from=22,body={w=w,h=h,fullH=h}})
      local function frame()
        local got
        d.handlers["view.get"]({from=22,body={}},function(_,body) got=body end)
        return assert(got)
      end
      local function press(id)
        local b=button(frame(),id,w,h)
        d.handlers.input({from=22,body={id=id,x=b.x,y=b.y}})
      end
      for _,role in ipairs({"generic","status","mining","lumber","shop","ar","panel"}) do
        assert(d.assign(22,role))
        equal(frame().role,role)
        for _,b in ipairs(frame().buttons) do assert(b.id~="map","MAP link on "..role) end
        d.handlers.input({from=22,body={id="map",x=w-1,y=2}})
        equal(frame().role,role)
      end
      assert(d.assign(22,"map"))
      press("map-out") press("map-n") press("map-level") press("map-pick")
      equal(frame().role,"map")
      local reboot=s.machine.env.dofile("so-mod-display.lua")
      reboot.screen("map",s.screen.render,s.screen.input)
      reboot.handlers.hello({from=22,body={w=w,h=h,fullH=h}})
      local restored
      reboot.handlers["view.get"]({from=22,body={}},function(_,body) restored=body end)
      equal(restored.role,"map","saved map role survives restart")
    end)
  end
end
