local U = dofile("so-ui.lua")
-- Top-down map in route A (docs/ui/SCHEMATIC-SPEC.md section 10). North is up at every size: x grows
-- to the right and z downwards. A text cell covers sx by sz blocks and takes a line glyph from the
-- dug, planned and held blocks inside it; the axis the branches step along snaps to the branch gap.
-- docs/ui/schematic/mapdraw.py and mapscreen.py are the twins that make the fixtures.
local M = { planes = {}, keys = {}, columns = {}, layouts = {}, aux = {}, serial = 0, budget = 16, cursor = 1, ticks = 0,
  version = 0, marks = 0, swept = 0, margin = 7, off = 2 ^ 25, row = 2 ^ 26, heavy = 15000,
  dirs = {[0]={0,-1},{1,0},{0,1},{-1,0}},
  facings = {[0]=0,1,2,3,north=0,east=1,south=2,west=3},
  dimensions = {[0]="minecraft:overworld",[-1]="minecraft:the_nether",[1]="minecraft:the_end"},
  heights = {["minecraft:overworld"]={-64,319}, ["minecraft:the_nether"]={1,126}, ["minecraft:the_end"]={1,255}},
  phases = {scan="scanning",base="felling",climb="felling",descend="felling",plant="planting",plantPlace="planting"},
  -- Cells per text cell: any step on a free axis, divisors and multiples of the gap on the branch axis.
  free = {1,2,3,4,6,8,12,16,24,32,48,64}, snap = {1,2,4,8,16,32,64},
  pan = {["map-n"]={0,-1},["map-e"]={1,0},["map-s"]={0,1},["map-w"]={-1,0}},
  prefer = {"r","l","ur","dr","ul","dl","u","d"}, east = {"ur","dr","r","ul","dl","l"}, along = {"r","l","ur","dr"},
  drop = {"r","l","d","dr","dl","u","ur","ul"}, farm = {"u","ur","r"},
  compass = "\24N", hex = {}, bitsOf = {}, scenes = {}, trails = {}, trailVersion = 0, trailCursor = 0, trailLimit = 32,
  -- The dimension chip (remoteDimensions only): its label and the next dimension.
  dimLabel = {["minecraft:overworld"]="OVER",["minecraft:the_nether"]="NETH",["minecraft:the_end"]="END"},
  nextDim = {["minecraft:overworld"]="minecraft:the_nether",["minecraft:the_nether"]="minecraft:the_end",
    ["minecraft:the_end"]="minecraft:overworld"} }
for i = 0, 15 do
  M.hex[("0123456789abcdef"):byte(i + 1)] = i
  M.bitsOf[i] = {}
  for b = 0, 3 do if math.floor(i / 2 ^ b) % 2 == 1 then M.bitsOf[i][#M.bitsOf[i] + 1] = b end end
end

M.call = function(name, method, ...)
  local mod = SO.mods[name]
  if mod and type(mod[method]) == "function" then return mod[method](...) end
end
M.dim = function(dim) return M.dimensions[dim] or dim or "minecraft:overworld" end
M.geometry = function(j, dim)
  if not j.home or j.homeSet == false or M.dim(j.dim) ~= dim then return end
  local f = (j.home.facing or 0) % 4
  local d, r = M.dirs[f], M.dirs[(f + 1) % 4]
  local gap, branches = j.mode == "fast" and 2 or 4, math.min(4096, math.max(0, j.branches or 0))
  return {x=j.home.x+d[1], z=j.home.z+d[2], top=j.home.y, bottom=j.bottom or j.home.y, dx=d[1], dz=d[2],
    rx=r[1], rz=r[2], gap=gap, branches=branches, length=j.length or 64, spine=branches*gap}
end
-- The shared shaft and spine path; mining holds it as one lane.
M.lane = function(g, c)
  if c.x == g.x and c.z == g.z then return c.y >= math.min(g.top, g.bottom) and c.y <= math.max(g.top, g.bottom) end
  local ax, az = c.x - g.x, c.z - g.z
  local along = ax * g.dx + az * g.dz
  return c.y == g.bottom and ax * g.dz - az * g.dx == 0 and along >= 0 and along <= g.spine
end
M.surface = function(s) return s.server and s.server.y or s.ground or s.g and s.g.top or 64 end
-- "z" when the spine runs north-south (branches are rows), "x" when east-west.
M.axis = function(g) return g and (g.dz ~= 0 and "z" or "x") or nil end
M.phase = function(g) return M.axis(g) == "z" and g.z + g.dz * g.gap or g.x + g.dx * g.gap end
M.onGeo = function(g, x, z)
  local ax, az = x - g.x, z - g.z
  local along, side = ax * g.dx + az * g.dz, ax * g.rx + az * g.rz
  if side == 0 and along >= 0 and along <= g.spine then return true end
  return along >= g.gap and along <= g.spine and along % g.gap == 0 and side >= 1 and side <= g.length
end
M.farmOn = function(s, level) return s.area ~= nil and (level == "all" or level >= s.ground and level <= s.ground + 8) end
M.near = function(p, level) return level == "all" or math.abs((p.y or level) - level) <= 1 end

-- The scene of one dimension: the server's own, or pick (remoteDimensions). Returns it and keeps
-- it in M.scenes; callers set M.scene.
M.gather = function(now, pick)
  if not M.config or now >= (M.configAt or 0)+5000 then
    M.config, M.configAt = SO.store.read("so-server.cfg") or {}, now
  end
  local config = M.config
  local mine = M.call("mine", "mapView") or {}
  local lumber = M.call("lumber", "mapView") or {}
  local dim = pick or M.dim(config.pos and config.pos.dim or mine.dim or lumber.dim)
  local s = {now=now, dim=dim, g=M.geometry(mine, dim), turtles={}, drops={}, spots={}, broken=0}
  -- The next branch a running job will start, amber until a turtle takes it.
  local pv = type(mine.preview) == "table" and mine.preview
  if pv and type(pv[1]) == "table" and type(pv[2]) == "table" and M.dim(mine.dim) == dim
      and tonumber(pv[1].x) and tonumber(pv[1].z) and tonumber(pv[2].x) and tonumber(pv[2].z) then
    s.preview = {x=pv[1].x, y=pv[1].y, z=pv[1].z, ex=pv[2].x, ez=pv[2].z}
  end
  local pos = config.pos
  if type(pos) == "table" and tonumber(pos.x) and tonumber(pos.z) and M.dim(pos.dim) == dim then s.server = pos end
  if lumber.area and M.dim(lumber.dim) == dim then
    local a = lumber.area
    s.area = {x1=math.min(a.x1, a.x2), z1=math.min(a.z1, a.z2), x2=math.max(a.x1, a.x2), z2=math.max(a.z1, a.z2)}
    s.ground, s.spots = lumber.ground or 64, {}
    for _, spot in ipairs(lumber.spots or {}) do
      if tonumber(spot.x) and tonumber(spot.z) then s.spots[#s.spots+1] = spot end
    end
  end
  local jobs, machines = {}, M.call("state", "get", "machines") or {}
  for id, machine in pairs(machines) do
    if machine.role == nil or machine.role == "worker" or machine.role == "turtle" then jobs[tostring(id)] = {} end
  end
  local assigned = {}
  for id, row in pairs(mine.turtles or {}) do jobs[tostring(id)], assigned[tostring(id)] = row, row end
  -- Every turtle on the farm (lumber.turtles), or the one turtle of an older lumber view.
  local wood = lumber.turtles or {}
  if lumber.turtle then wood = {lumber.turtle} end
  for id, row in pairs(wood) do
    assigned[tostring(row.id or id)] = row
    jobs[tostring(row.id or id)] = {pose=row.pose, dim=row.dim or lumber.dim,
      state=row.state == "lumber" and (M.phases[row.phase] or "working") or row.state}
  end
  M.workers = {}
  for id, row in pairs(assigned) do
    if not (row.paused or row.removeRequested or row.state == "parked" or row.state == "parking") then M.workers[id] = true end
  end
  for id, row in pairs(jobs) do
    local machine = machines[id] or machines[tonumber(id)] or {}
    local p = row.pose or machine.pose
    if type(p) == "table" and tonumber(p.x) and tonumber(p.z) and M.dim(p.dim or row.dim or machine.dim) == dim then
      local status = M.call("lease", "peek", tonumber(id) or id) or {}
      local word = tostring(row.state or "idle")
      if status.lost then word = "lost"
      elseif M.call("lease", "inRange", tonumber(id) or id, p) == false then word = "range" end
      s.turtles[#s.turtles+1] = {id=tostring(id), pose=p, facing=M.facings[p.facing or p.f], word=word, tone=U.tone(word),
        fuel=machine.fuel, ore=row.ores, ago=math.max(0, now - (machine.seen or now)),
        lease=status.lost and "expired" or status.open and "open" or "-", last=status.last,
        range=word == "range" and dim == "minecraft:overworld" and s.server and tonumber(p.y) and tonumber(s.server.y) and
          math.ceil(math.sqrt((p.x-s.server.x)^2 + (p.y-s.server.y)^2 + (p.z-s.server.z)^2)) .. "/" ..
          math.floor((status.range or 16) + 8) or nil}
    end
  end
  table.sort(s.turtles, function(a, b)
    local x, y = tonumber(a.id), tonumber(b.id)
    if x and y and x ~= y then return x < y end
    if (x == nil) ~= (y == nil) then return x ~= nil end
    return a.id < b.id
  end)
  for i, p in ipairs(M.call("drops", "list") or {}) do
    if M.dim(p.dim) == dim and tonumber(p.x) and tonumber(p.z) then
      s.drops[#s.drops+1] = {id=tostring(p.id or i), kind=tostring(p.kind or "drop"), x=p.x, y=p.y, z=p.z, broken=p.broken and true or false}
    end
  end
  local sap = lumber.saplings
  if type(sap) == "table" and tonumber(sap.x) and tonumber(sap.z) and M.dim(lumber.dim) == dim then
    local p = sap
    s.drops[#s.drops+1] = {id="saplings", kind="saplings", x=p.x, y=p.y, z=p.z, broken=false}
  end
  for _, p in ipairs(s.drops) do if p.broken then s.broken = s.broken + 1 end end
  local reserved, version = M.call("cells", "reserved", dim, 4096)
  s.reserved = reserved or {}
  local terrain, markers = {dim, tostring(version)}, {}
  for _, key in ipairs({"x","z","top","bottom","dx","dz","branches","length","gap"}) do terrain[#terrain+1] = s.g and s.g[key] or "" end
  if s.area then
    for _, key in ipairs({"x1","z1","x2","z2"}) do terrain[#terrain+1] = s.area[key] end
    terrain[#terrain+1] = s.ground
    for _, spot in ipairs(s.spots) do terrain[#terrain+1] = spot.x .. "," .. spot.z .. (spot.ready and "r" or "") end
  end
  if s.preview then
    local q = s.preview
    terrain[#terrain+1] = table.concat({"p", q.x, tostring(q.y), q.z, q.ex, q.ez}, ",")
  end
  for _, t in ipairs(s.turtles) do
    markers[#markers+1] = table.concat({t.id, t.pose.x, t.pose.y, t.pose.z, tostring(t.facing), t.word,
      tostring(t.fuel), tostring(t.ore), U.age(t.ago, true), t.lease, tostring(t.range), t.last and
        table.concat({t.last.status, tostring(t.last.ok), U.age(math.max(0, now-t.last.at), true)}, ",") or ""}, ",")
  end
  for _, p in ipairs(s.drops) do markers[#markers+1] = table.concat({p.id, p.kind, p.x, p.y, p.z, tostring(p.broken)}, ",") end
  if s.server then markers[#markers+1] = s.server.x .. "," .. s.server.y .. "," .. s.server.z end
  s.terrain, s.markers = table.concat(terrain, ";"), table.concat(markers, ";")
  M.version, M.newMarks = M.call("cells", "dugVersion")
  M.version = M.version or 0
  M.scenes[dim] = s
  return s
end
-- Refresh one worker per tick. History returns its newest 20 pose events in one page.
M.readTrail = function()
  -- A lost or blocked label can hide F4-A's pause state. Generation recovery is read-only.
  if M.config.workerPark == true and next(M.workers or {}) then
    for _, role in ipairs({"mine", "lumber"}) do
      local ok, box = pcall(SO.store.store, "so-data/" .. role .. "/job", function(v)
        return type(v) == "table" and type(v.turtles) == "table"
      end)
      for id, row in pairs(ok and box.value and box.value.turtles or {}) do
        if row.paused or row.removeRequested then M.workers[tostring(id)] = nil end
      end
    end
  end
  local ids = {}
  for id in pairs(M.workers or {}) do ids[#ids+1] = id end
  for id in pairs(M.trails) do
    if not M.workers[id] then M.trails[id] = nil M.trailVersion = M.trailVersion + 1 end
  end
  table.sort(ids)
  if #ids == 0 then M.trailCursor = 0 return end
  local state = SO.mods.state
  if not (state and state.history and type(state.history.page) == "function") then return end
  M.trailCursor = M.trailCursor % #ids + 1
  local id = ids[M.trailCursor]
  local page = state.history.page({reverse=true, kind="pose", id=tonumber(id) or id, count=20})
  local poses, sig = {}, {}
  for i, ev in ipairs(page.entries) do
    if i > 20 then break end
    local p = ev.data
    if type(p) == "table" and tostring(p.id) == id and type(p.x) == "number"
        and type(p.y) == "number" and type(p.z) == "number" then
      local dim = M.dim(p.dim)
      poses[#poses+1] = {dim=dim, x=p.x, y=p.y, z=p.z, seq=ev.seq}
      sig[#sig+1] = table.concat({ev.seq, dim, p.x, p.y, p.z}, ",")
    end
  end
  sig = table.concat(sig, ";")
  if not M.trails[id] or M.trails[id].sig ~= sig then
    M.trails[id] = {poses=poses, sig=sig}
    M.trailVersion = M.trailVersion + 1
  end
  M.trails[id].used = M.ticks
  local count, oldest = 0, nil
  for key, trail in pairs(M.trails) do
    count = count + 1
    if not oldest or trail.used < M.trails[oldest].used
        or trail.used == M.trails[oldest].used and key < oldest then oldest = key end
  end
  if count > M.trailLimit then M.trails[oldest] = nil M.trailVersion = M.trailVersion + 1 end
end
-- The scene a view shows: its own dimension with remoteDimensions on, else the server's.
M.selected = function(v)
  if not (M.config and M.config.remoteDimensions == true and v.dim) then return M.scene end
  if not M.scenes[v.dim] then M.gather(SO.now(), v.dim) end
  return M.scenes[v.dim]
end

M.view = function(session)
  local v = session.map or {fit=true}
  session.map = v
  if type(v.level) ~= "number" then v.level = "all" end
  v.cx, v.cz = tonumber(v.cx) or 0, tonumber(v.cz) or 0
  -- Views saved before route A carry a zoom and no scale: they fit again.
  if not (tonumber(v.sx) and tonumber(v.sz)) then v.fit = true end
  return v
end

-- Sizes: wall (80x30 and up) with a roster strip, room (52 wide) with every control on top, pocket
-- (25 wide) with pan and zoom on the last row, tiny with them on the last two rows.
M.layout = function(w, h, n)
  local key = w .. "x" .. h .. ":" .. n
  if M.layouts[key] then return M.layouts[key] end
  local kind = w >= 80 and h >= 30 and "wall" or w >= 52 and "room" or w >= 25 and "pocket" or "tiny"
  local L = {kind=kind, mx=1, my=2, mw=w}
  if kind == "room" then L.mh = h - 1
  elseif kind == "pocket" then L.mh = h - 2
  elseif kind == "tiny" then L.mh = h - 3
  else
    local cols = math.floor((w - 32) / 33) + 1
    local lines = math.min(4, math.ceil(n / cols))
    local rows = 2 * lines
    L.my, L.mh = 3, h - 2 - (rows > 0 and rows + 1 or 0)
    if rows > 0 then L.roster = {y=h - rows + 1, cols=cols, lines=lines} end
  end
  L.mh = math.max(1, L.mh)
  M.layouts[key] = L
  return L
end

M.bounds = function(s, level)
  local b
  local function add(x, z)
    if not b then b = {x, z, x, z} return end
    b[1], b[2], b[3], b[4] = math.min(b[1], x), math.min(b[2], z), math.max(b[3], x), math.max(b[4], z)
  end
  local g = s.g
  if g then
    add(g.x, g.z)
    if g.branches > 0 then
      for _, p in ipairs({{g.spine, 0}, {g.gap, g.length}, {g.spine, g.length}}) do
        add(g.x + g.dx * p[1] + g.rx * p[2], g.z + g.dz * p[1] + g.rz * p[2])
      end
    end
  end
  if M.farmOn(s, level) then add(s.area.x1, s.area.z1) add(s.area.x2, s.area.z2) end
  for _, p in ipairs(s.drops) do if M.near(p, level) then add(p.x, p.z) end end
  if s.server and M.near(s.server, level) then add(s.server.x, s.server.z) end
  for _, t in ipairs(s.turtles) do if M.near(t.pose, level) then add(t.pose.x, t.pose.z) end end
  return b
end
-- The first scale on the ladder that fits lo..hi in room cells; the start snaps to ph.
M.span = function(lo, hi, room, ladder, ph)
  local s, start
  for _, step in ipairs(ladder) do
    s, start = step, ph and lo - (lo - ph) % step or lo
    if math.floor((hi - start) / s) + 1 <= room then break end
  end
  return s, start, math.floor((hi - start) / s) + 1
end
M.fit = function(v, s, valign)
  local b = M.bounds(s, v.level)
  if not b then v.sx, v.sz, v.left, v.top, v.cx, v.cz = 1, 1, -math.floor(v.mw / 2), -math.floor(v.mh / 2), 0, 0 return end
  local axis = M.axis(s.g)
  local ph = axis and M.phase(s.g)
  local sx, left, cols = M.span(b[1], b[3], v.mw - 8, axis == "x" and M.snap or M.free, axis == "x" and ph or nil)
  local sz, top, rows = M.span(b[2], b[4], v.mh, axis == "z" and M.snap or M.free, axis == "z" and ph or nil)
  v.sx, v.sz = sx, sz
  -- Labels sit mostly east of things, so the scene starts a little left of centre.
  v.left = left - math.max(1, math.floor((v.mw - cols) / 2) - 3) * sx
  v.top = top - (valign == "top" and 0 or math.max(0, math.floor((v.mh - rows) / 2))) * sz
  v.cx, v.cz = v.left + math.floor(v.mw * sx / 2), v.top + math.floor(v.mh * sz / 2)
end
M.frame = function(v, s)
  v.left, v.top = v.cx - math.floor(v.mw * v.sx / 2), v.cz - math.floor(v.mh * v.sz / 2)
  local axis = M.axis(s.g)
  -- A branch lands on the first block row (or column) of its cell.
  if axis == "z" then v.top = v.top - (v.top - M.phase(s.g)) % v.sz
  elseif axis == "x" then v.left = v.left - (v.left - M.phase(s.g)) % v.sx end
end
M.place = function(v, s, valign)
  v.axis = M.axis(s.g)
  if not v.fit then return M.frame(v, s) end
  M.fit(v, s, valign)
  -- A fitted view too heavy for one frame steps out (see M.render).
  if (v.extra or 0) > 0 then
    for _ = 1, v.extra do
      v.sx = M.step(v.sx, v.axis == "x" and M.snap or M.free, 1)
      v.sz = M.step(v.sz, v.axis == "z" and M.snap or M.free, 1)
    end
    M.frame(v, s)
  end
end
M.cellOf = function(v, x, z)
  local cx, cy = math.floor((x - v.left) / v.sx), math.floor((z - v.top) / v.sz)
  if cx < 0 or cy < 0 or cx >= v.mw or cy >= v.mh then return end
  return cx, cy
end

-- Dug planes: one 16x16 column of a section (one level, or every level
-- OR-ed together for ALL), shared by all displays and read within a budget.
M.decode = function(bits, level, set)
  local y1, y2 = 0, 15
  if level ~= "all" then y1, y2 = level % 16, level % 16 end
  for z = 0, 15 do
    for y = y1, y2 do
      local base = 64 * z + 4 * y
      for g = 0, 3 do
        local d = M.hex[bits:byte(base + g + 1)]
        if d and d > 0 then for _, b in ipairs(M.bitsOf[d]) do set[16 * z + 4 * g + b] = true end end
      end
    end
  end
end
M.build = function(key, dim, col, sys, level)
  local set, bits, cells = {}, {}, {}
  for _, sy in ipairs(sys) do
    local found, stamp = M.call("cells", "dugBits", dim, col.sx, sy, col.sz)
    M.budget = M.budget - 1
    bits[sy] = stamp or 0
    if type(found) == "string" then M.decode(found, level, set) end
  end
  for i = 0, 255 do
    if set[i] then cells[#cells+1] = col.sx * 16 + i % 16 cells[#cells+1] = col.sz * 16 + math.floor(i / 16) end
  end
  if not M.planes[key] then
    M.keys[#M.keys+1] = key
    local column = dim .. ":" .. col.sx .. ":" .. col.sz
    M.columns[column] = M.columns[column] or {}
    M.columns[column][key] = true
  end
  local entry = {key=key, dim=dim, sx=col.sx, sz=col.sz, sysKey=table.concat(sys, ","), bits=bits, cells=cells, used=M.ticks}
  M.planes[key], M.serial = entry, M.serial + 1
  return entry
end
-- The view plus the margin, in blocks.
M.rect = function(v)
  return v.left - M.margin, v.top - M.margin, v.left + v.mw * v.sx - 1 + M.margin, v.top + v.mh * v.sz - 1 + M.margin
end
M.planesFor = function(v, s)
  local x1, z1, x2, z2 = M.rect(v)
  local box = table.concat({s.dim, math.floor(x1 / 16), math.floor(z1 / 16), math.floor(x2 / 16), math.floor(z2 / 16), M.version}, ":")
  if v.colsKey ~= box then
    v.cols = M.call("cells", "dugColumns", s.dim, math.floor(x1 / 16), math.floor(z1 / 16),
      math.floor(x2 / 16), math.floor(z2 / 16), 4096) or {}
    v.colsKey = box
  end
  local list, ready, level = {}, true, v.level
  for _, col in ipairs(v.cols) do
    local sys = col.sy
    if level ~= "all" then
      sys = nil
      for _, sy in ipairs(col.sy) do if sy == math.floor(level / 16) then sys = {sy} end end
    end
    if sys then
      local key = table.concat({s.dim, col.sx, col.sz, tostring(level)}, ":")
      local entry, sysKey = M.planes[key], table.concat(sys, ",")
      local fresh = entry and not entry.stale and entry.sysKey == sysKey
      -- A plane larger than the remaining budget waits for a fresh tick.
      if not fresh and (M.budget >= #sys or M.budget == 16) then entry, fresh = M.build(key, s.dim, col, sys, level), true end
      if entry then entry.used = M.ticks list[#list+1] = entry end
      ready = ready and fresh
    end
  end
  return list, ready
end
M.forget = function(index)
  local key = M.keys[index]
  local entry = M.planes[key]
  M.planes[key] = nil
  table.remove(M.keys, index)
  if entry then
    local column = M.columns[entry.dim .. ":" .. entry.sx .. ":" .. entry.sz]
    if column then column[key] = nil end
  end
end
M.check = function(entry)
  if not entry or entry.stale then return true end
  local count = 0
  for _ in pairs(entry.bits) do count = count + 1 end
  if count > M.probes and M.probes < 64 then return false end
  M.probes = M.probes - count
  for sy, old in pairs(entry.bits) do
    local _, stamp = M.call("cells", "dugBits", entry.dim, entry.sx, sy, entry.sz, true)
    if (stamp or 0) ~= old then entry.stale = true return true end
  end
  return true
end
-- New dug marks: check the planes under each turtle first, then sweep the
-- rest, at most 64 section probes per tick. Idle mines cost nothing.
M.revalidate = function()
  M.probes = 64
  if M.newMarks ~= M.marks then
    M.marks, M.swept = M.newMarks, 0
    for _, t in ipairs(M.scene and M.scene.turtles or {}) do
      local d = M.dirs[t.facing or 0]
      for _, p in ipairs({{t.pose.x, t.pose.z}, {t.pose.x + d[1], t.pose.z + d[2]}}) do
        for key in pairs(M.columns[M.scene.dim .. ":" .. math.floor(p[1] / 16) .. ":" .. math.floor(p[2] / 16)] or {}) do
          M.check(M.planes[key])
        end
      end
    end
  end
  while M.swept < #M.keys do
    if M.cursor > #M.keys then M.cursor = 1 end
    local entry = M.planes[M.keys[M.cursor]]
    if not entry or M.ticks - entry.used > 300 then M.forget(M.cursor)
    elseif M.check(entry) then M.cursor, M.swept = M.cursor + 1, M.swept + 1
    else break end
  end
  if #M.keys > 2048 then
    -- Keep the planes drawn in the last few ticks; drop the rest.
    for i = #M.keys, 1, -1 do
      local entry = M.planes[M.keys[i]]
      if not entry or M.ticks - entry.used > 5 then M.forget(i) end
    end
    M.cursor, M.serial = 1, M.serial + 1
  end
end

-- Block keys: x and z packed into one number, so neighbours are key +- 1 and +- M.row.
M.key = function(x, z) return (x + M.off) * M.row + z + M.off end
M.unkey = function(k)
  local kx = math.floor(k / M.row)
  return kx - M.off, k - kx * M.row - M.off
end
M.has = function(bits, bit) return bits % (2 * bit) >= bit end
-- k with lo <= base + step * k <= hi, inside kmin..kmax; step is -1, 0 or 1.
M.clip = function(base, step, lo, hi, kmin, kmax)
  if step == 0 then
    if base < lo or base > hi then return 1, 0 end
    return kmin, kmax
  end
  local a, b = (lo - base) / step, (hi - base) / step
  if a > b then a, b = b, a end
  return math.max(kmin, math.ceil(a)), math.min(kmax, math.floor(b))
end
-- Blocks in the view and its margin: key -> 1 planned, 2 dug, 4 held, 8 the next branch.
M.blocks = function(v, s, planes)
  local x1, z1, x2, z2 = M.rect(v)
  local cls, level, g, a = {}, v.level, s.g, s.area
  local function add(x, z, bit)
    if x >= x1 and x <= x2 and z >= z1 and z <= z2 then
      local k = M.key(x, z)
      local old = cls[k] or 0
      if not M.has(old, bit) then cls[k] = old + bit end
    end
  end
  local farm = M.farmOn(s, level)
  for _, entry in ipairs(planes) do
    local c = entry.cells
    for i = 1, #c, 2 do
      -- Farm travel marks are not tunnels; the farm draws as a farm.
      if not (farm and c[i] >= a.x1 and c[i] <= a.x2 and c[i+1] >= a.z1 and c[i+1] <= a.z2) then add(c[i], c[i+1], 2) end
    end
  end
  -- Cells four or more blocks long along a line get only its first two blocks per cell:
  -- the glyph is the same and the work stays per cell, not per block.
  local function line(bx, bz, ux, uz, n, bit)
      local k1, k2 = M.clip(bx, ux, x1, x2, 1, n)
      local k3, k4 = M.clip(bz, uz, z1, z2, 1, n)
      local size, base, o, u = ux ~= 0 and v.sx or v.sz, ux ~= 0 and bx or bz, ux ~= 0 and v.left or v.top, ux + uz
      local k = math.max(k1, k3)
      while k <= math.min(k2, k4) do
        local offset = (base + u * k - o) % size
        if size < 4 or offset < 2 then add(bx + ux * k, bz + uz * k, bit) k = k + 1
        else k = k + (u > 0 and size - offset or offset - 1) end
      end
  end
  if g and (level == "all" or level == g.bottom) then
    line(g.x, g.z, g.dx, g.dz, g.spine, 1)
    -- Branches that share a cell row (or column) with an earlier branch add nothing new.
    local snap, origin = v.axis == "z" and v.sz or v.sx, v.axis == "z" and v.top or v.left
    local b1, b2 = M.clip(v.axis == "z" and g.z or g.x, (v.axis == "z" and g.dz or g.dx) * g.gap,
      v.axis == "z" and z1 or x1, v.axis == "z" and z2 or x2, 1, g.branches)
    for b = b1, b2 do
      local bx, bz = g.x + g.dx * b * g.gap, g.z + g.dz * b * g.gap
      if ((v.axis == "z" and bz or bx) - origin) % snap == 0 then line(bx, bz, g.rx, g.rz, g.length, 1) end
    end
  end
  local q = s.preview
  if q and (level == "all" or level == q.y) then
    local ux, uz = q.ex > q.x and 1 or q.ex < q.x and -1 or 0, q.ez > q.z and 1 or q.ez < q.z and -1 or 0
    if ux == 0 or uz == 0 then line(q.x, q.z, ux, uz, math.min(4096, math.abs(q.ex - q.x) + math.abs(q.ez - q.z)), 8) end
  end
  for _, c in ipairs(s.reserved) do
    if level == "all" or c.y == level then add(c.x, c.z, 4) end
  end
  return cls
end
-- Blocks off the mine geometry in pieces of six or fewer: ore digs, drawn as one dot.
M.small = function(cls, g)
  local off, seen, dots = {}, {}, {}
  for k in pairs(cls) do
    local x, z = M.unkey(k)
    if not (g and M.onGeo(g, x, z)) then off[k] = true end
  end
  for k in pairs(off) do
    if not seen[k] then
      local comp, stack = {}, {k}
      seen[k] = true
      while #stack > 0 do
        local q = table.remove(stack)
        comp[#comp+1] = q
        for _, d in ipairs({1, -1, M.row, -M.row}) do
          local r = q + d
          if off[r] and not seen[r] then seen[r] = true stack[#stack+1] = r end
        end
      end
      if #comp < 7 then for _, q in ipairs(comp) do dots[q] = true end end
    end
  end
  return dots
end
-- The line glyph of every map cell, keyed cy * mw + cx: {cx, cy, glyph, fg}.
M.cells = function(v, s, planes)
  local cls = M.blocks(v, s, planes)
  local dots, agg = M.small(cls, s.g), {}
  local function line(k) return cls[k] and not dots[k] end
  for k, bits in pairs(cls) do
    local x, z = M.unkey(k)
    local cx, cy = M.cellOf(v, x, z)
    if cx then
      local i = cy * v.mw + cx
      local a = agg[i]
      if not a then a = {cx, cy, true, 0, 0, false, false, false} agg[i] = a end
      if not dots[k] then
        a[3], a[6], a[7], a[8] = false, a[6] or M.has(bits, 2), a[7] or M.has(bits, 4), a[8] or M.has(bits, 8)
        if line(k + M.row) then a[4] = a[4] + 1 end
        if line(k - M.row) then a[4] = a[4] + 1 end
        if line(k + 1) then a[5] = a[5] + 1 end
        if line(k - 1) then a[5] = a[5] + 1 end
      end
    end
  end
  local out = {}
  for i, a in pairs(agg) do
    local h, vv, dug, ch = a[4], a[5], a[6]
    if a[3] then out[i] = {a[1], a[2], U.g.dot, "3"}
    else
      if h > 0 and vv > 0 and h < 2 * vv and vv < 2 * h then ch = dug and "+" or U.g.dot
      elseif vv > h then ch = dug and "|" or U.g.gap
      elseif h > 0 then ch = dug and "-" or U.g.dot
      else ch = U.g.dot end
      out[i] = {a[1], a[2], ch, a[7] and "b" or dug and "3" or a[8] and "1" or "8"}
    end
  end
  return out
end

M.label = function(t, sx)
  if t.tone == "d" or sx >= 3 then return t.id end
  return t.id .. " " .. t.word:match("^%S*")
end
-- Turtles, then drops and the server, then the shaft; the first marker in a cell wins it, except that
-- a broken chest is a beacon and wins over everything (M.draw).
M.markers = function(v, s, dropLabel)
  local out, level = {}, v.level
  local function add(x, z, item)
    item.cx, item.cy = M.cellOf(v, x, z)
    if item.cx then out[#out+1] = item end
  end
  for _, t in ipairs(s.turtles) do
    if M.near(t.pose, level) then
      add(t.pose.x, t.pose.z, {glyph=U.arrow(t.facing), fg=t.tone, label=M.label(t, v.sx), lfg=t.tone, kind="turtle", ref=t})
    end
  end
  for _, d in ipairs(s.drops) do
    if M.near(d, level) then
      add(d.x, d.z, {glyph=d.broken and U.g.cross or U.g.bullet, fg=d.broken and "e" or "0",
        label=dropLabel == "id" and d.id or d.kind, lfg=d.broken and "e" or "8", kind="drop", ref=d})
    end
  end
  if s.server and M.near(s.server, level) then
    add(s.server.x, s.server.z, {glyph="@", fg="9", label="server", lfg="8", kind="server", ref=s.server})
  end
  if s.g then add(s.g.x, s.g.z, {glyph=U.g.shaft, fg="9", label="shaft", lfg="8", kind="shaft", ref=s.g}) end
  return out
end
M.picked = function(m, pick)
  if not pick or pick.k ~= m.kind then return false end
  return (m.kind ~= "turtle" and m.kind ~= "drop") or m.ref.id == tostring(pick.id)
end

-- One dot per text cell, newest first, so a tight wire budget drops the oldest cells.
M.trailCells = function(v, s)
  local cells, out = {}, {}
  for _, trail in pairs(M.trails) do
    for _, p in ipairs(trail.poses) do
      if p.dim == s.dim and M.near(p, v.level) then
        local cx, cy = M.cellOf(v, p.x, p.z)
        if cx then
          local key = cy * v.mw + cx
          if not cells[key] or cells[key].seq < p.seq then cells[key] = {cx=cx, cy=cy, seq=p.seq} end
        end
      end
    end
  end
  for _, cell in pairs(cells) do out[#out+1] = cell end
  table.sort(out, function(a, b) return a.seq > b.seq end)
  return out
end

-- Draws the map with its top-left cell at C (ox, oy). The view carries its cells (M.cells).
-- Returns the marker cells, keyed cy * mw + cx.
M.draw = function(C, v, s, ox, oy, pick, dropLabel, trails, limit)
  local mw, mh = v.mw, v.mh
  local occ, taken, placed = {}, {}, {}
  for i, c in pairs(v.base) do
    C.put(ox + c[1], oy + c[2], c[3], c[4])
    occ[i] = "line"
  end
  -- Trails do not affect label placement. Markers, labels and callouts draw over them.
  for i, cell in ipairs(trails or M.trailCells(v, s)) do
    if limit and i > limit then break end
    C.put(ox + cell.cx, oy + cell.cy, U.g.dot, "8")
  end
  local farmLabel
  if M.farmOn(s, v.level) then
    local a = s.area
    local x1, y1 = math.floor((a.x1 - v.left) / v.sx), math.floor((a.z1 - v.top) / v.sz)
    local x2, y2 = math.floor((a.x2 - v.left) / v.sx), math.floor((a.z2 - v.top) / v.sz)
    for y = math.max(y1, 0), math.min(y2, mh - 1) do
      for x = math.max(x1, 0), math.min(x2, mw - 1) do
        local ex, ey = x == x1 or x == x2, y == y1 or y == y2
        if ex or ey then
          C.put(ox + x, oy + y, ex and ey and "+" or ey and "-" or "|", "c")
          occ[y * mw + x] = "farm"
        else occ[y * mw + x] = "farmin" end
      end
    end
    local ready = 0
    for _, spot in ipairs(s.spots) do
      if spot.ready then ready = ready + 1 end
      local cx, cy = M.cellOf(v, spot.x, spot.z)
      if cx then
        C.put(ox + cx, oy + cy, spot.ready and U.g.spade or U.g.club, spot.ready and "d" or "8")
        occ[cy * mw + cx] = "tree"
      end
    end
    if M.cellOf(v, a.x1, a.z1) then farmLabel = {"farm " .. ready .. "/" .. #s.spots, x1 - 1, y1} end
  end
  local marks = M.markers(v, s, dropLabel)
  local order = {}
  for _, m in ipairs(marks) do if m.kind == "drop" and m.ref.broken then order[#order+1] = m end end
  for _, m in ipairs(marks) do if not (m.kind == "drop" and m.ref.broken) then order[#order+1] = m end end
  for _, m in ipairs(order) do
    local i = m.cy * mw + m.cx
    if not taken[i] then
      if M.picked(m, pick) then C.put(ox + m.cx, oy + m.cy, m.glyph, "f", m.fg)
      else C.put(ox + m.cx, oy + m.cy, m.glyph, m.fg) end
      taken[i] = m
    end
  end
  -- Greedy labels: the cheapest free candidate, in preference order; a label never touches
  -- another marker or label, and covering a line or tree costs more than empty ground.
  local function place(text, x, y, fg, prefer)
    local n = #text
    local cands = {r={x + 1, y}, l={x - n, y}, ur={x + 1, y - 1}, dr={x + 1, y + 1}, ul={x - n, y - 1},
      dl={x - n, y + 1}, u={x - math.floor(n / 2), y - 1}, d={x - math.floor(n / 2), y + 1}}
    local best
    for i, k in ipairs(prefer) do
      local cx, cy = cands[k][1], cands[k][2]
      if cx >= 0 and cx + n <= mw and cy >= 0 and cy < mh then
        local cost, bad = i - 1, false
        for j = -1, n do
          local qx, q = cx + j, cy * mw + cx + j
          local inside = qx >= 0 and qx < mw
          if j >= 0 and j < n then
            if taken[q] or placed[q] then bad = true break end
            if occ[q] then cost = cost + ((occ[q] == "line" or occ[q] == "tree") and 30 or 10) end
          elseif inside and (placed[q] or taken[q] and not (qx == x and cy == y)) then bad = true break end
        end
        if not bad and (not best or cost < best[1]) then best = {cost, cx, cy} end
      end
    end
    if not best then return end
    C.put(ox + best[2], oy + best[3], text, fg)
    for j = 0, n - 1 do placed[best[3] * mw + best[2] + j] = true end
  end
  for _, m in ipairs(marks) do
    if taken[m.cy * mw + m.cx] == m and not M.picked(m, pick) then
      local pref, skip = M.prefer, false
      if m.kind == "turtle" and m.ref.facing == 1 then pref = M.east -- not on the path ahead
      elseif m.kind == "turtle" and (m.ref.facing == 0 or m.ref.facing == 2) then pref = M.along
      elseif m.kind == "drop" then skip, pref = v.sx >= 3 and not m.ref.broken, M.drop
      elseif m.kind == "shaft" then skip = v.sx >= 3 end
      if not skip then place(m.label, m.cx, m.cy, m.lfg, pref) end
    end
  end
  if farmLabel and v.sx < 3 then place(farmLabel[1], farmLabel[2], farmLabel[3], "8", M.farm) end
  M.numbers(C, v, s, ox, oy, occ, taken, placed)
  return taken
end
-- Branch numbers on the side of the spine away from the branches, or on the screen edge.
M.numbers = function(C, v, s, ox, oy, occ, taken, placed)
  local g, axis, mw, mh = s.g, v.axis, v.mw, v.mh
  if not axis or not (v.level == "all" or v.level == g.bottom) then return end
  if (axis == "z" and v.sz or v.sx) > 2 then return end
  local function used(x, y) local q = y * mw + x return taken[q] or placed[q] end
  local function free(x, y) return x < 0 or x >= mw or not (occ[y * mw + x] or used(x, y)) end
  local sc, sr = math.floor((g.x - v.left) / v.sx), math.floor((g.z - v.top) / v.sz)
  for b = 1, g.branches do
    local text = tostring(b)
    local n = #text
    if axis == "z" then
      local r = math.floor((g.z + g.dz * b * g.gap - v.top) / v.sz)
      if r >= 0 and r < mh then
        local step = g.rx > 0 and -1 or 1
        if sc < 0 and step < 0 or sc >= mw and step > 0 then
          local x, ok = step < 0 and 0 or mw - n, true
          for j = 0, n - 1 do if used(x + j, r) then ok = false end end
          if ok then C.put(ox + x, oy + r, text, "8") end
        else
          local x = step < 0 and sc - n - 1 or sc + 2
          for _ = 1, 4 do -- step past a label sitting against the spine
            if x < 0 or x + n > mw then break end
            local lo, hi, ok = step < 0 and -3 or -1, step < 0 and n or n + 2, true
            for j = lo, hi do if not free(x + j, r) then ok = false break end end
            if ok then C.put(ox + x, oy + r, text, "8") break end
            local gx = step < 0 and x + n or x - 1
            if gx < 0 or gx >= mw or not used(gx, r) then break end
            x = x + 2 * step
          end
        end
      end
    else
      local c = math.floor((g.x + g.dx * b * g.gap - v.left) / v.sx)
      if c >= 0 and c <= mw - n then
        local r = g.rz > 0 and sr - 1 or sr + 1
        if r < 0 or r >= mh then r = g.rz > 0 and 0 or mh - 1 end
        local ok = true
        for j = -1, n do if not free(c + j, r) then ok = false break end end
        if ok then
          C.put(ox + c, oy + r, text, "8")
          for j = 0, n - 1 do placed[r * mw + c + j] = true end
        end
      end
    end
  end
end

M.holder = function(v, s, x1, z1, x2, z2, y1, y2)
  local key = table.concat({s.terrain, x1, z1, x2, z2, tostring(y1), tostring(y2)}, ":")
  if v.heldKey ~= key then
    local held
    if x1 == x2 and z1 == z2 and y1 and y1 == y2 then
      local who = M.call("cells", "owner", x1, y1, z1, s.dim)
      if who then held = {who=who, x=x1, y=y1, z=z1} end
    else held = M.call("cells", "holder", s.dim, x1, z1, x2, z2, y1, y2) end
    v.held, v.heldKey = held, key
  end
  return v.held
end
M.holderText = function(who)
  local role, id = tostring(who):match("^(.-):(%d+)$")
  return id and "#" .. id .. " " .. role or tostring(who)
end
M.silence = function(s, who)
  local id = tonumber(tostring(who):match("(%d+)$"))
  if not id then return end
  local status = M.call("lease", "peek", id) or {}
  local machines = M.call("state", "get", "machines") or {}
  local machine = machines[tostring(id)] or machines[id] or {}
  local seen = math.max(status.seen or 0, machine.seen or 0)
  if seen > 0 and (status.lost or s.now - seen >= 60000) then
    return "silent " .. math.floor(math.max(0, s.now-seen)/60000) .. " min"
  end
end
-- A picked item returns {colour, x, z, rows} for its callout.
M.callout = function(v, s, pick)
  if pick.k == "turtle" then
    for _, t in ipairs(s.turtles) do
      if t.id == tostring(pick.id) then
        local p, when = t.pose, U.age(t.ago, true)
        local fuel, lease = t.fuel and tostring(t.fuel) or "-", t.lease
        local rows = {
          {"text", {{0, "#" .. t.id, "0"}, {#t.id + 2, t.word, U.st.fg(t.tone)}, {-#when, when, "8"}}},
          {"text", {{0, p.x .. "," .. p.y .. "," .. p.z, "8"}}},
          {"leader", "fuel", fuel, type(t.fuel) == "number" and t.fuel < 500 and "1" or "0"},
          {"leader", "ore", tostring(t.ore or "-"), "0"},
          {"leader", "lease", lease, lease == "expired" and "e" or lease == "open" and "0" or "8"},
          {"chip", "DETAILS", "turtle:" .. t.id}}
        if t.range then table.insert(rows, #rows, {"text", {{0, "range " .. t.range, "0"}}}) end
        if t.last then
          local result = t.last.status == "expired" and "expired" or t.last.ok and "ok" or "failed"
          table.insert(rows, #rows, {"text", {{0, "last " .. result .. " " .. U.age(math.max(0, s.now-t.last.at)), "8"}}})
        end
        return {t.tone, p.x, p.z, rows}
      end
    end
  elseif pick.k == "drop" then
    for _, d in ipairs(s.drops) do
      if d.id == tostring(pick.id) then
        return {d.broken and "e" or "3", d.x, d.z, {
          {"text", {{0, d.id == "saplings" and "saplings" or "drop " .. d.id .. " " .. d.kind, "0"}}},
          {"text", {{0, d.x .. "," .. d.y .. "," .. d.z, "8"}}},
          {"leader", "state", d.broken and "broken" or "ok", d.broken and "e" or "0"}}}
      end
    end
  elseif pick.k == "server" then
    local p = s.server
    if p then return {"9", p.x, p.z, {{"text", {{0, "server", "0"}}}, {"text", {{0, p.x .. "," .. p.y .. "," .. p.z, "8"}}}}} end
  elseif pick.k == "shaft" then
    local g = s.g
    if g then
      local held = M.holder(v, s, g.x, g.z, g.x, g.z, math.min(g.top,g.bottom), math.max(g.top,g.bottom))
      local holder = held and M.holderText(held.who) or "-"
      local rows = {{"text", {{0, "shaft", "0"}}}, {"text", {{0, g.x .. "," .. g.z, "8"}}},
        {"leader", "lane", holder, held and "b" or "8"}}
      local silent = held and M.silence(s, held.who)
      if silent then rows[#rows+1] = {"text", {{0, silent, "8"}}} end
      return {"9", g.x, g.z, rows}
    end
  elseif pick.k == "cell" and tonumber(pick.x) and tonumber(pick.z) then
    local cx, cy = M.cellOf(v, pick.x, pick.z)
    if not cx then return end
    local bits, who = 0, nil
    for k, b in pairs(v.cls or {}) do
      local x, z = M.unkey(k)
      local bx, by = M.cellOf(v, x, z)
      if bx == cx and by == cy then
        for _, bit in ipairs({1, 2, 4}) do if M.has(b, bit) and not M.has(bits, bit) then bits = bits + bit end end
      end
    end
    local x, z = v.left + cx*v.sx, v.top + cy*v.sz
    local y = v.level ~= "all" and v.level or nil
    local held = M.holder(v, s, x, z, x+v.sx-1, z+v.sz-1, y, y)
    local word = held and "held" or M.has(bits, 2) and "dug" or M.has(bits, 1) and "planned" or ""
    if held then who = M.holderText(held.who) end
    local rows = {{"text", {{0, v.level == "all" and pick.x .. "," .. pick.z or pick.x .. "," .. v.level .. "," .. pick.z, "0"}}}}
    if word ~= "" then
      local parts = {{0, word, word == "held" and "b" or "0"}}
      if who then parts[2] = {#word + 1, who, "0"} end
      rows[2] = {"text", parts}
    end
    local silent = held and M.silence(s, held.who)
    if silent then rows[#rows+1] = {"text", {{0, silent, "8"}}} end
    return {"3", pick.x, pick.z, rows}
  end
end
-- A hairline box beside the picked marker, joined to it. Returns the box in map cells and its chip
-- {x, y, w} on the canvas, if any.
M.box = function(C, v, s, ox, oy, pick, taken, got)
  got = got or M.callout(v, s, pick)
  if not got then return end
  local tx, ty = M.cellOf(v, got[2], got[3])
  if not tx then return end
  local colour, rows = got[1], got[4]
  if pick.k == "cell" then
    local cell = C.cells[oy + ty] and C.cells[oy + ty][ox + tx]
    if cell then cell[2], cell[3] = "f", "3" end
  end
  local widest = 0
  for _, row in ipairs(rows) do
    if row[1] == "leader" then widest = math.max(widest, #row[2] + #row[3] + 4)
    elseif row[1] == "chip" then widest = math.max(widest, #row[2] + 2)
    else
      local left, right = 0, 0
      for _, part in ipairs(row[2]) do
        if part[1] >= 0 then left = math.max(left, part[1] + #part[2]) else right = right + #part[2] + 1 end
      end
      widest = math.max(widest, left + right)
    end
  end
  local bw, bh = math.min(v.mw, math.max(14, widest + 4)), #rows + 2
  local near, far = tx - bw + 1, tx
  if tx * 2 < v.mw then near, far = tx, tx - bw + 1 end
  -- Below, then above, each toward the middle first; the one hiding the fewest markers wins.
  local best
  for _, o in ipairs({{ty + 2 + bh <= v.mh, ty + 2, ty + 1, ty + 2}, {ty - 1 - bh >= 0, ty - 1 - bh, ty - 1, ty - 2}}) do
    if o[1] then
      for _, x0 in ipairs({near, far}) do
        local bx, hidden = math.max(0, math.min(x0, v.mw - bw)), 0
        for _, m in pairs(taken or {}) do
          if m.cx >= bx and m.cx < bx + bw and m.cy >= o[2] and m.cy < o[2] + bh then hidden = hidden + 1 end
        end
        if not best or hidden < best[1] then best = {hidden, bx, o[2], o[3], o[4]} end
      end
    end
  end
  local bx, by, link, joint
  if best then bx, by, link, joint = best[2], best[3], best[4], best[5]
  else bx, by = math.max(0, math.min(near, v.mw - bw)), math.max(0, math.min(ty + 2, v.mh - bh)) end
  C.fill(ox + bx, oy + by, bw, bh, "f")
  C.box(ox + bx, oy + by, bw, bh, colour)
  if link then C.put(ox + tx, oy + link, "|", colour) C.put(ox + tx, oy + joint, "+", colour) end
  local iw, chip = bw - 4, nil
  for i, row in ipairs(rows) do
    local y = oy + by + i
    if row[1] == "leader" then C.leader(ox + bx + 2, y, iw, row[2], row[3], row[4])
    elseif row[1] == "chip" then
      chip = {ox + bx + 2, y, #row[2] + 2}
      C.chip(chip[1], y, row[2], row[3])
    else
      for _, part in ipairs(row[2]) do
        local at = part[1] >= 0 and part[1] or iw + part[1]
        C.put(ox + bx + 2 + at, y, part[2]:sub(1, math.max(0, iw - at)), part[3])
      end
    end
  end
  return {bx, by, bw, bh, chip}
end
-- Where the pick is now: a turtle's pick follows the turtle.
M.focus = function(v, s)
  local p = v.pick
  if not p then return end
  if p.k == "cell" then return {x=p.x, z=p.z} end
  local got = s and M.callout(v, s, p)
  if got then return {x=got[2], z=got[3]} end
end

M.levelText = function(level) return level == "all" and "ALL" or "Y" .. level end
M.controls = function(C, L, w, h, v, s)
  local kind = L.kind
  local arrows = {{U.g.left, "map-w"}, {U.g.up, "map-n"}, {U.g.down, "map-s"}, {U.g.right, "map-e"}}
  local edge
  if kind ~= "tiny" then
    local x = C.chip(6, 1, "FIT", "map-fit", v.fit and "on" or "plain") + 1
    if kind ~= "pocket" then
      x = C.chip(x, 1, "-", "map-out") + 1
      x = C.chip(x, 1, "+", "map-in") + 2
      for _, a in ipairs(arrows) do x = C.chip(x, 1, a[1], a[2]) + 1 end
    else
      local x0 = 1 + math.floor((w - 24) / 2)
      for i, a in ipairs(arrows) do C.chip(x0 + 4 * (i - 1), h, a[1], a[2]) end
      C.chip(x0 + 17, h, "-", "map-out")
      C.chip(x0 + 21, h, "+", "map-in")
    end
    edge = x
  else
    local x0 = 1 + math.floor((w - 15) / 2)
    for i, a in ipairs(arrows) do C.chip(x0 + 4 * (i - 1), h - 1, a[1], a[2]) end
    x0 = 1 + math.floor((w - 13) / 2)
    C.chip(x0, h, "-", "map-out")
    C.chip(x0 + 4, h, "FIT", "map-fit", v.fit and "on" or "plain")
    C.chip(x0 + 10, h, "+", "map-in")
  end
  local x, text = w - 14, M.levelText(v.level)
  C.chip(x, 1, U.g.down, "map-down")
  C.put(x + 3 + math.floor((5 - #text) / 2), 1, text, "0")
  C.hit("map-level", x + 3, 1, 5, 1, text)
  C.chip(x + 8, 1, U.g.up, "map-up")
  -- The dimension chip, then the broken chest count, in the free run before the level chips;
  -- with no room there they take the title's place, the dimension first.
  local title = kind ~= "tiny"
  local function chip(label, id, tone)
    if edge and edge + #label + 1 <= w - 16 then edge = C.chip(edge, 1, label, id, tone) + 1
    elseif title then C.chip(1, 1, label, id, tone, 5) title = false end
  end
  if M.config and M.config.remoteDimensions == true then chip(M.dimLabel[s.dim] or "OVER", "map-dim") end
  if s.broken > 0 then chip(U.g.cross .. math.min(s.broken, 99), "map-broken", "stop") end
  if title then C.put(2, 1, "MAP", "0") end
  -- North is up on every map, so the compass never turns; it sits outside the map area.
  C.put(w - 2, 1, M.compass, "8")
end
M.roster = function(C, L, w, s)
  local R, ts = L.roster, s.turtles
  C.section(2, R.y, w - 2, "TURTLES", #ts)
  local room = R.cols * R.lines
  local shown = #ts <= room and #ts or room - 1
  for i = 0, math.min(#ts, room) - 1 do
    local x, y = 2 + (i % R.cols) * 33, R.y + 1 + math.floor(i / R.cols) * 2
    if i >= shown then C.put(x, y, "+" .. (#ts - shown) .. " more", "8") break end
    local t = ts[i + 1]
    C.put(x, y, U.arrow(t.facing), t.tone)
    C.put(x + 2, y, t.id, "0")
    C.put(x + 5, y, t.word:sub(1, 10), U.st.fg(t.tone))
    C.put(x + 16, y, t.pose.x .. "," .. t.pose.y .. "," .. t.pose.z, "8")
  end
end

-- The tap area over the map, cut around a callout chip: display clients take the last button
-- under a tap and the local monitor the first, so the two never overlap.
M.pickArea = function(C, L, chip)
  local x2, y2 = L.mx + L.mw, L.my + L.mh
  local parts = {{L.mx, L.my, L.mw, L.mh}}
  if chip then
    parts = {{L.mx, L.my, L.mw, chip[2] - L.my}, {L.mx, chip[2], chip[1] - L.mx, 1},
      {chip[1] + chip[3], chip[2], x2 - chip[1] - chip[3], 1}, {L.mx, chip[2] + 1, L.mw, y2 - chip[2] - 1}}
  end
  for _, r in ipairs(parts) do if r[3] > 0 and r[4] > 0 then C.hit("map-pick", r[1], r[2], r[3], r[4]) end end
end
-- Places the view, loads its planes and rebuilds its cells when the view or the data changed.
M.prepare = function(v, s, valign)
  M.place(v, s, valign)
  local planes
  planes, v.ready = M.planesFor(v, s)
  local key = table.concat({v.mw, v.mh, v.sx, v.sz, v.left, v.top, tostring(v.level), s.terrain, M.serial, #planes}, ":")
  if v.bkey ~= key then
    v.base, v.bkey = M.cells(v, s, planes), key
    v.cls = nil
  end
  if v.pick and v.pick.k == "cell" and not v.cls then v.cls = M.blocks(v, s, planes) end
  return key
end
-- The frame as the display sends it: a blank joins the previous run whatever its fg (D.compact).
M.pack = function(C)
  local frame = C.frame()
  for y, row in ipairs(frame.rows) do
    local runs = {}
    for x = 1, C.w do
      local cell, last = C.cells[y][x], runs[#runs]
      if last and last[3] == cell[3] and (last[2] == cell[2] or cell[1] == " ") then last[1] = last[1] + 1
      else runs[#runs+1] = {1, cell[2], cell[3]} end
    end
    row.runs = runs
  end
  return frame
end
M.render = function(w, h, session, tries)
  session = type(session)=="table" and session or {}
  M.seen = SO.now()
  if not M.scene then M.scene = M.gather(M.seen) end
  local v = M.view(session)
  local s = M.selected(v)
  local L = M.layout(w, h, #s.turtles)
  v.mw, v.mh, v.L, v.h = L.mw, L.mh, L, h
  local key = M.prepare(v, s)
  local p = v.pick or {}
  local got = v.pick and M.callout(v, s, v.pick)
  local detail = {}
  for _, row in ipairs(got and got[4] or {}) do
    if row[1] == "text" then
      for _, part in ipairs(row[2]) do detail[#detail+1] = part[2] end
    else detail[#detail+1] = row[2] .. ":" .. row[3] end
  end
  local fkey = table.concat({key, w, h, s.markers, M.trailVersion, table.concat(detail, ";"), tostring(M.config and M.config.remoteDimensions), tostring(v.fit), tostring(p.k), tostring(p.id), tostring(p.x), tostring(p.z)}, ":")
  if v.frame and v.fkey == fkey then return v.frame end
  local trails = M.trailCells(v, s)
  local function paint(limit)
    local C = U.canvas(w, h)
    v.taken = M.draw(C, v, s, L.mx, L.my, v.pick, nil, trails, limit)
    v.box = v.pick and M.box(C, v, s, L.mx, L.my, v.pick, v.taken, got)
    M.controls(C, L, w, h, v, s)
    if L.roster then M.roster(C, L, w, s) end
    M.pickArea(C, L, v.box and v.box[5])
    return M.pack(C)
  end
  local frame = paint(0)
  local bytes = SO.proto and #SO.proto.ser(frame) or 0
  -- Wait for complete planes before choosing a zoom for the 16 KB message limit.
  if v.ready and (tries or 0) < 4 and bytes > M.heavy then
    if v.fit then v.extra = math.min((v.extra or 0) + 1, #M.free) else M.zoom(v, 1) end
    return M.render(w, h, session, (tries or 0) + 1)
  end
  -- Trails never choose or latch zoom. Keep a newest prefix that fits over the base frame.
  if #trails > 0 and bytes <= M.heavy then
    local limit = #trails
    while limit > 0 do
      local candidate = paint(limit)
      if not SO.proto or #SO.proto.ser(candidate) <= M.heavy then frame = candidate break end
      limit = math.floor(limit / 2)
    end
    if limit == 0 then frame = paint(0) end
  end
  v.frame, v.fkey = frame, fkey
  return v.frame
end
-- An off-screen view for the status wall and the alert crop, kept per size.
M.auxView = function(key, v)
  local old = M.aux[key]
  if old and old.sig == v.sig then return old end
  M.aux[key] = v
  return v
end
M.ensure = function()
  M.seen = SO.now()
  if not M.scene then M.scene = M.gather(M.seen) end
  return M.scene
end
-- The status wall thumbnail: the compass on its first row, the whole scene north up under it.
M.thumb = function(C, x, y, w, h)
  local s = M.ensure()
  if w < 3 or h < 2 then return false end
  C.put(x + w - 2, y, M.compass, "8")
  local v = M.auxView("thumb:" .. w .. "x" .. h, {sig="", fit=true, level="all", mw=w, mh=h - 1})
  M.prepare(v, s, "top")
  M.draw(C, v, s, x, y + 1)
  return true
end
-- The alert crop: one block per cell around focus {x, y, z, id?, drop?}, at the mine level when
-- focus is at or under it, with the subject inverted and no callout.
M.crop = function(C, x, y, w, h, focus)
  local s = M.ensure()
  if type(focus) ~= "table" or not tonumber(focus.x) or not tonumber(focus.z) or w < 1 or h < 1 then return false end
  local g, fx, fy, fz = s.g, tonumber(focus.x), tonumber(focus.y), tonumber(focus.z)
  local level = g and fy and fy <= g.bottom and g.bottom or "all"
  local pick = focus.id ~= nil and {k="turtle", id=tostring(focus.id)} or focus.drop ~= nil and {k="drop", id=tostring(focus.drop)} or nil
  -- Centred on the subject, but shifted so the scene fills the crop rather than empty ground.
  local b, cx = M.bounds(s, level), fx
  if b then cx = math.max(math.min(fx - math.floor(w / 2), b[3] + 2 - w), b[1] - 1) + math.floor(w / 2) end
  local sig = table.concat({cx, fz, tostring(level)}, ":")
  local v = M.auxView("crop:" .. w .. "x" .. h, {sig=sig, fit=false, level=level, sx=1, sz=1, cx=cx, cz=fz, mw=w, mh=h})
  M.prepare(v, s)
  M.draw(C, v, s, x, y, pick)
  return true
end

-- Next scale up or down the ladder, from the nearest rung.
M.step = function(scale, ladder, step)
  local i = #ladder
  for k, value in ipairs(ladder) do if value >= scale then i = k break end end
  return ladder[math.max(1, math.min(#ladder, i + step))]
end
M.zoom = function(v, step)
  if not (v.sx and v.sz) then return end
  local nx = M.step(v.sx, v.axis == "x" and M.snap or M.free, step)
  local nz = M.step(v.sz, v.axis == "z" and M.snap or M.free, step)
  local f = M.focus(v, M.selected(v))
  if f and (nx ~= v.sx or nz ~= v.sz) and M.cellOf(v, f.x, f.z) then
    -- Keep the picked block where it is on screen.
    v.cx = f.x - math.floor((f.x - v.cx) * nx / v.sx + 0.5)
    v.cz = f.z - math.floor((f.z - v.cz) * nz / v.sz + 0.5)
  end
  v.sx, v.sz, v.fit = nx, nz, false
end
M.tap = function(v, cx, cy)
  local b = v.box
  if b and cx >= b[1] and cx < b[1] + b[3] and cy >= b[2] and cy < b[2] + b[4] then v.pick = nil return end
  local m = v.taken and v.taken[cy * v.mw + cx]
  local pick = m and {k=m.kind, id=(m.kind == "turtle" or m.kind == "drop") and m.ref.id or nil}
    or {k="cell", x=v.left + cx * v.sx, z=v.top + cy * v.sz}
  local old = v.pick
  if old and old.k == pick.k and (pick.k ~= "cell" and old.id == pick.id
      or pick.k == "cell" and select(1, M.cellOf(v, old.x, old.z)) == cx and select(2, M.cellOf(v, old.x, old.z)) == cy) then
    v.pick = nil
  else v.pick = pick end
end
-- Centres one block per cell on a broken chest and picks it: the drop id, else the broken chest
-- after the picked one, else the first.
M.focusBroken = function(v, s, id)
  local list, at = {}, 1
  for _, d in ipairs(s.drops or {}) do
    if d.broken and (not id or d.id == id) then list[#list+1] = d end
  end
  if #list == 0 then return end
  table.sort(list, function(a, b) return a.id < b.id end)
  for i, d in ipairs(list) do
    if v.pick and v.pick.k == "drop" and v.pick.id == d.id then at = i % #list + 1 end
  end
  local d = list[at]
  v.fit, v.sx, v.sz, v.cx, v.cz, v.level, v.pick = false, 1, 1, d.x, d.z, "all", {k="drop", id=d.id}
end
M.input = function(event)
  if not event.session then return end
  local v, id = M.view(event.session), event.id
  local s = M.selected(v) or {}
  local g, surface = s.g, M.surface(s)
  local drop = type(id) == "string" and id:match("^map%-drop:(.+)$")
  v.extra = nil
  if id == "map-broken" or id == "map-focus" or drop then M.focusBroken(v, s, drop)
  elseif id == "map-dim" and M.config and M.config.remoteDimensions == true then
    v.dim = M.nextDim[v.dim or s.dim] or "minecraft:overworld"
    v.fit, v.pick, v.colsKey = true, nil, nil
  elseif id == "map-fit" then v.fit = true
  elseif id == "map-in" or id == "map-out" then M.zoom(v, id == "map-in" and -1 or 1)
  elseif M.pan[id] then
    local d = M.pan[id]
    v.fit = false
    v.cx = v.cx + d[1] * math.max(1, math.floor((v.mw or 3) * (v.sx or 1) / 3))
    v.cz = v.cz + d[2] * math.max(1, math.floor((v.mh or 3) * (v.sz or 1) / 3))
  elseif id == "map-up" or id == "map-down" then
    local rule = M.heights[s.dim] or M.heights["minecraft:overworld"]
    v.level = math.max(rule[1], math.min(rule[2],
      (v.level == "all" and (g and g.bottom or surface) or v.level) + (id == "map-up" and 1 or -1)))
  elseif id == "map-level" then
    local mine = g and g.bottom
    if v.level == "all" then v.level = mine or surface
    elseif v.level == mine and mine ~= surface then v.level = surface
    else v.level = "all" end
  elseif id == "map-pick" and v.L and event.x and event.y then
    local L = v.L
    local cx = event.x - L.mx
    local cy = event.y - math.max(0, (event.session.h or v.h) - v.h) - L.my
    if cx >= 0 and cy >= 0 and cx < L.mw and cy < L.mh then M.tap(v, cx, cy) end
  end
end
return {name="map",handlers={},render=M.render,input=M.input,thumb=M.thumb,crop=M.crop,tick=function(now)
  M.ticks, M.budget = M.ticks + 1, 16
  if not M.wired and SO.mods.display then SO.mods.display.screen("map",M.render,M.input) M.wired=true end
  if M.seen and now - M.seen < 10000 then
    M.scene = M.gather(now)
    if M.config.remoteDimensions == true then
      for _, dim in pairs(M.dimensions) do if dim ~= M.scene.dim then M.gather(now, dim) end end
    end
    M.readTrail()
    M.revalidate()
  end
end}
