local H = dofile("tests/so/harness.lua")
local R = dofile("tests/ui/render.lua")
local U = dofile("so-ui.lua")

-- tests/ui/map-scene.txt (geometry, dug cells, drops, farm, views) and tests/ui/status-scene.txt
-- (turtle states, fuel, ore, leases) are the scene behind docs/ui/schematic/mapscreen.py and these tests.
-- Literal paths, so part runs declare every fixture they read.
local FIXTURES = {["map-57x24"]="tests/ui/fixtures/map-57x24.txt", ["map-100x38"]="tests/ui/fixtures/map-100x38.txt",
  ["map-26x20"]="tests/ui/fixtures/map-26x20.txt", ["map-sel-57x24"]="tests/ui/fixtures/map-sel-57x24.txt",
  ["map-39x19"]="tests/ui/fixtures/map-39x19.txt", ["map-29x12"]="tests/ui/fixtures/map-29x12.txt",
  ["map-15x10"]="tests/ui/fixtures/map-15x10.txt", ["schematic-map-XL"]="tests/ui/fixtures/schematic-map-XL.txt"}
local NORTH = "\24N"

local function words(path)
  local out = {}
  for line in io.lines(path) do
    local a = {}
    for word in line:gmatch("%S+") do a[#a+1] = word end
    if #a > 0 then out[#out+1] = a end
  end
  return out
end
local function loadScene()
  local s = {dug={}, reserve={}, poses={}, drops={}, spots={}, views={}, jobs={}, leases={}, finds={}, oreViews={}}
  for _, a in ipairs(words("tests/ui/map-scene.txt")) do
    local n = {}
    for i = 2, #a do n[#n+1] = tonumber(a[i]) end
    local k = a[1]
    if k == "server" then s.server = {dim="minecraft:overworld", x=n[1], y=n[2], z=n[3]}
    elseif k == "mine" then
      s.mine = {dim="minecraft:overworld", home={x=n[1], y=n[2], z=n[3], facing=n[4]}, homeSet=true,
        bottom=n[5], length=n[6], mode=a[8], branches=tonumber(a[9]), turtles={}}
    elseif k == "dug" or k == "reserve" then
      local b = {}
      for i = #a - 5, #a do b[#b+1] = tonumber(a[i]) end
      for x = math.min(b[1], b[4]), math.max(b[1], b[4]) do for y = math.min(b[2], b[5]), math.max(b[2], b[5]) do
        for z = math.min(b[3], b[6]), math.max(b[3], b[6]) do
          if k == "dug" then s.dug[#s.dug+1] = {x=x, y=y, z=z}
          else s.reserve[#s.reserve+1] = {x=x, y=y, z=z, who=a[2], dim="minecraft:overworld"} end
        end
      end end
    elseif k == "turtle" then s.poses[a[2]] = {x=n[2], y=n[3], z=n[4], facing=n[5]}
    elseif k == "drop" then
      s.drops[#s.drops+1] = {id=#s.drops+1, kind=a[2], dim=0, x=tonumber(a[3]), y=tonumber(a[4]), z=tonumber(a[5]), broken=a[6] == "broken"}
    elseif k == "saplings" then s.saplings = {x=n[1], y=n[2], z=n[3]}
    elseif k == "farm" then s.area, s.ground = {x1=n[1], z1=n[2], x2=n[3], z2=n[4]}, n[5]
    elseif k == "spot" then s.spots[#s.spots+1] = {x=n[1], z=n[2], ready=a[4] == "ready"}
    elseif k == "blueprint" then
      -- blueprint DIM X1 Y1 Z1 X2 Y2 Z2 DONE TOTAL STATE [SEVERITY TEXT...]
      local b = {dim="minecraft:" .. a[2], state=a[11]}
      for i, key in ipairs({"x1","y1","z1","x2","y2","z2","done","total"}) do b[key] = tonumber(a[i + 2]) end
      if a[12] then b.alert = {severity=tonumber(a[12]), text=table.concat(a, " ", 13)} end
      s.build = b
    elseif k == "builder" then
      -- builder ID X Y Z F FUEL AGO
      s.build.id, s.build.pose = a[2], {x=tonumber(a[3]), y=tonumber(a[4]), z=tonumber(a[5]), f=tonumber(a[6])}
      s.build.fuel, s.build.ago = tonumber(a[7]), tonumber(a[8])
    elseif k == "ore-find" then
      s.finds[#s.finds+1] = {seq=tonumber(a[2]), kind="mine.ore", gameAt=-tonumber(a[7]),
        data={name="minecraft:diamond_ore",count=1,
          pos={dim=a[3],x=tonumber(a[4]),y=tonumber(a[5]),z=tonumber(a[6])}}}
    elseif k == "ore-view" then
      local w, h = a[3]:match("(%d+)x(%d+)")
      local v = {name=a[2],w=tonumber(w),h=tonumber(h),map={level=a[4]=="all" and "all" or tonumber(a[4]),fit=a[5]=="fit"}}
      local rest = 6
      if a[5] ~= "fit" then
        local sx, sz = a[5]:match("(%d+)x(%d+)")
        v.map.sx,v.map.sz,v.map.cx,v.map.cz,rest = tonumber(sx),tonumber(sz),tonumber(a[6]),tonumber(a[7]),8
      end
      v.map.oreFinds,v.elapsed = a[rest]=="on",tonumber(a[rest+1])
      if a[rest+2] then v.map.pick={k=a[rest+2],id=a[rest+3]} end
      s.oreViews[#s.oreViews+1]=v
    elseif k == "view" then
      -- view NAME WxH LEVEL fit|SXxSZ CX CZ [turtle ID | drop ID | server | shaft | cell X Z]
      local w, h = a[3]:match("(%d+)x(%d+)")
      local v = {name=a[2], w=tonumber(w), h=tonumber(h), map={level=a[4] == "all" and "all" or tonumber(a[4]), fit=a[5] == "fit"}}
      local rest = 6
      if a[5] ~= "fit" then
        local sx, sz = a[5]:match("(%d+)x(%d+)")
        v.map.sx, v.map.sz, v.map.cx, v.map.cz, rest = tonumber(sx), tonumber(sz), tonumber(a[6]), tonumber(a[7]), 8
      end
      if a[rest] == "turtle" or a[rest] == "drop" then v.map.pick = {k=a[rest], id=a[rest + 1]}
      elseif a[rest] == "cell" then v.map.pick = {k="cell", x=tonumber(a[rest + 1]), z=tonumber(a[rest + 2])}
      elseif a[rest] then v.map.pick = {k=a[rest]} end
      s.views[#s.views+1] = v
    end
  end
  for _, a in ipairs(words("tests/ui/status-scene.txt")) do
    if a[1] == "turtle" then
      s.jobs[#s.jobs+1] = {id=tonumber(a[2]), job=a[3], state=a[4]:gsub("_", " "), fuel=tonumber(a[5]), ore=tonumber(a[6]),
        ago=tonumber(a[7]), at=a[8]}
    elseif a[1] == "lease" then s.leases[tonumber(a[2])] = a[3] end
  end
  return s
end

local function setup(opts)
  opts = opts or {}
  local scene = loadScene()
  local net = H.new()
  local m = net.machine({id=1, modem=true, directories=true, monitor=opts.monitor, width=26, height=20})
  m.install({"so-store.lua","so-mod-map.lua","so-mod-display.lua","so-ui.lua","so-proto.lua","so-mod-cells.lua","so-mod-lease.lua","so-plan.lua"})
  if opts.monitor then
    local target = R.capture(26,20)
    target.setTextScale = function() end
    local find = m.env.peripheral.find
    m.env.peripheral.find = function(kind) if kind == "monitor" then return target end return find(kind) end
    m.env.peripheral.getName = function() return "monitor" end
  end
  m.files["so-server.cfg"] = H.encode({pos=scene.server})
  local t = {scene=scene, machine=m, net=net, calls=0, leases=scene.leases}
  local now = 1700000000000
  local lumber = {dim="minecraft:overworld", area=scene.area, ground=scene.ground, spots=scene.spots, saplings=scene.saplings}
  local machines = {}
  for _, j in ipairs(scene.jobs) do
    local pose = scene.poses[tostring(j.id)]
    machines[tostring(j.id)] = {id=j.id, role="worker", fuel=j.fuel, seen=now - j.ago, pose=pose}
    if j.job == "mine" then
      scene.mine.turtles[tostring(j.id)] = {pose=pose, state=j.state, dim="minecraft:overworld", ores=j.ore,
        lane=j.at == "lane", branch=tonumber(j.at)}
    else
      lumber.turtles = lumber.turtles or {}
      lumber.turtles[tostring(j.id)] = {id=j.id, pose=pose, state="lumber", phase=j.state}
    end
  end
  t.mine, t.lumber, t.machines = scene.mine, lumber, machines
  local store = m.env.dofile("so-store.lua")
  m.env.SO = {now=function() return now + net.time - 1700000000000 end, store=store, proto=m.env.dofile("so-proto.lua"),
    breathe=function() end, pair={key=function() return "key" end}, mods={
    mine={mapView=function() return t.mine end}, lumber={mapView=function() return t.lumber end},
    state={get=function() return t.machines end},
    -- peek reads a lease without creating its row; the map never calls status.
    lease={peek=function(id)
      if type(t.leases[id]) == "table" then return t.leases[id] end
      return {open=t.leases[id] == "open" and "l" or nil, lost=t.leases[id] == "lost" or nil}
    end,
      status=function() t.statusCalls = (t.statusCalls or 0) + 1 return {} end, inRange=function() return true end},
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
  t.reloadMap = function()
    t.map = m.env.dofile("so-mod-map.lua")
    m.env.SO.mods.map = t.map
    t.map.tick(0)
    t.screen = d.screen("map")
  end
  t.step = function() net.advance(1) t.map.tick(m.env.SO.now()) end
  -- Renders until every dug plane in view is loaded; returns the frame and the most reads in one frame.
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
-- The screen cell of block x,z, or nil outside the map.
local function at(v, x, z)
  local cx, cy = math.floor((x - v.left) / v.sx), math.floor((z - v.top) / v.sz)
  if cx < 0 or cy < 0 or cx >= v.mw or cy >= v.mh then return end
  return v.L.mx + cx, v.L.my + cy
end
local function cell(out, v, x, z)
  local cx, cy = at(v, x, z)
  return cx and out.cells[cy][cx]
end
local function button(frame,id,w,h)
  for _,b in ipairs(frame.buttons) do if b.id==id then
    assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,"button bounds "..id)
    if id ~= "map-pick" then
      local row=frame.rows[b.y].text
      assert(row:sub(b.x,b.x+b.w-1):find("%S"),"button is drawn "..id)
    end
    for _,other in ipairs(frame.buttons) do if b~=other then
      assert(b.x+b.w<=other.x or other.x+other.w<=b.x or b.y+(b.h or 1)<=other.y
        or other.y+(other.h or 1)<=b.y,"overlapping map control "..id.." "..other.id)
    end end
    return b
  end end
  error("missing drawn button "..id)
end
local CONTROLS = {"map-fit","map-in","map-out","map-n","map-s","map-w","map-e","map-level","map-up","map-down","map-pick"}
local function row(frame, y) return frame.rows[y].text end
-- The compass: "↑N" at the right end of row 1, outside the map and every control.
local function compass(frame, w, v)
  local text = row(frame, 1)
  assert(text:sub(w - 2, w - 1) == NORTH, "compass at the top right: " .. text)
  assert(v.L.my > 1, "map area below the compass row")
  for _, b in ipairs(frame.buttons) do
    assert(not (b.y == 1 and b.x <= w - 1 and b.x + b.w - 1 >= w - 2), "control over the compass: " .. b.id)
  end
end

local function trailSetup(two)
  local s = setup()
  s.mine, s.lumber, s.scene.drops = {turtles={["8"]={state="idle"}}}, {}, {}
  local m = s.machine
  m.files["so-server.cfg"] = H.encode({remoteDimensions=true})
  m.install({"so-log.lua", "so-mod-state.lua"})
  local state = m.env.dofile("so-mod-state.lua")
  m.env.SO.mods.state = state
  state.emit("machine", {id=8, role="worker", pose={x=0,y=64,z=0,facing=1}})
  if two then
    s.mine.turtles["9"] = {state="idle"}
    state.emit("machine", {id=9, role="worker", pose={x=5,y=64,z=2,facing=0}})
    s.scene.drops = {{id=1,kind="ore",dim=0,x=-5,y=64,z=0}}
  end
  s.pageCalls = {}
  local page = state.history.page
  state.history.page = function(q)
    if q.kind == "pose" then s.pageCalls[#s.pageCalls+1] = q end
    return page(q)
  end
  s.pose = function(id, x, y, z, dim)
    assert(state.emit("pose", {id=id,x=x,y=y,z=z,dim=dim or "minecraft:overworld",facing=1}))
  end
  s.reloadMap()
  return s, state
end

local function mapState(s)
  for i = 1, 20 do
    local name, value = debug.getupvalue(s.map.tick,i)
    if name == "M" then return value end
  end
  error("map state missing")
end

-- The map-scene builder behind a read-only build module. Change b.dim, b.state, b.alert or b.pose
-- (nil when unknown) and reload the map. Machine 8 keeps an older pose with no dimension, which the
-- map must never use for the builder.
local function builder(s, dim, id)
  local src, env = s.scene.build, s.machine.env
  if id then src.id = id end
  local b = {dim=dim or src.dim, state=src.state, done=src.done, total=src.total, alert=src.alert,
    pose={x=src.pose.x, y=src.pose.y, z=src.pose.z, f=src.pose.f}}
  s.machines[src.id] = {id=tonumber(src.id), role="worker", fuel=src.fuel, seen=env.SO.now() - src.ago,
    pose={x=118, y=64, z=-334, facing=0}}
  local function pose() return b.pose and {x=b.pose.x, y=b.pose.y, z=b.pose.z, f=b.pose.f, dim=b.dim} end
  env.SO.mods.build = {
    assigned=function(id) return id == tonumber(src.id) end,
    facts=function() return {dim=b.dim, state=b.state, done=b.done, total=b.total, alert=b.alert,
      turtleId=tonumber(src.id), pose=pose()} end,
    mapView=function()
      local turtles = {}
      if b.pose then turtles[src.id] = {id=tonumber(src.id), dim=b.dim, pose=pose(), state=b.state, alert=b.alert} end
      return {dim=b.dim, bounds={dim=b.dim, x1=src.x1, y1=src.y1, z1=src.z1, x2=src.x2, y2=src.y2, z2=src.z2}, turtles=turtles}
    end}
  s.reloadMap()
  return b
end
local function textOf(frame)
  local out = {}
  for _, r in ipairs(frame.rows) do out[#out+1] = r.text end
  return table.concat(out, "\n")
end

local function findSetup()
  local s = setup()
  s.mine, s.lumber, s.machines, s.scene.drops = {}, {}, {}, {}
  s.now, s.events, s.queries = 1000000, {}, {}
  s.machine.files["so-server.cfg"] = H.encode({remoteDimensions=true})
  s.machine.env.SO.now = function() return s.now end
  s.machine.env.SO.mods.state.history = {page=function(q)
    s.queries[#s.queries+1] = q
    local entries = {}
    for _, ev in ipairs(s.events) do
      if ev.kind == q.kind and ev.seq > q.from then
        entries[#entries+1] = ev
        if #entries == q.count then break end
      end
    end
    return {entries=entries}
  end}
  s.find = function(x, y, z, age, dim)
    local ev = {seq=#s.events+1, kind="mine.ore", gameAt=s.now-(age or 0), at=9999999999,
      data={id=2,name="minecraft:diamond_ore",count=1,pos={dim=dim or "minecraft:overworld",x=x,y=y,z=z}}}
    s.events[#s.events+1] = ev
    return ev
  end
  s.step = function() s.map.tick(s.now) end
  s.reloadMap()
  return s
end
local function findView(scale)
  return {map={fit=false,sx=scale or 1,sz=scale or 1,cx=0,cz=0,level=64,oreFinds=true}}
end

return function(test,equal)
  test("ore finds use the exclusive ten-minute game window and invalidate cached frames on expiry", function()
    local s, session = findSetup(), findView()
    s.find(-5,64,-3,599999)
    s.find(-4,64,-3,600000)
    s.find(-3,64,-3,-1)
    local legacy = s.find(-2,64,-3,0)
    legacy.gameAt, legacy.at = nil, s.now
    local frame = s.settle(26,20,session)
    equal(#s.queries,0,"render never consumes history")
    s.step()
    local function glyph(x) return cell(picture(s.screen.render(26,20,session),26,20),session.map,x,-3)[1] end
    equal(glyph(-5),"*") equal(glyph(-4)," ") equal(glyph(-3)," ") equal(glyph(-2),"*")
    assert(s.screen.render(26,20,session) ~= frame,"new finds invalidate the frame")
    frame = s.screen.render(26,20,session)
    s.step() equal(s.screen.render(26,20,session),frame,"sequence deduplication keeps the cache")
    s.now = s.now + 1
    equal(glyph(-5)," ","expiry also works on the first render after an idle period")
    equal(glyph(-2),"*")
    s.now = s.now + 599999
    equal(glyph(-2)," ")
  end)

  test("ore find visibility defaults off and each display toggles independently", function()
    local s, a, b = findSetup(), findView(), findView()
    a.map.oreFinds, b.map.oreFinds = nil, nil
    s.find(-5,64,-3)
    s.settle(26,20,a) s.step()
    local function glyph(session)
      return cell(picture(s.screen.render(26,20,session),26,20),session.map,-5,-3)[1]
    end
    equal(glyph(a)," ") equal(a.map.oreFinds,false)
    s.screen.input({session=a,text="ore finds on"})
    equal(glyph(a),"*") equal(glyph(b)," ")
    s.screen.input({session=b,id="map-ore"}) equal(glyph(b),"*")
    s.screen.input({session=a,text="ore finds off"}) equal(glyph(a)," ") equal(glyph(b),"*")
    s.screen.input({session=b,id="map-ore"}) equal(glyph(b)," ")
  end)

  test("ore finds reject malformed evidence and filter dimensions and exact levels", function()
    local s, session = findSetup(), findView()
    s.find(-5,64,-3)
    s.find(-4,64,-3,0,"minecraft:the_nether")
    s.find(-3,63,-3) s.find(-2,65,-3)
    for _, bad in ipairs({{x=0.5,y=64,z=-3}, {x=math.huge,y=64,z=-3}, {x=0/0,y=64,z=-3},
        {x="0",y=64,z=-3}, {x=0,y=64}, {dim="mod:unknown",x=0,y=64,z=-3},
        {dim="minecraft:overworld",x=0,y=400,z=-3}}) do
      s.find(0,64,-3).data.pos = bad
    end
    s.find(0,64,-3).data.count = 0
    s.find(0,64,-3).gameAt = "bad"
    s.find(0,64,-3).gameAt = false
    s.find(0,64,-3).data.pos = nil
    s.settle(26,20,session) s.step()
    local function glyph(x) return cell(picture(s.screen.render(26,20,session),26,20),session.map,x,-3)[1] end
    equal(glyph(-5),"*") equal(glyph(-4)," ") equal(glyph(-3)," ") equal(glyph(-2)," ") equal(glyph(0)," ")
    session.map.level = "all"
    equal(glyph(-3),"*") equal(glyph(-2),"*")
    session.map.dim = "minecraft:the_nether"
    equal(glyph(-4),"*") equal(glyph(-5)," ") equal(glyph(-3)," ")
    local count = 0 for _ in pairs(mapState(s).finds.items) do count=count+1 end
    equal(count,4,"invalid records never enter the ring")
  end)

  test("ore history consumes at most 50 entries per tick and rebuilds a bounded 256-find ring", function()
    local s, session = findSetup(), findView()
    for i=1,700 do s.find(i,64,-3) end
    s.settle(26,20,session)
    local files = s.machine.env.SO.store.copy(s.machine.files)
    local function count()
      local n=0 for _ in pairs(mapState(s).finds.items) do n=n+1 end return n
    end
    for tick=1,14 do
      local before = #s.queries
      s.step()
      equal(#s.queries,before+1)
      equal(s.queries[#s.queries],{kind="mine.ore",from=(tick-1)*50,count=50})
      equal(count(),math.min(tick*50,256))
    end
    local seqs = {}
    for _, p in pairs(mapState(s).finds.items) do seqs[p.seq]=true assert(p.seq>444) end
    equal(s.machine.files,files,"finds never write storage")
    s.reloadMap() s.screen.render(26,20,session)
    equal(count(),0)
    for _=1,14 do s.step() end
    local rebuilt = {} for _,p in pairs(mapState(s).finds.items) do rebuilt[p.seq]=true end
    equal(rebuilt,seqs,"restart rebuilds retained events without duplicates")
    local version = mapState(s).finds.version
    s.step() equal(mapState(s).finds.version,version)
  end)

  test("ore finds replay the real retained state log after a module restart", function()
    local s, state = trailSetup()
    local session=findView()
    assert(state.emit("mine.ore",{id=8,name="minecraft:diamond_ore",count=1,
      pos={dim="minecraft:overworld",x=-5,y=64,z=-3}}))
    s.settle(26,20,session) s.step()
    local function glyph()
      return cell(picture(s.screen.render(26,20,session),26,20),session.map,-5,-3)[1]
    end
    equal(glyph(),"*")
    s.machine.env.SO.mods.state = s.machine.env.dofile("so-mod-state.lua")
    s.reloadMap() s.screen.render(26,20,session) s.step()
    equal(glyph(),"*")
    equal(mapState(s).finds.cursor,state.history.page({kind="mine.ore",count=50}).entries[1].seq)
  end)

  test("ore markers leave labels, branch numbers, workers, reservations and callouts intact", function()
    local s = setup()
    local now = s.machine.env.SO.now()
    s.machine.env.SO.now = function() return now end
    local events = {}
    s.machine.env.SO.mods.state.history = {page=function(q)
      if q.kind ~= "mine.ore" then return {entries={}} end
      local entries={}
      for _,ev in ipairs(events) do if ev.seq>q.from then entries[#entries+1]=ev if #entries==q.count then break end end end
      return {entries=entries}
    end}
    local session={map={fit=false,sx=1,sz=1,cx=158,cz=-367,level=-58,oreFinds=true,pick={k="turtle",id="6"}}}
    local base = picture(s.settle(57,24,session),57,24)
    local v = session.map
    assert(v.box,"picked worker has a callout")
    for cy=0,v.mh-1 do for cx=0,v.mw-1 do
      local x,z=v.left+cx,v.top+cy
      events[#events+1]={seq=#events+1,kind="mine.ore",gameAt=now,
        data={name="minecraft:diamond_ore",count=1,pos={dim="minecraft:overworld",x=x,y=-58,z=z}}}
    end end
    local checked=0
    for _=1,math.ceil(#events/50) do
      s.step()
      local out=picture(s.screen.render(57,24,session),57,24)
      for y=v.L.my,v.L.my+v.mh-1 do for x=1,57 do
        local c=base.cells[y][x]
        local terrain=v.base[(y-v.L.my)*v.mw+x-v.L.mx]
        local ground=terrain and c[1]==terrain[3] and c[2]==terrain[4] and c[2]~="b"
        local box=v.box
        local inside=box and x>=v.L.mx+box[1] and x<v.L.mx+box[1]+box[3]
          and y>=v.L.my+box[2] and y<v.L.my+box[2]+box[4]
        if inside or c[1]~=" " and not ground then
          equal(out.cells[y][x][1],c[1],"find covered label, marker, number, callout or reservation")
          equal(out.cells[y][x][3],c[3],"protected background")
          if c[1]~=" " then equal(out.cells[y][x][2],c[2],"protected foreground") end
          checked=checked+1
        end
      end end
    end
    assert(checked>0)
  end)

  test("ore finds stay beneath isolated reservations outside mine geometry", function()
    local s, session=findSetup(),findView()
    assert(s.cells.reserveMany("mine:2",{{dim="minecraft:overworld",x=-5,y=64,z=-3}}))
    s.find(-5,64,-3)
    local base=cell(picture(s.settle(26,20,session),26,20),session.map,-5,-3)
    s.step()
    equal(cell(picture(s.screen.render(26,20,session),26,20),session.map,-5,-3),base)
    equal(#mapState(s).findCells(session.map,mapState(s).scene),0)
  end)

  test("display text input toggles ore finds only for its own map session", function()
    local s=findSetup()
    s.find(-5,64,-3)
    local function frame(id)
      local out
      s.display.handlers["view.get"]({from=id,body={}},function(_,body) out=body end)
      return out
    end
    for _,id in ipairs({22,23}) do
      s.display.handlers.hello({from=id,body={w=26,h=20,fullH=20}})
      assert(s.display.assign(id,"map"))
      frame(id)
    end
    s.step()
    local function shown(id)
      for _,r in ipairs(frame(id).rows) do if r.text:find("*",1,true) then return true end end
      return false
    end
    equal(shown(22),false) equal(shown(23),false)
    s.display.handlers.input({from=22,body={text="ore finds on",x=1,y=1}})
    equal(shown(22),true) equal(shown(23),false)
    s.display.handlers.input({from=22,body={text="ore finds off",x=1,y=1}})
    equal(shown(22),false)
  end)

  test("many ore finds fit the 15000-byte frame budget without changing manual or FIT zoom", function()
    local s = findSetup()
    for i=1,256 do s.find(((i*17)%158-79)*64+1,64,((i-1)%60-30)*64+1) end
    local manual, fitted = findView(64), {map={oreFinds=true}}
    local base = s.settle(164,81,manual)
    s.settle(164,81,fitted)
    local fitZoom={fitted.map.sx,fitted.map.sz,fitted.map.extra or 0}
    for _=1,6 do s.step() end
    local proto=s.machine.env.SO.proto
    s.machine.env.SO.proto=nil
    local raw=s.screen.render(164,81,findView(64))
    s.machine.env.SO.proto=proto
    assert(#proto.ser(raw)>15000,"untrimmed ore markers must overflow")
    local session=findView(64)
    local frame=s.screen.render(164,81,session)
    assert(#proto.ser(frame)<=15000)
    assert(proto.encode(proto.build(string.rep("a",64),"view.frame",frame)))
    equal({session.map.sx,session.map.sz,session.map.extra or 0},{64,64,0})
    local out, before=picture(frame,164,81),picture(base,164,81)
    local shown,dropped=0,false
    for _,c in ipairs(mapState(s).findCells(session.map,mapState(s).scene)) do
      local x,y=session.map.L.mx+c.cx,session.map.L.my+c.cy
      if before.cells[y][x][1]==" " then
        if out.cells[y][x][1]=="*" then assert(not dropped) shown=shown+1 else dropped=true end
      end
    end
    assert(shown>0 and dropped,"drop older ore markers before any labels")
    local fitFrame=s.screen.render(164,81,fitted)
    equal({fitted.map.sx,fitted.map.sz,fitted.map.extra or 0},fitZoom)
    assert(#proto.ser(fitFrame)<=15000)
    print("map ore overflow: base "..#proto.ser(base)..", untrimmed "..#proto.ser(raw)..", trimmed "..#proto.ser(frame).." bytes; "..shown.." visible finds")
  end)

  for _, role in ipairs({"mine","lumber"}) do
    test("map evicts parked and removed "..role.." trails while the registry keeps the worker", function()
      local s, state = trailSetup()
      s.mine, s.lumber = {turtles={}}, {turtles={}}
      local row = {id=8,pose={x=0,y=64,z=0,facing=1},state=role == "mine" and "mining" or "lumber"}
      s[role].turtles["8"] = row
      s.pose(8,-5,64,-3)
      s.pose(8,0,64,0)
      local session = {map={fit=false,sx=1,sz=1,cx=0,cz=0,level=64}}
      local function dot()
        return cell(picture(s.screen.render(26,20,session),26,20),session.map,-5,-3)[1]
      end
      s.settle(26,20,session) s.step()
      equal(dot(),U.g.dot)
      for _, word in ipairs({"parking","parked"}) do
        row.state = word
        local calls = #s.pageCalls
        s.step()
        equal(dot()," ",word.." evicts the trail")
        equal(next(mapState(s).trails),nil)
        equal(#s.pageCalls,calls,word.." skips history refresh")
      end
      row.state = role == "mine" and "mining" or "lumber"
      s.step() equal(dot(),U.g.dot,"resuming refreshes the trail")
      s[role].turtles["8"] = nil
      local calls = #s.pageCalls
      s.step()
      assert(state.get("machines")["8"],"REMOVE keeps the registry row")
      equal(dot()," ","removing the assignment evicts the trail")
      equal(next(mapState(s).trails),nil)
      equal(#s.pageCalls,calls,"removed workers skip history refresh")
      s.reloadMap() s.screen.render(26,20,session) s.step()
      equal(dot()," ","a map restart does not revive removed trails")
      equal(#s.pageCalls,calls)
    end)
  end

  for _, role in ipairs({"mine","lumber"}) do
    test("map reads saved "..role.." park and remove flags beneath a lost or blocked label", function()
      local s = trailSetup()
      s.mine, s.lumber = {turtles={}}, {turtles={}}
      s[role].turtles["8"] = {id=8,pose={x=0,y=64,z=0},state=role == "mine" and "lost" or "fuel"}
      local m, session = s.machine, {map={fit=false,sx=1,sz=1,cx=0,cz=0,level=64}}
      m.files["so-server.cfg"] = H.encode({workerPark=true})
      local box = m.env.SO.store.store("so-data/"..role.."/job",function(v) return type(v)=="table" end)
      local job = {turtles={["8"]={}}}
      assert(box.save(job))
      s.pose(8,-5,64,-3) s.pose(8,0,64,0)
      s.reloadMap() s.screen.render(26,20,session) s.step()
      local function dot()
        return cell(picture(s.screen.render(26,20,session),26,20),session.map,-5,-3)[1]
      end
      equal(dot(),U.g.dot)
      for _, flag in ipairs({"paused","removeRequested"}) do
        job.turtles["8"][flag] = true
        assert(box.save(job))
        local calls, files = #s.pageCalls, m.env.SO.store.copy(m.files)
        s.step()
        equal(dot()," ",flag.." evicts a trail despite its status label")
        equal(next(mapState(s).trails),nil)
        equal(#s.pageCalls,calls,flag.." skips refresh")
        equal(m.files,files,"map generation recovery must not write")
        job.turtles["8"][flag] = nil
        assert(box.save(job)) s.step()
        equal(dot(),U.g.dot,"clearing saved flags restores eligibility")
      end
    end)
  end

  test("map trail cache stays within 32 workers and 640 poses as worker ids accumulate", function()
    local s = trailSetup()
    s.mine.turtles = {}
    for id = 1, 96 do s.mine.turtles[tostring(id)] = {state="mining",pose={x=0,y=64,z=0}} end
    s.machine.env.SO.now = function() return 100000 end
    s.machine.env.SO.mods.state.history.page = function(q)
      if q.kind ~= "pose" then return {entries={}} end
      s.pageCalls[#s.pageCalls+1] = q
      local entries = {}
      for i = 1, 20 do entries[i] = {seq=q.id*20+i,data={id=q.id,x=i,y=64,z=-3}} end
      return {entries=entries}
    end
    s.screen.render(26,20,{})
    local M, largest = mapState(s), 0
    for _ = 1, 192 do
      s.step()
      local workers, poses = 0, 0
      for _, trail in pairs(M.trails) do workers, poses = workers+1, poses+#trail.poses end
      largest = math.max(largest,workers)
      assert(workers <= 32 and poses <= 640,"global trail cache exceeded its bound")
    end
    equal(largest,32)
    equal(#s.pageCalls,192,"one page per tick even beyond the cache cap")
  end)

  test("map trims the oldest of 180 trail cells at 164x81 and zoom 64 without latching zoom", function()
    local s = trailSetup()
    s.mine.turtles = {}
    for id = 1, 9 do
      local pose = {x=(id-5)*1200,y=64,z=(id-5)*500,facing=1}
      s.mine.turtles[tostring(id)] = {state="mining",pose=pose}
      for i = 1, 20 do
        local n = (id-1)*20+i
        s.pose(id,((n*17)%158-79)*64+1,64,((n-1)%60-30)*64+1)
      end
    end
    local function manual() return {map={fit=false,sx=64,sz=64,cx=0,cz=0,level=64}} end
    local baseline, fitted = manual(), {}
    local base = s.settle(164,81,baseline)
    s.settle(164,81,fitted)
    local zoom = {fitted.map.sx,fitted.map.sz,fitted.map.extra or 0}
    local proto = s.machine.env.SO.proto
    assert(#proto.ser(base) < 15000,"base frame must fit without trails")
    for _ = 1, 9 do s.step() end
    s.machine.env.SO.proto = nil
    local raw = s.screen.render(164,81,manual())
    s.machine.env.SO.proto = proto
    assert(#proto.ser(raw) > 15000,"180 untrimmed trail cells must overflow")
    local session = manual()
    local frame = s.screen.render(164,81,session)
    assert(#proto.ser(frame) <= 15000,"trails exceeded the 15000-byte budget")
    assert(proto.encode(proto.build(string.rep("a",64),"view.frame",frame)),"trimmed frame must encode")
    equal({session.map.sx,session.map.sz,session.map.extra or 0},{64,64,0})
    local M, out, before = mapState(s), picture(frame,164,81), picture(base,164,81)
    local drawn, dropped = 0, false
    for _, c in ipairs(M.trailCells(session.map,M.scene)) do
      local x, y = session.map.L.mx+c.cx, session.map.L.my+c.cy
      if before.cells[y][x][1] == " " then
        if out.cells[y][x][1] == U.g.dot then
          assert(not dropped,"an older trail cell survived a newer dropped cell")
          drawn = drawn+1
        else dropped = true end
      end
    end
    assert(drawn > 0 and dropped,"keep fitting trail cells and drop old cells")
    local fitFrame = s.screen.render(164,81,fitted)
    equal({fitted.map.sx,fitted.map.sz,fitted.map.extra or 0},zoom,"trails must not latch FIT zoom")
    assert(#proto.ser(fitFrame) <= 15000)
    print("map trail overflow: base "..#proto.ser(base)..", untrimmed "..#proto.ser(raw)
      ..", trimmed "..#proto.ser(frame).." bytes; "..drawn.." visible dots")
  end)

  test("map trail asserts every cell and stays under the worker glyph at 26x20", function()
    local s = trailSetup()
    for x = -5, -1 do s.pose(8,x,64,-3) end
    s.pose(8,3,64,-3,"minecraft:the_nether")
    s.pose(8,4,70,-3)
    s.pose(8,5,63,-3)
    s.pose(8,1000,64,-3)
    s.pose(8,0,64,0)
    local session = {map={fit=false,sx=1,sz=1,cx=0,cz=0,level=64}}
    local before = picture(s.settle(26,20,session),26,20)
    equal(#s.pageCalls,0,"render does not read history")
    s.step()
    equal(#s.pageCalls,1)
    equal(s.pageCalls[1],{reverse=true,kind="pose",id=8,count=20})
    local frame = s.screen.render(26,20,session)
    local out, v = picture(frame,26,20), session.map
    local dots = {}
    for _, x in ipairs({-5,-4,-3,-2,-1,5}) do
      local cx, cy = at(v,x,-3)
      dots[cy*26+cx] = true
    end
    for y = 1, 20 do for x = 1, 26 do
      local got, want = out.cells[y][x], before.cells[y][x]
      if dots[y*26+x] then equal(got,{U.g.dot,"8","f"},"trail cell "..x..","..y)
      elseif want[1] == " " then
        equal(got[1],want[1],"blank cell "..x..","..y)
        equal(got[3],want[3],"blank background "..x..","..y)
      else equal(got,want,"unchanged cell "..x..","..y) end
    end end
    equal(cell(out,v,0,0)[1],U.g.right,"worker glyph covers its latest pose")
    s.step()
    equal(s.screen.render(26,20,session),frame,"unchanged history keeps the cached frame")
    equal(#s.pageCalls,2,"one page on each active tick")
    session.map.dim = "minecraft:the_nether"
    out = picture(s.screen.render(26,20,session),26,20)
    equal(cell(out,v,3,-3)[1],U.g.dot,"trail follows its event dimension")
    equal(cell(out,v,-5,-3)[1]," ","overworld trail is absent in the Nether")
    equal(#s.pageCalls,2,"dimension renders do not read history")
  end)

  test("map trail keeps only the newest 20 poses and refreshes a stationary worker", function()
    local s, state = trailSetup()
    s.mine.turtles = {["8"]={pose={x=0,y=64,z=0,facing=1}}}
    for x = -10, 10 do s.pose(8,x,64,-4) end
    local session = {map={fit=false,sx=1,sz=1,cx=0,cz=0,level=64}}
    s.settle(26,20,session) s.step()
    local out, v = picture(s.screen.render(26,20,session),26,20), session.map
    equal(cell(out,v,-10,-4)[1]," ","the 21st oldest pose is absent")
    for x = -9, 10 do equal(cell(out,v,x,-4)[1],U.g.dot,"retained pose "..x) end
    s.pose(8,-10,64,-3)
    s.step()
    out = picture(s.screen.render(26,20,session),26,20)
    equal(cell(out,v,-9,-4)[1]," ","the oldest dot leaves the cached frame")
    equal(cell(out,v,-10,-3)[1],U.g.dot,"new history invalidates the frame")
    -- Poses age out by count, even when their game time is old.
    s.net.advance(3600)
    s.screen.render(26,20,session) s.step()
    out = picture(s.screen.render(26,20,session),26,20)
    equal(cell(out,v,-10,-3)[1],U.g.dot)
    state.get = function() return {} end
    s.mine.turtles = {}
    local calls = #s.pageCalls
    s.step()
    out = picture(s.screen.render(26,20,session),26,20)
    equal(cell(out,v,-10,-3)[1]," ","removed workers leave no trail")
    equal(#s.pageCalls,calls,"no history reads without workers")
  end)

  for _, size in ipairs({{26,20},{57,24},{100,38},{164,81}}) do
    local w, h = size[1], size[2]
    test("map trail stays below worker and chest labels and callouts at "..w.."x"..h, function()
      for _, pick in ipairs({false,{k="turtle",id="8"},{k="drop",id="1"}}) do
        local s = trailSetup(true)
        local session = {map={fit=false,sx=1,sz=1,cx=0,cz=0,level=64,pick=pick or nil}}
        local before = picture(s.settle(w,h,session),w,h)
        local v, targets, blanks = session.map, {}, {}
        for cy = 0, v.mh-1 do for cx = 0, v.mw-1 do
          local c = before.cells[v.L.my+cy][v.L.mx+cx]
          if c[1]:match("%w") then targets[#targets+1] = {cx,cy}
          elseif v.box and cx > v.box[1] and cx < v.box[1]+v.box[3]-1
              and cy > v.box[2] and cy < v.box[2]+v.box[4]-1 and c[1] == " " then
            blanks[#blanks+1] = {cx,cy}
          end
        end end
        if not pick then
          local text = table.concat(before.picture().text,"\n")
          for _, label in ipairs({"8 idle","9 idle","ore"}) do assert(text:find(label,1,true),text) end
          assert(#targets <= 20,"the fixture covers every label character")
        end
        for i = 1, math.min(20,#targets) do
          local p = targets[i]
          s.pose(8,v.left+p[1],64,v.top+p[2])
        end
        for i = 1, math.min(20,#blanks) do
          local p = blanks[i]
          s.pose(9,v.left+p[1],64,v.top+p[2])
        end
        -- Keep the fixture's marker poses fixed while the historical paths change.
        s.machine.env.SO.mods.state.get = function()
          return {['8']={role="worker",pose={x=0,y=64,z=0,facing=1}},
            ['9']={role="worker",pose={x=5,y=64,z=2,facing=0}}}
        end
        s.step() s.step()
        equal(#s.pageCalls,2,"two workers share one page per tick across three dimensions")
        equal(s.pageCalls[1].id,8) equal(s.pageCalls[2].id,9)
        local out = picture(s.screen.render(w,h,session),w,h)
        for y = 1, h do for x = 1, w do
          local c = before.cells[y][x]
          local cx, cy = x-v.L.mx, y-v.L.my
          local inBox = v.box and cx >= v.box[1] and cx < v.box[1]+v.box[3]
            and cy >= v.box[2] and cy < v.box[2]+v.box[4]
          if c[1] ~= " " or inBox then equal(out.cells[y][x],c,"label or callout at "..x..","..y) end
        end end
      end
    end)
  end

  for _, view in ipairs(loadScene().views) do
    local w, h = view.w, view.h
    test("map fixture "..view.name.." draws the scene from real dug marks", function()
      local s = setup()
      local session = {map={}}
      for k, value in pairs(view.map) do session.map[k] = value end
      local frame, most = s.settle(w, h, session)
      assert(most <= 16 + 24, "dug reads per frame "..most)
      local out = picture(frame, w, h)
      local diffs = R.diff(R.load(assert(FIXTURES[view.name], "fixture path")), out.picture())
      equal(#diffs, 0, view.name .. "\n" .. table.concat(diffs, "\n"))
      local v = session.map
      compass(frame, w, v)
      -- Every dug block in view shows a glyph, unless a marker, label or callout covers it.
      local level, checked = v.level, 0
      for _, p in ipairs(s.scene.dug) do
        if level == "all" or p.y == level then
          local c = cell(out, v, p.x, p.z)
          if c and c[1] ~= " " then checked = checked + 1 end
        end
      end
      assert(checked > 0, "no dug marks in view")
      for _, id in ipairs(CONTROLS) do button(frame, id, w, h) end
      -- The scene's broken chest: a coral count chip on row 1, beside the controls or in the title.
      if w >= 25 then equal(button(frame, "map-broken", w, h).y, 1) end
      local bytes = #s.machine.env.SO.proto.ser(frame)
      assert(bytes < 16384, view.name .. " frame bytes " .. bytes)
    end)
  end

  test("map cache versions stay stable across two dimensions", function()
    local s = setup()
    local over, nether = "minecraft:overworld", "minecraft:the_nether"
    assert(s.cells.reserve("mine:8", 0, 40, 0, nether))
    local a, av = s.cells.reserved(over)
    local b, bv = s.cells.reserved(nether)
    for _ = 1, 2 do
      local aa, aav = s.cells.reserved(over)
      local bb, bbv = s.cells.reserved(nether)
      equal(aa, a) equal(aav, av) equal(bb, b) equal(bbv, bv)
    end
    assert(s.cells.reserve("mine:9", 1, 40, 0, nether))
    assert(select(2, s.cells.reserved(over)) ~= av)
    equal(#s.cells.reserved(nether), 2)
  end)

  test("map held callout shows held #4 mine and silent 7 min at 26x20", function()
    local s = setup()
    local now = s.machine.env.SO.now()
    s.leases[4] = {lost=true, seen=now-7*60000}
    s.machines["4"].seen = now-8*60000
    local session = {map={level=-58, fit=false, sx=1, sz=1, cx=120, cz=-360, pick={k="cell", x=120, z=-360}}}
    local function text() return table.concat(picture(s.settle(26,20,session),26,20).picture().text,"\n") end
    local shown = text()
    assert(shown:find("held #4 mine",1,true),shown)
    assert(shown:find("silent 7 min",1,true),shown)
    s.leases[4] = {seen=now}
    s.machines["4"].seen = now
    s.step()
    assert(not text():find("silent",1,true), "fresh holder is not silent")
    -- A holder without a world pose still refreshes its callout after contact.
    s.mine.turtles["4"], s.machines["4"] = nil, {seen=now-7*60000}
    s.leases[4] = {seen=now-7*60000}
    s.step()
    assert(text():find("silent 7 min",1,true))
    s.leases[4].seen = s.machine.env.SO.now()
    s.step()
    assert(not text():find("silent",1,true))
  end)

  test("map turtle callout shows last ok 2m and range 27/24 at 26x20", function()
    local s = setup()
    local now = s.machine.env.SO.now()
    s.mine.turtles, s.lumber, s.machines = {}, {}, {
      ["8"]={id=8, role="worker", fuel=700, seen=now, pose={x=140,y=64,z=-336,facing=1}}}
    s.leases[8] = {range=16, last={status="reported",ok=true,at=now-120000}}
    s.machine.env.SO.mods.lease.inRange = function() return false end
    local session = {map={level=64,fit=false,sx=1,sz=1,cx=140,cz=-336,pick={k="turtle",id="8"}}}
    local function text() return table.concat(picture(s.settle(26,20,session),26,20).picture().text,"\n") end
    local shown = text()
    assert(shown:find("last ok 2m",1,true),shown)
    assert(shown:find("range 27/24",1,true),shown)
    s.leases[8].last = {status="reported",ok=false,at=now}
    s.step()
    assert(text():find("last failed",1,true),text())
    s.leases[8].last = {status="expired",ok=false,at=now}
    s.step()
    assert(text():find("last expired",1,true),text())
  end)

  test("lease snapshots copy the last accepted report and expiry", function()
    local s = setup()
    s.machine.env.SO.pair.key = function() return string.rep("a",64) end
    local lease = s.machine.env.dofile("so-mod-lease.lua")
    s.machine.env.SO.mods.lease = lease
    local function report(ok)
      local id = assert(lease.send(8, {{op="forward"}}, {owner="mine"}))
      lease.handlers["step.report"]({from=8,body={lease=id,results={{ok=ok}}}})
      return lease.peek(8).last
    end
    equal(report(true), {status="reported",ok=true,at=s.machine.env.SO.now()})
    local last = lease.status(8).last
    last.ok = false
    equal(lease.peek(8).last.ok,true,"snapshot owns its copy")
    local id = assert(lease.send(8, {{op="forward"}}, {ms=1,owner="mine"}))
    lease.handlers["step.report"]({from=8,body={lease="wrong",results={{ok=false}}}})
    equal(lease.peek(8).last.ok,true,"foreign report does not replace the result")
    lease.handlers["step.report"]({from=8,body={lease=id,results={{ok=false}}}})
    equal(lease.peek(8).last.ok,false)
    assert(lease.send(8, {{op="forward"}}, {ms=1,owner="mine"}))
    local now = s.machine.env.SO.now()+10002
    lease.tick(now)
    equal(lease.peek(8).last,{status="expired",ok=false,at=now})
  end)

  test("map level arrows clamp at the limits of each dimension", function()
    local s = setup()
    s.machine.files["so-server.cfg"] = H.encode({pos=s.scene.server,remoteDimensions=true})
    s.net.advance(6)
    for _, limits in ipairs({{"minecraft:overworld",-64,319},{"minecraft:the_nether",1,126},{"minecraft:the_end",1,255}}) do
      for _, edge in ipairs({{limits[2],"map-down"},{limits[3],"map-up"}}) do
        local session = {map={dim=limits[1],level=edge[1],fit=true}}
        s.settle(26,20,session)
        for _ = 1, 3 do s.screen.input({id=edge[2],session=session}) end
        equal(session.map.level,edge[1])
      end
    end
  end)

  test("map holder lookup includes reservations past the 4096 display cap", function()
    local s = setup()
    local many = {}
    for x = 1, 5000 do many[#many+1] = {x=x,y=-58,z=5000} end
    assert(s.cells.reserveMany("setup:99",many))
    -- Omit every displayed reservation. Callouts must query the actual owners.
    s.cells.reserved = function() return {}, 1 end
    local function text(pick,level,sx)
      local session = {map={level=level,fit=false,sx=sx or 1,sz=sx or 1,cx=120,cz=-341,pick=pick}}
      return table.concat(picture(s.settle(26,20,session),26,20).picture().text,"\n")
    end
    assert(text({k="cell",x=120,z=-341},-58):find("held #4 mine",1,true))
    assert(text({k="shaft"},"all"):find("#4 mine",1,true))
    assert(text({k="cell",x=120,z=-341},"all",2):find("held #4 mine",1,true))
    local held = assert(s.cells.holder("minecraft:overworld",1,5000,5000,5000))
    equal(held.who,"setup:99")
    held.who = "changed"
    equal(s.cells.owner(held.x,held.y,held.z),"setup:99","lookup is a copy")
  end)

  test("map cold FIT in adversarial column order settles to warm-only FIT", function()
    local function coldFixture()
      local s = setup()
      for x = 130, 178, 3 do for z = -372, -344, 3 do assert(s.cells.markDug(x,-58,z)) end end
      return s
    end
    local warm = coldFixture()
    -- The thumbnail warms the same planes without choosing a wire-frame zoom.
    for _ = 1, 20 do warm.map.thumb(U.canvas(164,81),1,1,164,81) warm.step() end
    local reference = {}
    local expected = warm.screen.render(164,81,reference)
    assert(reference.map.ready,"reference must start with warm planes")
    local largest, partial = 0, 0
    for seed = 1, 20 do
      local cold, random = coldFixture(), seed
      local columns = cold.cells.dugColumns
      cold.cells.dugColumns = function(...)
        local result = columns(...)
        for i = #result, 2, -1 do
          random = random*16807%2147483647
          local j = random%i+1
          result[i], result[j] = result[j], result[i]
        end
        return result
      end
      local session = {}
      for _ = 1, 60 do
        local frame = cold.screen.render(164,81,session)
        if session.map.ready then break end
        partial = partial+1
        largest = math.max(largest,#cold.machine.env.SO.proto.ser(frame))
        equal(session.map.extra or 0,0,"partial planes must not latch extra zoom")
        cold.step()
      end
      assert(session.map.ready,"cold planes never finished")
      local actual = cold.settle(164,81,session)
      local a, b = session.map, reference.map
      equal({a.sx,a.sz,a.left,a.top,a.extra or 0},{b.sx,b.sz,b.left,b.top,b.extra or 0},"cold FIT differs at seed " .. seed)
      local diffs = R.diff(picture(expected,164,81).picture(),picture(actual,164,81).picture())
      equal(#diffs,0,table.concat(diffs,"\n"))
    end
    assert(partial>0,"test must draw partially loaded planes")
    assert(largest>15000,"adversarial cold frames did not cross the wire budget: " .. largest)
    print("map cold FIT: " .. partial .. " partial frames, largest " .. largest .. " bytes; 20 warm-only comparisons matched")
  end)

  for seed = 1, 20 do
    test("map-XL fixture ignores randomized prior state " .. seed, function()
      local s = setup()
      local copy = s.machine.env.SO.store.copy
      local mine, lumber, machines, leases = copy(s.mine), copy(s.lumber), copy(s.machines), copy(s.leases)
      local clock = s.machine.env.SO.now
      local random = seed
      local function nextValue(n) random = random*16807%2147483647 return random%n end
      s.mine.running, s.mine.branches = nextValue(2)==1, nextValue(30)+1
      s.mine.preview = {{x=120,y=-58,z=-381},{x=120+nextValue(100),y=-58,z=-381}}
      local priorTime = nextValue(1000000000)
      s.machine.env.SO.now = function() return priorTime end
      s.screen.render(164,81,{map={fit=true,level="all",pick={k="shaft"}}})
      s.mine, s.lumber, s.machines, s.leases = mine, lumber, machines, leases
      s.machine.env.SO.now = clock
      local columns = s.cells.dugColumns
      s.cells.dugColumns = function(...)
        local result = columns(...)
        for i = #result, 2, -1 do
          local j = nextValue(i)+1
          result[i], result[j] = result[j], result[i]
        end
        return result
      end
      s.reloadMap()
      local frame = s.settle(164,81,{})
      local diffs = R.diff(R.load(FIXTURES["schematic-map-XL"]),picture(frame,164,81).picture())
      equal(#diffs,0,"seed " .. seed .. "\n" .. table.concat(diffs,"\n"))
    end)
  end

  test("map keeps north up: the compass tells the truth for every mine facing", function()
    for f = 0, 3 do
      local s = setup()
      s.mine.home.facing = f
      s.mine.turtles = {}
      s.lumber = {}
      s.machines = {}
      s.scene.drops = {}
      -- One turtle north and one east of the shaft, on the mine level.
      s.machines["8"] = {id=8, role="worker", pose={x=120, y=-58, z=-350, facing=0}}
      s.machines["9"] = {id=9, role="worker", pose={x=130, y=-58, z=-340, facing=1}}
      s.step()
      for _, size in ipairs({{57, 24}, {100, 38}, {26, 20}, {15, 10}}) do
        local w, h = size[1], size[2]
        local session = {}
        local frame = s.settle(w, h, session)
        local v = session.map
        compass(frame, w, v)
        local out = picture(frame, w, h)
        local nx, ny = at(v, 120, -350)
        local ex, ey = at(v, 130, -340)
        assert(nx and ex, "markers in view at facing " .. f)
        -- The tiny map may put both in one row or column; it never flips them.
        assert(ny < ey or w < 25 and ny == ey, "north is up at facing " .. f .. " " .. w .. "x" .. h)
        assert(ex > nx or w < 25 and ex == nx, "east is right at facing " .. f .. " " .. w .. "x" .. h)
        if w >= 25 then equal(out.cells[ny][nx][1], U.arrow(0)) end
        -- The branch axis snaps: branch rows (or columns) step by the gap in whole cells.
        local g = {x=120 + ({0, 1, 0, -1})[f + 1], z=-340 + ({-1, 0, 1, 0})[f + 1]}
        local d = ({{0, -1}, {1, 0}, {0, 1}, {-1, 0}})[f + 1]
        local b1x, b1y = at(v, g.x + d[1] * 4, g.z + d[2] * 4)
        local b2x, b2y = at(v, g.x + d[1] * 8, g.z + d[2] * 8)
        if f % 2 == 0 then
          equal((v.top - (g.z + d[2] * 4)) % v.sz, 0, "branch rows start their cells")
          if b1x and b2x then equal(b1x, b2x) assert(b1y ~= b2y or v.sz > 4) end
        else
          equal((v.left - (g.x + d[1] * 4)) % v.sx, 0, "branch columns start their cells")
          if b1x and b2x then equal(b1y, b2y) assert(b1x ~= b2x or v.sx > 4) end
        end
      end
    end
  end)

  test("map pan, zoom and FIT move the view and keep the pick in place", function()
    local s = setup()
    local session = {}
    s.settle(57, 24, session)
    local v = session.map
    equal(v.fit, true) equal({v.sx, v.sz}, {2, 2}) equal({v.left, v.top}, {90, -381})
    local cx, cz = v.cx, v.cz
    local function press(id, x, y) s.screen.input({id=id, x=x, y=y, session=session}) return s.settle(57, 24, session) end
    press("map-e") equal(v.fit, false) equal(v.cx, cx + math.floor(57 * 2 / 3)) equal(v.cz, cz)
    press("map-s") equal(v.cz, cz + math.floor(23 * 2 / 3))
    press("map-w") press("map-n") equal({v.cx, v.cz}, {cx, cz})
    press("map-out") equal({v.sx, v.sz}, {3, 4})
    for _ = 1, 20 do press("map-out") end
    equal({v.sx, v.sz}, {64, 64})
    for _ = 1, 20 do press("map-in") end
    equal({v.sx, v.sz}, {1, 1})
    -- Branch rows stay on cell rows at every zoom: the top aligns to the gap.
    equal((v.top - (-345)) % v.sz, 0)
    local frame = press("map-fit") equal(v.fit, true) equal({v.sx, v.sz, v.left, v.top}, {2, 2, 90, -381})
    equal(row(frame, 1):sub(6, 10), " FIT ")
    -- Tap turtle 2: it inverts and gets a callout; zoom keeps it in the same cell.
    local x, y = at(v, 160, -373)
    frame = press("map-pick", x, y)
    equal(v.pick.k, "turtle") equal(v.pick.id, "2")
    local out = picture(frame, 57, 24)
    equal(out.cells[y][x][2], "f") equal(out.cells[y][x][3], "d")
    local text = table.concat(out.picture().text, "\n")
    assert(text:find("#2 mining", 1, true), "turtle callout")
    assert(text:find("160,-58,-373", 1, true), "callout position")
    for _, id in ipairs({"map-in", "map-out", "map-out"}) do
      press(id)
      local px, py = at(v, 160, -373)
      assert(px and math.abs(px - x) <= 1 and math.abs(py - y) <= 1, id .. " keeps the pick")
    end
    frame = press("map-fit")
    frame = press("map-pick", x, y)
    equal(v.pick, nil, "second tap clears the pick")
    assert(not table.concat(picture(frame, 57, 24).picture().text, "\n"):find("#2 mining", 1, true), "callout closed")
    -- A tap on the callout box closes it; a tap on empty ground picks the cell.
    press("map-pick", x, y)
    local b = v.box
    press("map-pick", v.L.mx + b[1] + 1, v.L.my + b[2] + 1)
    equal(v.pick, nil, "tap on the callout closes it")
    frame = press("map-pick", 3, 4)
    equal(v.pick.k, "cell")
    assert(row(frame, 1):find(NORTH, 1, true))
  end)

  test("map level control steps, cycles and filters by y", function()
    local s = setup()
    local session = {}
    local frame = s.settle(39, 19, session)
    local v = session.map
    local function press(id) s.screen.input({id=id, session=session}) return s.settle(39, 19, session) end
    local function label() local b = button(frame, "map-level", 39, 19) return row(frame, b.y):sub(b.x, b.x + b.w - 1):match("%S+") end
    equal(v.level, "all") equal(label(), "ALL")
    frame = press("map-level") equal(v.level, -58) equal(label(), "Y-58")
    v.fit, v.sx, v.sz, v.cx, v.cz = false, 1, 1, 150, -352
    frame = press("map-up") equal(v.level, -57)
    local out = picture(frame, 39, 19)
    assert(cell(out, v, 136, -350)[1] ~= " ", "vein above the branch at y -57")
    equal(cell(out, v, 150, -345)[1], " ", "branch 1 is not on y -57")
    frame = press("map-down") frame = press("map-down") equal(v.level, -59)
    out = picture(frame, 39, 19)
    assert(cell(out, v, 165, -346)[1] ~= " ", "pocket below the level")
    frame = press("map-level") equal(v.level, "all")
    frame = press("map-level") equal(v.level, -58)
    frame = press("map-fit")
    frame = press("map-level") equal(v.level, 64) equal(label(), "Y64")
    assert(table.concat(picture(frame, 39, 19).picture().text):find("\226\128\162", 1, true), "surface level shows the drops")
    frame = press("map-level") equal(v.level, "all")
    -- ALL is a max projection: the y -59 pocket and the y -58 branches both show.
    out = picture(frame, 39, 19)
    assert(cell(out, v, 165, -346)[1] ~= " ")
    assert(cell(out, v, 150, -345)[1] ~= " ")
  end)

  test("map draws lines from block adjacency, dots for small digs and blue for held cells", function()
    local s = setup()
    local session = {map={level=-58, fit=false, sx=1, sz=1, cx=140, cz=-366}}
    local out = picture(s.settle(57, 24, session), 57, 24)
    local v = session.map
    equal(cell(out, v, 150, -365)[1], "-") equal(cell(out, v, 150, -365)[2], "3")
    equal(cell(out, v, 150, -367)[1], U.g.dot, "a 3-block vein is a dot")
    equal(cell(out, v, 120, -360)[1], "|") equal(cell(out, v, 120, -360)[2], "b", "the held spine is blue")
    equal(cell(out, v, 165, -373)[1], U.g.dot) equal(cell(out, v, 165, -373)[2], "8", "planned branch is muted dots")
    equal(cell(out, v, 162, -373)[2], "b", "cells held ahead of a turtle are blue")
    equal(cell(out, v, 140, -355)[1], " ", "rock between branches")
    -- A big dig off the geometry draws as lines, not a dot.
    for x = 140, 150 do assert(s.cells.markDug(x, -58, -363)) end
    s.step()
    out = picture(s.settle(57, 24, session), 57, 24)
    equal(cell(out, v, 145, -363)[1], "-")
  end)

  test("map work per tick is bounded and an idle map does no dug reads", function()
    local s = setup()
    local session = {map={level="all", fit=false, sx=1, sz=1, cx=140, cz=-360}}
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
    equal(cell(picture(frame, 164, 81), session.map, 165, -374)[1], " ", "rock before the mark")
    assert(s.cells.markDug(165, -58, -374))
    for _ = 1, 2 do
      local reads, probes = s.calls, s.probes
      s.step()
      frame = s.screen.render(164, 81, session)
      assert(s.calls - reads <= 16 + 24, "update reads "..(s.calls - reads))
      assert(s.probes - probes <= 64 + 24, "update probes "..(s.probes - probes))
    end
    equal(cell(picture(frame, 164, 81), session.map, 165, -374)[1], U.g.dot, "new dig")
  end)

  test("map shows marks in sections that left the cells cache before the sweep", function()
    local s = setup()
    local session = {map={level=-58, fit=false, sx=1, sz=1, cx=160, cz=-370}}
    local frame = s.settle(29, 12, session)
    equal(cell(picture(frame, 29, 12), session.map, 165, -374)[1], " ")
    assert(s.cells.markDug(165, -58, -374))
    -- Planning reads elsewhere push the section out of the 256-section cache.
    local version = s.cells.dugVersion()
    for i = 1, 300 do s.cells.isDug(5000 + i * 16, 0, 5000) end
    equal(s.cells.dugVersion(), version, "probed empty sections stay out of the column index")
    for _ = 1, 4 do s.step() frame = s.screen.render(29, 12, session) end
    assert(cell(picture(frame, 29, 12), session.map, 165, -374)[1] ~= " ", "new dig after eviction")
  end)

  test("map orders numeric and named turtle ids without failing", function()
    local s = setup()
    for _, id in ipairs({"9", "10", "1a", "b"}) do
      s.mine.turtles[id] = {pose={x=130, y=-58, z=-347, facing=0}, state="mining"}
    end
    s.step()
    s.settle(57, 24, {})
    s.settle(100, 38, {})
  end)

  test("map dug reads stay inside the budget at the widest zoom", function()
    local s = setup()
    for x = 0, 40 do assert(s.cells.markDug(x * 16, 0, x * 16)) end
    local session = {map={level="all", fit=false, sx=64, sz=64, cx=0, cz=0}}
    local _, most = s.settle(164, 81, session)
    assert(most <= 16 + 24, "reads per frame "..most)
  end)

  test("map draws at odd sizes, levels and empty scenes without errors", function()
    local s = setup()
    for _, size in ipairs({{1,1},{7,5},{14,9},{24,8},{25,6},{51,19},{52,10},{79,40},{80,30},{120,50},{164,81}}) do
      for _, session in ipairs({{}, {map={level=64, fit=true}}, {map={level=-58, fit=false, sx=1, sz=1, cx=160, cz=-373, pick={k="turtle", id="2"}}}}) do
        local frame = s.screen.render(size[1], size[2], session)
        equal(#frame.rows, size[2])
        for _, b in ipairs(frame.buttons) do assert(b.x >= 1 and b.y >= 1 and b.x + b.w - 1 <= size[1] and b.y <= size[2]) end
        s.screen.input({id="map-pick", x=math.ceil(size[1] / 2), y=math.ceil(size[2] / 2), session=session})
        s.screen.input({id="map-out", session=session})
        s.screen.render(size[1], size[2], session)
      end
    end
    -- Odd data: unlimited fuel, a pose without x, a string focus y.
    s.machines["2"].fuel = "unlimited"
    s.machines["30"] = {id=30, role="worker", pose={y=-58, z=3}}
    s.step()
    local text = table.concat(picture(s.screen.render(57, 24, {map={level=-58, fit=false, sx=1, sz=1, cx=160, cz=-373,
      pick={k="turtle", id="2"}}}), 57, 24).picture().text, "\n")
    assert(text:find("unlimited", 1, true), "unlimited fuel in the callout")
    assert(s.map.crop(U.canvas(20, 9), 1, 1, 20, 9, {x="184", y="-58", z="-369", id=6}))
    -- A huge mine: the planned lines cost per cell, not per block.
    s.mine.branches, s.mine.length = 1000, 4096
    s.step()
    local started = os.clock()
    s.screen.render(164, 81, {})
    print("map huge mine render " .. string.format("%.2f", os.clock() - started) .. " s")
    assert(os.clock() - started < 5, "huge mine render took " .. (os.clock() - started) .. " s")
    local bare = setup()
    bare.mine, bare.lumber, bare.machines, bare.scene.drops = {}, {}, {}, {}
    bare.machine.files["so-server.cfg"] = nil
    bare.step()
    local frame = bare.screen.render(57, 24, {})
    assert(frame.rows[1].text:find(NORTH, 1, true), "compass without a scene")
  end)

  test("map view state and caches belong to each display", function()
    local s, a, b = setup(), {}, {}
    s.screen.render(26,20,a) s.screen.render(26,20,b)
    s.screen.input({id="map-out",session=a}) s.screen.input({id="map-e",session=a})
    s.screen.input({id="map-level",session=a})
    equal(b.map.fit,true) equal(b.map.level,"all")
    s.screen.render(29,12,b)
    equal(a.map.level,-58)
    assert(a.map.base ~= b.map.base)
  end)

  test("map taps under a retirement banner hit the right cell", function()
    local s = setup()
    local session = {h=24}
    s.settle(57, 22, session)
    local v = session.map
    local x, y = at(v, 160, -373)
    s.screen.input({id="map-pick", x=x, y=y + 2, session=session})
    local frame = s.settle(57, 22, session)
    equal(v.pick and v.pick.id, "2", "banner offset applied")
    assert(table.concat(picture(frame, 57, 22).picture().text, "\n"):find("#2 mining", 1, true))
  end)

  test("map turtle colours and labels follow state and lost leases", function()
    local s = setup()
    s.mine.turtles["2"].state = "idle" s.mine.turtles["2"].pose.facing = 0
    s.leases[3] = nil s.leases[6] = nil s.leases[2] = "lost"
    local session = {map={level=-58, fit=false, sx=1, sz=1, cx=150, cz=-370}}
    s.step()
    local frame = s.settle(57, 24, session)
    local out, v = picture(frame, 57, 24), session.map
    equal(cell(out, v, 160, -373)[1], U.g.up) equal(cell(out, v, 160, -373)[2], "e")
    equal(cell(out, v, 142, -377)[2], "1", "waiting is amber")
    local text = table.concat(out.picture().text, "\n")
    assert(text:find("2 lost", 1, true), "lost turtles carry their state")
    assert(text:find("3 wait", 1, true), "waiting turtles carry their state")
    -- Coarse scales keep only ids.
    session = {map={level="all", fit=false, sx=3, sz=2, cx=150, cz=-370}}
    text = table.concat(picture(s.settle(57, 24, session), 57, 24).picture().text, "\n")
    assert(not text:find("3 wait", 1, true) and not text:find("lost", 1, true), "ids only from sx 3")
  end)

  test("map controls sit on row 1 like every route A screen and other headers carry no MAP link", function()
    local s = setup()
    s.display.screen("panel", function(cw, ch) local c = U.canvas(cw, ch) c.header("PANEL", "22:14") return c.frame() end, function() end)
    s.display.handlers.hello({from=22,body={w=26,h=20,fullH=20}})
    assert(s.display.assign(22,"panel"))
    local frame
    s.display.handlers["view.get"]({from=22,body={}},function(_,body) frame=body end)
    for _,b in ipairs(frame.buttons) do assert(b.id~="map","header MAP link") end
    for _, size in ipairs({{26,20},{57,24},{100,38},{15,10},{39,19}}) do
      local session = {}
      frame = s.screen.render(size[1], size[2], session)
      for _, b in ipairs(frame.buttons) do
        if b.id ~= "map-pick" then assert(b.y == 1 or b.y >= size[2] - 1, "control rows " .. b.id) end
      end
      -- The title gives way to the broken chest count when the row has no room for both.
      if size[1] >= 25 then assert(row(frame, 1):find("^ MAP") or row(frame, 1):find("^ " .. U.g.cross .. "1"), row(frame, 1)) end
      compass(frame, size[1], session.map)
    end
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

  test("map renders complete large frames inside the protocol limit",function()
    local s=setup()
    -- A dense mine: 40 branches dug side by side.
    for k = 1, 40 do for x = 121, 184 do assert(s.cells.markDug(x, -58, -341 - 2 * k)) end end
    s.machine.install({"so-log.lua", "so-mod-state.lua"})
    local state = s.machine.env.dofile("so-mod-state.lua")
    s.machine.env.SO.mods.state.history = state.history
    local workers = 0
    for id in pairs(s.machines) do
      workers = workers + 1
      for i = 1, 20 do
        state.emit("pose", {id=tonumber(id),x=121+(i*7+workers)%64,y=-58,z=-342-i*3})
      end
    end
    s.screen.render(164,81,{})
    for _ = 1, workers do s.step() end
    for _, view in ipairs({{164,81,{}}, {164,81,{map={level="all",fit=false,sx=1,sz=1,cx=150,cz=-380}}}, {100,38,{}}, {57,24,{}}}) do
      local w, h, session = view[1], view[2], view[3]
      s.settle(w,h,session)
      s.display.handlers.hello({from=22,body={w=w,h=h,fullH=h}})
      assert(s.display.assign(22,"map"))
      local frame
      s.display.handlers["view.get"]({from=22,body={}},function(_,body) frame=body end)
      local proto=s.machine.env.SO.proto
      local wire,err=proto.encode(proto.build(string.rep("a",64),"view.frame",frame))
      assert(wire,w.."x"..h.." frame does not fit: "..tostring(err))
      if w == 164 then print("map 164x81 dense frame " .. #proto.ser(frame) .. " bytes") end
      equal(#frame.rows,h)
      for _, id in ipairs(CONTROLS) do button(frame,id,w,h) end
    end
  end)

  test("map generator writes every map fixture from the same scene views", function()
    local started, pipe = pcall(io.popen, "pwd")
    local root = started and pipe and pipe:read("*l")
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= "/" or not os.execute("python3 -V > /dev/null 2>&1") then
      return dofile("tests/skips.lua").record("map generator writes every map fixture from the same scene views",
        "needs a POSIX shell and python3")
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' > /dev/null"))
    local function same(a, b) return os.execute("cmp -s '" .. a .. "' '" .. b .. "'") end
    for _, v in ipairs(loadScene().views) do
      assert(same(dir .. "/" .. v.name .. ".txt", root .. "/" .. FIXTURES[v.name]), v.name .. " differs from the generator")
    end
    assert(same(dir .. "/status-W.txt", root .. "/tests/ui/fixtures/status-W.txt"), "status-W differs from the generator")
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)

  test("map thumb draws the status wall thumbnail with its compass", function()
    local s = setup()
    local fixture = R.load("tests/ui/fixtures/status-W.txt")
    local C
    for _ = 1, 20 do
      C = U.canvas(100, 38)
      assert(s.map.thumb(C, 60, 3, 40, 26))
      s.step()
    end
    local out = picture(C.frame(), 100, 38).picture()
    local function chars(text)
      local list = {}
      for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do list[#list+1] = ch end
      return list
    end
    for y = 3, 28 do
      local want, got = chars(fixture.text[y]), chars(out.text[y])
      for x = 60, 99 do
        equal(got[x], want[x], "thumb text at " .. x .. "," .. y)
        if want[x] ~= " " then equal(out.fg[y]:sub(x, x), fixture.fg[y]:sub(x, x), "thumb fg at " .. x .. "," .. y) end
        equal(out.bg[y]:sub(x, x), fixture.bg[y]:sub(x, x), "thumb bg at " .. x .. "," .. y)
      end
    end
    equal(C.frame().rows[3].text:sub(98, 99), NORTH)
    equal(s.map.thumb(U.canvas(2, 1), 1, 1, 2, 1), false)
  end)

  test("map crop draws one block per cell around an alert subject, inverted", function()
    local s = setup()
    local C
    for _ = 1, 10 do
      C = U.canvas(49, 13)
      assert(s.map.crop(C, 1, 1, 49, 13, {x=184, y=-58, z=-369, id=6}))
      s.step()
    end
    local out = picture(C.frame(), 49, 13)
    -- At the mine level, shifted so the scene fills the crop: #6 ends its branch two cells from the
    -- right edge, inverted, with its branch running west of it.
    local c = out.cells[7][48]
    equal(c[1], U.g.right) equal(c[2], "f") equal(c[3], "e")
    equal(out.cells[7][40][1], "-")
    local text = table.concat(out.picture().text, "\n")
    assert(not text:find("6 lost", 1, true), "the subject has no label")
    assert(not text:find("\226\134\145N", 1, true), "no compass in the crop")
    C = U.canvas(49, 13)
    assert(s.map.crop(C, 1, 1, 49, 13, {x=123, y=64, z=-337, drop=3}))
    out = picture(C.frame(), 49, 13)
    c = out.cells[7][25]
    equal(c[1], U.g.cross) equal(c[2], "f") equal(c[3], "e")
    equal(s.map.crop(U.canvas(5, 5), 1, 1, 5, 5, {}), false)
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

  test("map broken chest chip centres and picks each broken chest, and a broken chest wins its cell", function()
    local s = setup()
    local drops = s.scene.drops
    drops[#drops+1] = {id=#drops+1, kind="ore", dim=0, x=150, y=-58, z=-366, broken=true}
    s.mine.turtles["2"].pose = {x=123, y=64, z=-337, facing=0}
    s.step()
    local session = {map={level="all", fit=true}}
    local frame = s.settle(57, 24, session)
    local chip = button(frame, "map-broken", 57, 24)
    equal(row(frame, 1):sub(chip.x, chip.x + chip.w - 1), " " .. U.g.cross .. "2 ")
    local function press(id) s.screen.input({id=id, session=session, x=1, y=1}) end
    press("map-broken")
    local v = session.map
    equal(v.pick.id, "3") equal(v.cx, 123) equal(v.cz, -337) equal(v.sx, 1) equal(v.sz, 1) equal(v.fit, false)
    local out = picture(s.settle(57, 24, session), 57, 24)
    equal(cell(out, v, 123, -337)[1], U.g.cross, "the beacon wins over the turtle on it")
    assert(table.concat(out.picture().text, "\n"):find("broken", 1, true), "the callout names the state")
    press("map-broken") equal(v.pick.id, "5") equal(v.cx, 150)
    press("map-broken") equal(v.pick.id, "3")
    press("map-drop:5") equal(v.pick.id, "5")
    press("map-focus") equal(v.pick.id, "3")
    for _, d in ipairs(drops) do d.broken = false end
    s.step()
    frame = s.settle(57, 24, {map={level="all", fit=true}})
    for _, b in ipairs(frame.buttons) do assert(b.id ~= "map-broken", "no chip without broken chests") end
    assert(row(frame, 1):find("^ MAP"))
  end)

  test("map draws the next branch of a running job in amber", function()
    local s = setup()
    s.mine.preview = {{x=120, y=-58, z=-381}, {x=184, y=-58, z=-381}}
    s.step()
    local session = {map={level=-58, fit=false, sx=1, sz=1, cx=150, cz=-378}}
    local out, v = picture(s.settle(57, 24, session), 57, 24), session.map
    equal(cell(out, v, 170, -381)[2], "1") equal(cell(out, v, 170, -381)[1], U.g.dot)
    equal(cell(out, v, 130, -377)[2], "3", "dug cells stay steel")
    s.mine.preview = nil s.step()
    out = picture(s.settle(57, 24, session), 57, 24)
    equal(cell(out, v, 170, -381)[2], "8", "planned again once a turtle takes it")
    s.mine.preview = {{x=120, y=-58, z=-381}, {x=184, y=-58, z=-381}} s.mine.dim = "minecraft:the_nether" s.step()
    out = picture(s.settle(57, 24, session), 57, 24)
    for x = 121, 184 do local c = cell(out, v, x, -381) assert(not c or c[2] ~= "1", "preview from another dimension") end
  end)

  test("map shows every lumber turtle on the farm and reads leases with peek", function()
    local s = setup()
    s.lumber.turtles["8"] = {id=8, pose={x=104, y=65, z=-342, facing=1}, state="lumber", phase="plant"}
    s.statusCalls = nil
    s.step()
    local session = {map={level="all", fit=true, pick={k="turtle", id="8"}}}
    local text = table.concat(picture(s.settle(57, 24, session), 57, 24).picture().text, "\n")
    assert(text:find("#8 planting", 1, true), text)
    session.map.pick = {k="turtle", id="5"}
    text = table.concat(picture(s.settle(57, 24, session), 57, 24).picture().text, "\n")
    assert(text:find("#5", 1, true), text)
    equal(s.statusCalls, nil, "lease.status creates rows; the map only peeks")
  end)

  test("map turtle callout offers the turtle details", function()
    local s = setup()
    local session = {map={level=-58, fit=false, sx=1, sz=1, cx=158, cz=-367, pick={k="turtle", id="6"}}}
    local frame = s.settle(57, 24, session)
    local b = button(frame, "turtle:6", 57, 24)
    equal(frame.rows[b.y].text:sub(b.x, b.x + b.w - 1), " DETAILS ")
  end)

  test("map switches dimension only with remoteDimensions on", function()
    local s = setup()
    local m = s.machine
    s.mine.turtles["9"] = {pose={x=10, y=40, z=10, facing=0}, state="mining", dim="minecraft:the_nether"}
    s.machines["9"] = {id=9, role="worker", fuel=900, seen=m.env.os.epoch("utc")}
    local session = {map={level="all", fit=true}}
    local frame = s.settle(57, 24, session)
    for _, b in ipairs(frame.buttons) do assert(b.id ~= "map-dim", "dimension chip while off") end
    s.screen.input({id="map-dim", session=session, x=1, y=1})
    equal(session.map.dim, nil)
    m.files["so-server.cfg"] = H.encode({pos=s.scene.server, remoteDimensions=true})
    s.net.advance(6) s.map.tick(m.env.SO.now())
    for _, size in ipairs({{57,24},{26,20},{100,38},{39,19}}) do
      frame = s.screen.render(size[1], size[2], {map={level="all", fit=true}})
      local b = button(frame, "map-dim", size[1], size[2])
      assert(frame.rows[1].text:sub(b.x, b.x + b.w - 1):find("OVER"), frame.rows[1].text)
      -- Pocket 26 has room for one chip: the dimension takes the title's place.
      if size[1] ~= 26 then button(frame, "map-broken", size[1], size[2]) end
    end
    s.screen.input({id="map-dim", session=session, x=1, y=1})
    equal(session.map.dim, "minecraft:the_nether")
    session.map.pick = {k="turtle", id="9"}
    frame = s.screen.render(57, 24, session)
    local text = table.concat(picture(frame, 57, 24).picture().text, "\n")
    assert(text:find("NETH", 1, true) and text:find("#9 mining", 1, true), text)
    assert(not text:find("server", 1, true), "the overworld server is not in the nether")
    s.screen.input({id="map-dim", session=session, x=1, y=1}) equal(session.map.dim, "minecraft:the_end")
    s.screen.input({id="map-dim", session=session, x=1, y=1}) equal(session.map.dim, "minecraft:overworld")
  end)

  test("B2-B map gathers copied dimension-filtered builder bounds and confirmed poses",function()
    local s=setup()
    local f=dofile("tests/so/build-fixture.lua")()
    f.configure("floor",2,1,1) f.tick() f.report()
    s.machine.env.SO.mods.build={mapView=function() return f.mod().mapView() end}
    local M=mapState(s)
    local before=f.job()
    local view=M.gather(0).build
    equal(view.bounds,{dim="minecraft:overworld",x1=0,y1=0,z1=0,x2=1,y2=0,z2=0})
    equal(view.turtles["2"].pose,{dim="minecraft:overworld",x=-2,y=4,z=0,f=1})
    equal(M.gather(0,"minecraft:the_nether").build,nil)
    f.uncertain=true
    view=M.gather(1).build
    equal(view.turtles,{}) assert(view.bounds)
    equal(f.job(),before)
    view.bounds.x1=900
    equal(f.mod().mapView().bounds.x1,0)
  end)
  test("B2-B map never aliases builder adapter tables or invents an unknown pose",function()
    local s=setup()
    local source={dim="minecraft:overworld",bounds={x1=0,y1=0,z1=0,x2=1,y2=0,z2=1},turtles={}}
    s.machine.env.SO.mods.build={mapView=function() return source end}
    local M=mapState(s)
    local view=M.gather(0).build
    view.bounds.x1=12
    equal(source.bounds.x1,0) equal(view.turtles,{})
    equal(M.gather(1).build.bounds.x1,0)
  end)


  test("B2-B a standalone builder supplies its dimension when the server and other jobs have none",function()
    local s=setup()
    s.mine,s.lumber={},{}
    s.machine.files["so-server.cfg"]=H.encode({})
    s.machine.env.SO.mods.build={mapView=function() return {dim="minecraft:the_nether",turtles={}} end}
    local scene=mapState(s).gather(6000)
    equal(scene.dim,"minecraft:the_nether") equal(scene.build.dim,"minecraft:the_nether")
  end)

  test("B3-B map RELEASE waits for fenced GPS and validates the drawn confirmation",function()
    local s=setup()
    local m=s.machine
    m.files["so-server.cfg"]=H.encode({worldEdits=true})
    m.env.rednet.send=function() return true end
    m.env.SO.pair.key=function() return string.rep("a",64) end
    local lease=m.env.dofile("so-mod-lease.lua") m.env.SO.mods.lease=lease
    lease.handlers.hello({from=99,body={role="worker",dim="minecraft:overworld",
      capabilities={setupFence=true,parkBatch=true},journal={id="before",pose={x=0,y=0,z=0,f=0}}}})
    assert(s.cells.reserve("setup:99",1000,64,1000))
    s.net.time=s.net.time+300000
    s.reloadMap()
    local session={id=10,w=57,h=24,map={fit=false,sx=1,sz=1,cx=1000,cz=1000,level=64,pick={k="cell",x=1000,z=1000}}}
    local function frame() return s.screen.render(57,24,session) end
    local b=button(frame(),"map-release",57,24)
    s.screen.input({id="map-release",session=session,from=10,x=1,y=1})
    equal(session.map.releaseToken,nil)
    s.screen.input({id="map-release",session=session,from=10,x=b.x,y=b.y})
    assert(session.map.releaseToken)
    equal(lease.peek(99).open,nil)
    b=button(frame(),"map-release",57,24)
    s.screen.input({id="map-release",session=session,from=10,x=b.x,y=b.y})
    equal(s.cells.owner(1000,64,1000),"setup:99")
    local lid=assert(lease.peek(99).open)
    local waiting=frame() local text=""
    for _,r in ipairs(waiting.rows) do text=text..r.text end
    assert(text:find("WAIT GPS",1,true))
    lease.handlers["step.report"]({from=99,body={lease=lid,journal="after",pose={x=0,y=0,z=0,f=0},
      results={{ok=true,data={dim="minecraft:overworld",x=1001,y=64,z=1000}}}}})
    equal(s.cells.owner(1000,64,1000),nil)
    equal(s.cells.owner(1001,64,1000),"gps:99")
  end)

  test("B3-B map RELEASE stays absent with world edits off",function()
    local s=setup()
    assert(s.cells.reserve("setup:99",1000,64,1000))
    local session={id=10,w=57,h=24,map={fit=false,sx=1,sz=1,cx=1000,cz=1000,level=64,pick={k="cell",x=1000,z=1000}}}
    local f=s.screen.render(57,24,session)
    for _,b in ipairs(f.buttons) do assert(b.id~="map-release") end
    s.screen.input({id="map-release",session=session,from=10,x=2,y=2})
    equal(s.cells.owner(1000,64,1000),"setup:99")
  end)


  test("B2-U map draws the builder only at its confirmed pose in the shown dimension",function()
    local s=setup()
    builder(s)
    local session={map={level="all",fit=true}}
    local frame=s.settle(57,24,session)
    local out=picture(frame,57,24)
    local v=session.map
    local old=cell(out,v,118,-334)
    assert(not old or old[1]~=U.arrow(0),"builder drawn at its older machine pose")
    for _,t in ipairs(mapState(s).scene.turtles) do assert(t.id~="8","nether builder in the overworld") end
    assert(not textOf(frame):find("build",1,true),"nether blueprint in the overworld")
    s.machine.files["so-server.cfg"]=H.encode({pos=s.scene.server,remoteDimensions=true})
    s.reloadMap()
    session={map={level="all",fit=true,dim="minecraft:the_nether"}}
    frame=s.settle(57,24,session)
    out,v=picture(frame,57,24),session.map
    local c=cell(out,v,146,-326)
    equal(c[1],U.arrow(1)) equal(c[2],"1")
    assert(textOf(frame):find("8 held",1,true),textOf(frame))
  end)

  test("B2-U map draws the blueprint outline, held label and callout like its twin",function()
    local s=setup()
    local b=builder(s,"minecraft:overworld")
    local started,pipe=pcall(io.popen,"pwd")
    local root=started and pipe and pipe:read("*l")
    if started and pipe then pipe:close() end
    for _,pick in ipairs({false,"8"}) do
      local session={map={level="all",fit=true,pick=pick and {k="turtle",id=pick} or nil}}
      local frame=s.settle(57,24,session)
      local out,v=picture(frame,57,24),session.map
      local corner=cell(out,v,140,-330)
      equal(corner[1],"+") equal(corner[2],"1")
      local marker=cell(out,v,146,-326)
      equal(pick and marker[3] or marker[2],"1")
      local text=textOf(frame)
      -- The callout may cover the label; without it the label always shows while held.
      if not pick then assert(text:find("build held",1,true),text) end
      if pick then
        assert(text:find("Build needs material",1,true) and text:find("4/40",1,true),text)
      end
      if root and root:sub(1,1)=="/" and os.execute("python3 -V > /dev/null 2>&1") then
        local path=os.tmpname()
        local py=("import sys; sys.path.insert(0, '%s'); import mapdraw as MD, mapscreen as MS; "
          .."MD.BUILD['dim'] = 'overworld'; MS.screen(57, 24, 'builder', pick=%s).fixture('%s')")
          :format(root.."/docs/ui/schematic",pick and "('turtle', '8')" or "None",path)
        assert(os.execute("python3 -I -c \""..py.."\""))
        local diffs=R.diff(R.load(path),out.picture())
        os.remove(path)
        equal(#diffs,0,"builder twin\n"..table.concat(diffs,"\n"))
      else dofile("tests/skips.lua").record("B2-U builder twin","needs a POSIX shell and python3") end
    end
    b.alert={severity=1,text="Build path blocked"}
    s.reloadMap()
    local session={map={level="all",fit=true}}
    local out=picture(s.settle(57,24,session),57,24)
    equal(cell(out,session.map,152,-322)[2],"e")
    equal(cell(out,session.map,146,-326)[2],"e")
  end)

  test("B2-U map keeps the blueprint outline when the builder pose is unknown",function()
    local s=setup()
    local b=builder(s,"minecraft:overworld")
    b.pose=nil
    s.reloadMap()
    local session={map={level="all",fit=true}}
    local frame=s.settle(57,24,session)
    local out,v=picture(frame,57,24),session.map
    for _,t in ipairs(mapState(s).scene.turtles) do assert(t.id~="8","builder drawn with an unknown pose") end
    local old=cell(out,v,118,-334)
    assert(not old or old[1]~=U.arrow(0),"builder drawn at its older machine pose")
    equal(cell(out,v,140,-330)[1],"+") equal(cell(out,v,152,-322)[1],"+")
    equal(cell(out,v,146,-330)[1],"-") equal(cell(out,v,140,-326)[1],"|")
    assert(textOf(frame):find("build held",1,true))
    -- FIT holds the blueprint even with every other job gone.
    s.mine,s.lumber,s.scene.drops={},{},{}
    for id in pairs(s.machines) do if id~="8" then s.machines[id]=nil end end
    s.machine.files["so-server.cfg"]=H.encode({})
    s.reloadMap()
    session={map={level="all",fit=true}}
    out,v=picture(s.settle(57,24,session),57,24),session.map
    equal(cell(out,v,140,-330)[1],"+") equal(cell(out,v,152,-322)[1],"+")
  end)

  test("B2-U map shows a running build's progress, hides it off its levels and keeps the frame budget",function()
    local s=setup()
    local b=builder(s,"minecraft:overworld")
    b.state,b.alert="running",nil
    s.reloadMap()
    local session={map={level="all",fit=true}}
    local frame=s.settle(57,24,session)
    local out,v=picture(frame,57,24),session.map
    equal(cell(out,v,140,-330)[2],"9") equal(cell(out,v,146,-326)[2],"d")
    local text=textOf(frame)
    assert(text:find("build 4/40",1,true) and not text:find("8 running",1,true),text)
    session={map={level=63,fit=false,sx=1,sz=1,cx=146,cz=-326}}
    out,v=picture(s.settle(57,24,session),57,24),session.map
    equal(cell(out,v,140,-330)[1]," ")
    session={map={level=66,fit=false,sx=1,sz=1,cx=146,cz=-326}}
    out,v=picture(s.settle(57,24,session),57,24),session.map
    equal(cell(out,v,140,-330)[1],"+")
    local proto=s.machine.env.SO.proto
    session={map={level="all",fit=true}}
    assert(#proto.ser(s.settle(164,81,session))<=15000,"builder frame over budget")
  end)


  test("B4-UD ore drawing matches every fixture in the shared scene",function()
    local fixtures = {
      ["map-ore-off"]="tests/ui/fixtures/map-ore-off.txt", ["map-ore-all"]="tests/ui/fixtures/map-ore-all.txt",
      ["map-ore-level"]="tests/ui/fixtures/map-ore-level.txt", ["map-ore-zoom"]="tests/ui/fixtures/map-ore-zoom.txt",
      ["map-ore-boundary"]="tests/ui/fixtures/map-ore-boundary.txt", ["map-ore-expired"]="tests/ui/fixtures/map-ore-expired.txt",
      ["map-ore-callout"]="tests/ui/fixtures/map-ore-callout.txt"}
    for _, spec in ipairs(loadScene().oreViews) do
      local s=setup()
      local now=s.machine.env.SO.now()
      s.machine.env.SO.now=function() return now+spec.elapsed end
      local events=s.scene.finds
      for _,ev in ipairs(events) do ev.gameAt=now+ev.gameAt end
      s.machine.env.SO.mods.state.history={page=function(q)
        if q.kind~="mine.ore" then return {entries={}} end
        local entries={}
        for _,ev in ipairs(events) do if ev.seq>q.from then entries[#entries+1]=ev end end
        return {entries=entries}
      end}
      local M=mapState(s)
      M.readFinds(now)
      M.pruneFinds(now+spec.elapsed)
      local scene=M.gather(now+spec.elapsed)
      local v=M.view({map=spec.map})
      v.mw,v.mh=spec.w,spec.h
      for _=1,60 do M.prepare(v,scene) if v.ready then break end s.step() end
      assert(v.ready,"ore fixture planes never loaded")
      local C=U.canvas(spec.w,spec.h)
      local taken=M.draw(C,v,scene,1,1,v.pick,nil,{},0,M.findCells(v,scene))
      if v.pick then M.box(C,v,scene,1,1,v.pick,taken) end
      local diff=R.diff(fixtures[spec.name],picture(C.frame(),spec.w,spec.h).picture())
      equal(#diff,0,spec.name.."\n"..table.concat(diff,"\n"))
    end
  end)

  test("B4-UD generator reproduces every committed ore fixture",function()
    local started,pipe=pcall(io.popen,"pwd")
    local root=started and pipe and pipe:read("*l")
    if started and pipe then pipe:close() end
    if not root or root:sub(1,1)~="/" or not os.execute("python3 -V > /dev/null 2>&1") then
      return dofile("tests/skips.lua").record("B4-UD ore fixture generator","needs a POSIX shell and python3")
    end
    local dir=os.tmpname()
    os.remove(dir)
    assert(os.execute("python3 -I '"..root.."/docs/ui/schematic/mapdraw.py' --fixtures '"..dir.."' > /dev/null"))
    local mismatches={}
    for _,spec in ipairs(loadScene().oreViews) do
      if not os.execute("cmp -s '"..dir.."/"..spec.name..".txt' '"..root.."/tests/ui/fixtures/"..spec.name..".txt'") then
        mismatches[#mismatches+1]=spec.name
      end
    end
    assert(os.execute("rm -r '"..dir.."'"))
    equal(mismatches,{})
  end)

  test("B2-U map replaces a listed turtle's row with the builder's, like its twin",function()
    local started,pipe=pcall(io.popen,"pwd")
    local root=started and pipe and pipe:read("*l")
    if started and pipe then pipe:close() end
    local twin=root and root:sub(1,1)=="/" and os.execute("python3 -V > /dev/null 2>&1")
    -- Turtle 6 is a mining row in the scene; the builder takes it over, with and without a pose.
    for _,known in ipairs({true,false}) do
      local s=setup()
      local b=builder(s,"minecraft:overworld","6")
      if not known then b.pose=nil s.reloadMap() end
      local session={map={level="all",fit=true,pick=known and {k="turtle",id="6"} or nil}}
      local frame=s.settle(100,38,session)
      local out,v=picture(frame,100,38),session.map
      local rows=0
      for _,t in ipairs(mapState(s).scene.turtles) do if t.id=="6" then rows=rows+1 assert(t.build,"older row for 6") end end
      equal(rows,known and 1 or 0)
      local old=cell(out,v,184,-369)
      assert(not old or old[1]~=U.arrow(1),"turtle 6 drawn at its mining row")
      local text=textOf(frame)
      if known then assert(text:find("Build needs material",1,true) and text:find("4/40",1,true),text) end
      if twin then
        local path=os.tmpname()
        local py=("import sys; sys.path.insert(0, '%s'); import mapdraw as MD, mapscreen as MS; "
          .."MD.BUILD['dim'] = 'overworld'; MD.BUILD['id'] = '6'; %s"
          .."MS.screen(100, 38, 'builder', pick=%s).fixture('%s')")
          :format(root.."/docs/ui/schematic",known and "" or "MD.BUILD['turtle'] = None; ",
            known and "('turtle', '6')" or "None",path)
        assert(os.execute("python3 -I -c \""..py.."\""))
        local diffs=R.diff(R.load(path),out.picture())
        os.remove(path)
        equal(#diffs,0,"builder 6 twin\n"..table.concat(diffs,"\n"))
      else dofile("tests/skips.lua").record("B2-U builder 6 twin","needs a POSIX shell and python3") end
    end
  end)

end
