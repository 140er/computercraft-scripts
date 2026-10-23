local U = dofile("so-ui.lua")
-- Top-down map. Terrain is drawn in sextant pixels (2x3 per character, one
-- block per pixel at zoom 0); markers take whole characters on top.
local M = { planes = {}, keys = {}, columns = {}, layouts = {}, serial = 0, budget = 16, cursor = 1, ticks = 0,
  version = 0, marks = 0, swept = 0,
  dirs = {[0]={0,-1},{1,0},{0,1},{-1,0}},
  dimensions = {[0]="minecraft:overworld",[-1]="minecraft:the_nether",[1]="minecraft:the_end"},
  -- Terrain classes, lowest priority first. A character takes the colour of
  -- its highest class; every lit pixel uses that colour on the black ground.
  colour = {"0","0","d","1","d","b","1"},
  names = {"PLANNED","DUG","FARM","SAPLING","TREE","LANE","HELD"},
  letters = {ore="O",fuel="F",junk="J",wood="W",storage="C",any="A",saplings="S"},
  arrows = {[0]="^",">","v","<",north="^",east=">",south="v",west="<"},
  labels = {["map-fit"]="FIT",["map-in"]="+",["map-out"]="-",["map-n"]="^",["map-s"]="v",
    ["map-w"]="<",["map-e"]=">",["map-up"]="UP",["map-down"]="DN"},
  pan = {["map-n"]={0,-1},["map-e"]={1,0},["map-s"]={0,1},["map-w"]={-1,0}},
  hex = {}, bitsOf = {} }
for i = 0, 15 do
  M.hex[("0123456789abcdef"):byte(i + 1)] = i
  M.bitsOf[i] = {}
  for b = 0, 3 do if math.floor(i / 2 ^ b) % 2 == 1 then M.bitsOf[i][#M.bitsOf[i] + 1] = b end end
end

do
  local probe = U.canvas(15,3)
  probe.header("MAP", "")
  for y,row in ipairs(probe.frame().rows) do
    if row.text:find("MAP",1,true) then M.headerRow=y break end
  end
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

M.gather = function(now)
  if not M.config or now >= (M.configAt or 0)+5000 then
    M.config, M.configAt = SO.store.read("so-server.cfg") or {}, now
  end
  local config = M.config
  local mine = M.call("mine", "mapView") or {}
  local lumber = M.call("lumber", "mapView") or {}
  local dim = M.dim(config.pos and config.pos.dim or mine.dim or lumber.dim)
  local s = {dim=dim, g=M.geometry(mine, dim), turtles={}, drops={}, spots={}}
  if config.pos and M.dim(config.pos.dim) == dim then s.server = config.pos end
  if lumber.area and M.dim(lumber.dim) == dim then s.area, s.ground, s.spots = lumber.area, lumber.ground or 64, lumber.spots or {} end
  local workers = {}
  for id, row in pairs(M.call("state", "get", "machines") or {}) do
    if row.role == nil or row.role == "worker" or row.role == "turtle" then workers[tostring(id)] = row end
  end
  for id, row in pairs(mine.turtles or {}) do
    local previous = workers[tostring(id)]
    row.seen = previous and previous.seen
    workers[tostring(id)] = row
  end
  if lumber.turtle then
    local previous = workers[tostring(lumber.turtle.id)]
    lumber.turtle.seen = previous and previous.seen
    workers[tostring(lumber.turtle.id)] = lumber.turtle
  end
  for id, row in pairs(workers) do
    local p = row.pose
    if p and M.dim(p.dim or row.dim or mine.dim) == dim then
      local status = M.call("lease", "status", tonumber(id) or id) or {}
      local range = M.call("lease", "inRange", tonumber(id) or id, p)
      local state, color = tostring(row.state or "idle"), "1"
      if status.lost or status.uncertain or range == false or state == "lost" or state == "range" or state == "out of range"
          or row.seen and now-row.seen >= 120000 then color = "e"
      elseif state == "done" then color = "b"
      elseif state == "mining" or state == "working" or state == "lumber" or status.open and state ~= "stopped" and state ~= "idle" then color = "d" end
      s.turtles[#s.turtles+1] = {id=id, pose=p, color=color, label=status.lost and "LOST" or state:upper()}
    end
  end
  table.sort(s.turtles, function(a, b)
    local x, y = tonumber(a.id), tonumber(b.id)
    if x and y and x ~= y then return x < y end
    if (x == nil) ~= (y == nil) then return x ~= nil end
    return tostring(a.id) < tostring(b.id)
  end)
  for _, p in ipairs(M.call("drops", "list") or {}) do
    if M.dim(p.dim) == dim then s.drops[#s.drops+1] = p end
  end
  if lumber.saplings and M.dim(lumber.dim) == dim then
    local p = SO.store.copy(lumber.saplings) p.kind = "saplings" s.drops[#s.drops+1] = p
  end
  local reserved, version = M.call("cells", "reserved", dim, 4096)
  s.reserved = reserved or {}
  local terrain, markers = {dim, tostring(version)}, {}
  for _, key in ipairs({"x","z","top","bottom","dx","dz","branches","length","gap"}) do terrain[#terrain+1] = s.g and s.g[key] or "" end
  if s.area then
    for _, key in ipairs({"x1","z1","x2","z2"}) do terrain[#terrain+1] = s.area[key] end
    terrain[#terrain+1] = s.ground
    for _, spot in ipairs(s.spots) do terrain[#terrain+1] = spot.x .. "," .. spot.z .. (spot.ready and "r" or "") end
  end
  for _, t in ipairs(s.turtles) do
    markers[#markers+1] = table.concat({t.id, t.pose.x, t.pose.y, t.pose.z, tostring(t.pose.facing), t.color, t.label}, ",")
  end
  for _, p in ipairs(s.drops) do markers[#markers+1] = table.concat({p.kind or "", p.x, p.y, p.z, tostring(p.broken)}, ",") end
  if s.server then markers[#markers+1] = s.server.x .. "," .. s.server.y .. "," .. s.server.z end
  s.terrain, s.markers = table.concat(terrain, ";"), table.concat(markers, ";")
  M.version, M.newMarks = M.call("cells", "dugVersion")
  M.version = M.version or 0
  M.scene = s
end

M.view = function(session)
  local v = session.map or {fit=true}
  session.map = v
  if type(v.level) ~= "number" then v.level = "all" end
  v.zoom, v.cx, v.cz = tonumber(v.zoom) or 0, tonumber(v.cx) or 0, tonumber(v.cz) or 0
  return v
end

-- Buttons in one row, widths proportional to their weights, one column apart.
M.row = function(L, y, w, ids, weights)
  local total, acc = 0, 0
  for _, n in ipairs(weights) do total = total + n end
  local free = w - (#ids - 1)
  for i, id in ipairs(ids) do
    local a = math.floor(acc * free / total + 0.5)
    acc = acc + weights[i]
    L.buttons[#L.buttons+1] = {id=id, x=1+a+i-1, y=y, w=math.floor(acc * free / total + 0.5)-a, h=1}
  end
end
M.layout = function(w, h)
  local key = w .. "x" .. h
  if M.layouts[key] then return M.layouts[key] end
  local top = M.headerRow + 1
  local rows = h - top + 1
  local L = {my=top, mx=1, buttons={}}
  local function add(id, x, y, width, height) L.buttons[#L.buttons+1] = {id=id, x=x, y=y, w=width, h=height} end
  if w >= 29 and rows >= 8 and w * 6 >= h * 9 then
    -- Landscape: a control rail on the right, the map uses everything else.
    local rw = w >= 90 and 15 or 9
    local rx, bh = w - rw, rows >= 29 and 3 or 1
    local all = rows >= 8 * bh + 5
    local some, third, half = all or rows >= 8 * bh + 2, rw / 3, math.floor((rw - 1) / 2)
    local y = top
    L.mw, L.mh = rx - 2, rows
    add("map-fit", rx, y, rw, bh) y = y + bh + (all and 1 or 0)
    add("map-out", rx, y, half, bh) add("map-in", rx + rw - half, y, half, bh) y = y + bh + (some and 1 or 0)
    add("map-n", rx + third, y, third, bh) add("map-w", rx, y + bh, third, bh)
    add("map-e", rx + 2 * third, y + bh, third, bh) add("map-s", rx + third, y + 2 * bh, third, bh)
    y = y + 3 * bh + (some and 1 or 0)
    add("map-up", rx, y, rw, bh) y = y + bh + (all and 1 or 0)
    add("map-level", rx, y, rw, bh) y = y + bh + (all and 1 or 0)
    add("map-down", rx, y, rw, bh)
  else
    -- Portrait and small screens: two control rows under the map.
    L.mw, L.mh = w, math.max(1, h - top - 1)
    if w >= 23 then
      M.row(L, h - 1, w, {"map-w","map-n","map-s","map-e","map-out","map-in"}, {3,3,3,3,3,3})
      M.row(L, h, w, {"map-fit","map-down","map-level","map-up"}, {5,4,7,4})
    else
      M.row(L, h - 1, w, {"map-w","map-n","map-s","map-e"}, {3,3,3,3})
      M.row(L, h, w, {"map-out","map-fit","map-in","map-level"}, {3,5,3,7})
    end
  end
  M.layouts[key] = L
  return L
end

M.bounds = function(s)
  local b
  local function add(x, z)
    if not b then b = {x, z, x, z} return end
    b[1], b[2], b[3], b[4] = math.min(b[1], x), math.min(b[2], z), math.max(b[3], x), math.max(b[4], z)
  end
  local g = s.g
  if g then
    add(g.x, g.z)
    if g.branches > 0 then
      add(g.x + g.dx * g.spine, g.z + g.dz * g.spine)
      add(g.x + g.dx * g.gap + g.rx * g.length, g.z + g.dz * g.gap + g.rz * g.length)
      add(g.x + g.dx * g.spine + g.rx * g.length, g.z + g.dz * g.spine + g.rz * g.length)
    end
  end
  if s.area then add(s.area.x1, s.area.z1) add(s.area.x2, s.area.z2) end
  if s.server then add(s.server.x, s.server.z) end
  for _, p in ipairs(s.drops) do add(p.x, p.z) end
  for _, t in ipairs(s.turtles) do add(t.pose.x, t.pose.z) end
  return b
end
M.fit = function(v, s, pw, ph)
  local b = M.bounds(s)
  if not b then v.zoom, v.cx, v.cz = 0, 0, 0 return end
  local zoom = -1
  while zoom < 8 and ((b[3] - b[1] + 1) / 2 ^ zoom > pw - 2 or (b[4] - b[2] + 1) / 2 ^ zoom > ph - 2) do zoom = zoom + 1 end
  v.zoom, v.cx, v.cz = zoom, math.floor((b[1] + b[3]) / 2), math.floor((b[2] + b[4]) / 2)
end
M.cellOf = function(v, x, z)
  local px, pz = math.floor((x - v.left) / v.scale), math.floor((z - v.top) / v.scale)
  if px < 0 or pz < 0 or px >= v.pw or pz >= v.ph then return end
  return math.floor(px / 2), math.floor(pz / 3)
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
M.planesFor = function(v, s)
  local x1, z1 = v.left, v.top
  local x2, z2 = x1 + math.ceil(v.pw * v.scale) - 1, z1 + math.ceil(v.ph * v.scale) - 1
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
      local d = M.dirs[tonumber(t.pose.facing) or 0] or M.dirs[0]
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

M.raster = function(v, s, planes)
  local r, pw, ph, scale, left, top, level = {}, v.pw, v.ph, v.scale, v.left, v.top, v.level
  local n, all, g, area = scale < 1 and math.floor(1 / scale + 0.5) or 1, level == "all", s.g, s.area
  local function put(px, pz, cls)
    -- Planned passages are dotted, one dot per pixel or per zoomed-in block.
    if px >= 0 and px < pw and pz >= 0 and pz < ph and (cls ~= 1 or (math.floor(px / n) + math.floor(pz / n)) % 2 == 0) then
      local k = pz * pw + px + 1
      if (r[k] or 0) < cls then r[k] = cls end
    end
  end
  local function block(x, z, cls)
    local px, pz = math.floor((x - left) / scale), math.floor((z - top) / scale)
    for i = 0, n - 1 do for j = 0, n - 1 do put(px + i, pz + j, cls) end end
  end
  -- An axis-aligned run of blocks, clipped to the view in pixel space.
  local function line(x1, z1, x2, z2, cls)
    for px = math.max(0, math.floor((math.min(x1, x2) - left) / scale)),
        math.min(pw - 1, math.floor((math.max(x1, x2) - left) / scale) + n - 1) do
      for pz = math.max(0, math.floor((math.min(z1, z2) - top) / scale)),
          math.min(ph - 1, math.floor((math.max(z1, z2) - top) / scale) + n - 1) do put(px, pz, cls) end
    end
  end
  if g and (all or level == g.bottom) then
    if g.spine > 0 then line(g.x + g.dx, g.z + g.dz, g.x + g.dx * g.spine, g.z + g.dz * g.spine, 1) end
    for k = 1, g.branches do
      local x, z = g.x + g.dx * k * g.gap, g.z + g.dz * k * g.gap
      line(x + g.rx, z + g.rz, x + g.rx * g.length, z + g.rz * g.length, 1)
    end
  end
  local farm = area and (all or level >= s.ground and level <= s.ground + 8)
  local ax1, ax2, az1, az2
  if farm then
    ax1, ax2, az1, az2 = math.min(area.x1, area.x2), math.max(area.x1, area.x2), math.min(area.z1, area.z2), math.max(area.z1, area.z2)
    line(ax1, az1, ax2, az1, 3) line(ax1, az2, ax2, az2, 3) line(ax1, az1, ax1, az2, 3) line(ax2, az1, ax2, az2, 3)
    for _, spot in ipairs(s.spots) do block(spot.x, spot.z, spot.ready and 5 or 4) end
  end
  for _, entry in ipairs(planes) do
    local c = entry.cells
    for i = 1, #c, 2 do
      -- Farm travel marks are not tunnels; the farm draws as a farm.
      if not (farm and c[i] >= ax1 and c[i] <= ax2 and c[i+1] >= az1 and c[i+1] <= az2) then block(c[i], c[i+1], 2) end
    end
  end
  for _, c in ipairs(s.reserved) do
    if all or c.y == level then block(c.x, c.z, g and M.lane(g, c) and 6 or 7) end
  end
  return r
end

M.encode = function(c, v, L, solid)
  local r, pw = v.raster, v.pw
  for cy = 0, L.mh - 1 do
    local row = c.cells[L.my + cy]
    for cx = 0, L.mw - 1 do
      local best, bits = 0, 0
      for j = 0, 2 do
        local k = (cy * 3 + j) * pw + cx * 2 + 1
        local a, b = r[k], r[k + 1]
        if a then bits = bits + 2 ^ (2 * j) if a > best then best = a end end
        if b then bits = bits + 2 ^ (2 * j + 1) if b > best then best = b end end
      end
      local cell = row and row[L.mx + cx]
      if best > 0 and cell then
        -- CC sextants hold five pixels; a lit bottom-right pixel swaps the colours.
        if solid then cell[1], cell[2], cell[3] = " ", U.ink(M.colour[best]), M.colour[best]
        elseif bits >= 32 then cell[1], cell[2], cell[3] = string.char(128 + 63 - bits), "f", M.colour[best]
        else cell[1], cell[2], cell[3] = string.char(128 + bits), M.colour[best], "f" end
      end
    end
  end
end
-- Serialized size of the drawn rows, as the display compacts them.
M.weigh = function(c)
  local total = 0
  for y = 1, c.h do
    local row, runs, last, text = c.cells[y], 0, "", 0
    for x = 1, c.w do
      local key = row[x][2] .. row[x][3]
      if key ~= last then runs, last = runs + 1, key end
      if row[x][1] ~= " " then text = x end
    end
    total = total + text + 30 + math.min(runs * 25, 2 * c.w + 10)
  end
  return total
end
M.markers = function(c, v, s, L)
  local occ, level = {}, v.level
  local function mark(x, z, ch, bg, item)
    local cx, cy = M.cellOf(v, x, z)
    if not cx then return end
    c.put(L.mx + cx, L.my + cy, ch, "f", bg)
    occ[cy * L.mw + cx] = item
    return cx, cy
  end
  local function near(p) return level == "all" or math.abs((p.y or level) - level) <= 1 end
  for _, p in ipairs(s.drops) do if near(p) then mark(p.x, p.z, M.letters[p.kind] or "?", p.broken and "e" or "a", p) end end
  if s.server and near(s.server) then mark(s.server.x, s.server.z, "@", "9", {server=true}) end
  if s.g then mark(s.g.x, s.g.z, "H", "9", {shaft=true}) end
  for i = #s.turtles, 1, -1 do
    local t = s.turtles[i]
    t.cx, t.cy = mark(t.pose.x, t.pose.z, M.arrows[t.pose.facing or t.pose.f or 0] or "^", t.color, t)
  end
  for _, t in ipairs(v.scale <= 2 and s.turtles or {}) do
    if t.cx and occ[t.cy * L.mw + t.cx] == t then
      local text = tostring(t.id)
      local sides = (t.pose.facing == 1 or t.pose.facing == "east") and {-#text, 1} or {1, -#text}
      for _, offset in ipairs(sides) do
        local start, free = t.cx + offset, true
        for x = start, start + #text - 1 do
          if x < 0 or x >= L.mw or occ[t.cy * L.mw + x] then free = false end
        end
        if free then
          c.put(L.mx + start, L.my + t.cy, text, "f", t.color)
          for x = start, start + #text - 1 do occ[t.cy * L.mw + x] = t end
          break
        end
      end
    end
  end
  return occ
end
M.owner = function(v, s, cx, cy)
  for _, c in ipairs(s.reserved) do
    if v.level == "all" or c.y == v.level then
      local x, y = M.cellOf(v, c.x, c.z)
      if x == cx and y == cy then
        local id = tostring(c.who):match("(%d+)$")
        return id and "#" .. id or tostring(c.who)
      end
    end
  end
end
M.readout = function(v, s, occ, L)
  local f = v.focus
  local cx, cy
  if f then cx, cy = M.cellOf(v, f.x, f.z) end
  if not cx then return "", "" end
  local item = occ[cy * L.mw + cx]
  local function at(p, y) return p.x .. "," .. (y and y .. "," or "") .. p.z end
  if item then
    if item.pose then return "#" .. item.id .. " " .. item.label, at(item.pose, item.pose.y) end
    if item.shaft then return "SHAFT", at(s.g) end
    if item.server then return "SERVER", at(s.server, s.server.y) end
    return (item.kind or "drop"):upper() .. (item.broken and " BROKEN" or ""), at(item, item.y)
  end
  local best = 0
  for j = 0, 2 do
    for i = 0, 1 do best = math.max(best, v.raster[(cy * 3 + j) * v.pw + cx * 2 + i + 1] or 0) end
  end
  local label = M.names[best] or ""
  if best >= 6 then label = label .. " " .. (M.owner(v, s, cx, cy) or "") end
  return label, at(f, v.level ~= "all" and v.level or nil)
end

M.render = function(w, h, session)
  session = type(session)=="table" and session or {}
  M.seen = SO.now()
  if not M.scene then M.gather(M.seen) end
  local s, v, L = M.scene, M.view(session), M.layout(w, h)
  local pw, ph = L.mw * 2, L.mh * 3
  if v.fit then M.fit(v, s, pw, ph) end
  v.scale, v.pw, v.ph, v.h, v.L, v.headerRow = 2 ^ v.zoom, pw, ph, h, L, M.headerRow
  v.left, v.top = v.cx - math.floor(pw * v.scale / 2), v.cz - math.floor(ph * v.scale / 2)
  local planes
  planes, v.ready = M.planesFor(v, s)
  local rkey = table.concat({w, h, v.zoom, v.left, v.top, tostring(v.level), s.terrain, M.serial, #planes}, ":")
  if v.rkey ~= rkey then v.raster, v.rkey = M.raster(v, s, planes), rkey end
  local fkey = table.concat({rkey, s.markers, tostring(v.fit), v.focus and v.focus.x or "", v.focus and v.focus.z or ""}, ":")
  if v.frame and v.fkey == fkey then return v.frame end
  local c = U.canvas(w, h)
  M.encode(c, v, L, v.solidKey == rkey and v.solid)
  if v.solidKey ~= rkey then
    -- A frame must fit one 16 KB message. Dense pictures on huge monitors
    -- fall back to whole-character cells, which compress into long runs.
    v.solid, v.solidKey = M.weigh(c) > 12500, rkey
    if v.solid then c = U.canvas(w, h) M.encode(c, v, L, true) end
  end
  local occ = M.markers(c, v, s, L)
  local f = v.focus and M.cellOf(v, v.focus.x, v.focus.z)
  if f then
    local _, fy = M.cellOf(v, v.focus.x, v.focus.z)
    if not occ[fy * L.mw + f] then c.put(L.mx + f, L.my + fy, "+", "f", "0") end
  end
  local label, coords = M.readout(v, s, occ, L)
  local room = math.max(0, w - 7)
  local text = #label + #coords + 1 <= room and (label ~= "" and label .. " " or "") .. coords or label:sub(1, room)
  c.header("MAP", text)
  for _, b in ipairs(L.buttons) do
    local value = b.id == "map-level" and (v.level == "all" and "ALL" or "Y" .. v.level)
    c.button(b.x, b.y, b.w, M.labels[b.id] or value or "", b.id,
      b.id == "map-fit" and v.fit and "9" or value and "b" or "7", b.h)
  end
  c.hit("map-pick", L.mx, L.my, L.mw, L.mh)
  v.frame, v.fkey = c.frame(), fkey
  return v.frame
end

M.zoom = function(v, step)
  local old = v.zoom or 0
  local new = math.max(-1, math.min(8, old + step))
  local f = v.focus
  if new ~= old and f and v.pw and M.cellOf(v, f.x, f.z) then
    -- Keep the focused block where it is on screen.
    local k = 2 ^ (new - old)
    v.cx, v.cz = f.x - math.floor((f.x - v.cx) * k + 0.5), f.z - math.floor((f.z - v.cz) * k + 0.5)
  end
  v.zoom, v.fit = new, false
end
M.input = function(event)
  if not event.session then return end
  local v, id, s = M.view(event.session), event.id, M.scene or {}
  local g, surface = s.g, M.surface(s)
  if id == "map-fit" then v.fit = true
  elseif id == "map-in" or id == "map-out" then M.zoom(v, id == "map-in" and -1 or 1)
  elseif M.pan[id] then
    local d, scale = M.pan[id], v.scale or 1
    v.fit = false
    v.cx = v.cx + d[1] * math.max(1, math.floor((v.pw or 3) * scale / 3))
    v.cz = v.cz + d[2] * math.max(1, math.floor((v.ph or 3) * scale / 3))
  elseif id == "map-up" or id == "map-down" then
    v.level = (v.level == "all" and (g and g.bottom or surface) or v.level) + (id == "map-up" and 1 or -1)
  elseif id == "map-level" then
    local mine = g and g.bottom
    if v.level == "all" then v.level = mine or surface
    elseif v.level == mine and mine ~= surface then v.level = surface
    else v.level = "all" end
  elseif id == "map-pick" and v.L and event.x and event.y then
    local L = v.L
    local cx = event.x - L.mx
    local cy = event.y - math.max(0, (event.session.h or v.h) - v.h) - L.my
    if cx >= 0 and cy >= 0 and cx < L.mw and cy < L.mh then
      local fx, fy
      if v.focus then fx, fy = M.cellOf(v, v.focus.x, v.focus.z) end
      if fx == cx and fy == cy then v.focus = nil
      else v.focus = {x=v.left + math.floor((cx * 2 + 1) * v.scale), z=v.top + math.floor((cy * 3 + 1) * v.scale)} end
    end
  end
end
return {name="map",handlers={},render=M.render,input=M.input,tick=function(now)
  M.ticks, M.budget = M.ticks + 1, 16
  if not M.wired and SO.mods.display then SO.mods.display.screen("map",M.render,M.input) M.wired=true end
  if M.seen and now - M.seen < 10000 then M.gather(now) M.revalidate() end
end}
