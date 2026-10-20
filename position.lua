local M = {}

local sources = { gps = true, neighbour = true, radio = true, typed = true, reckoned = true, inherited = true }
local confs = { certain = true, suspect = true, lost = true }
-- P0 left the measured modem error open. Half a block is the nearest-cell bound.
local residualLimit = 0.5

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function dimOk(dim)
  return type(dim) == "string" and #dim > 0 and #dim <= 80 and dim:match("^[%w_]+:[%w_/.-]+$")
end

function M.frameId(id)
  if type(id) ~= "string" or #id > 64 then return nil end
  local owner, stamp = id:match("^f:(%d+):(%d+)$")
  if not owner or not stamp then return nil end
  if #owner > 1 and owner:sub(1, 1) == "0" then return nil end
  if #stamp > 1 and stamp:sub(1, 1) == "0" then return nil end
  owner, stamp = tonumber(owner), tonumber(stamp)
  if not integer(owner, 0, 2147483647) or not integer(stamp, 0, 9007199254740991) then return nil end
  if id ~= "f:" .. owner .. ":" .. stamp then return nil end
  return owner, stamp
end

function M.toAbs(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    n = n + 1
    if k ~= "dx" and k ~= "dy" and k ~= "dz" and k ~= "rot" then return false end
  end
  return n == 4 and integer(t.dx, -60000000, 60000000) and integer(t.dy, -4096, 4096)
    and integer(t.dz, -60000000, 60000000) and integer(t.rot, 0, 3)
end

function M.frame(f)
  if type(f) ~= "table" or f.v ~= 1 then return false end
  local n = 0
  for k in pairs(f) do
    n = n + 1
    if k ~= "v" and k ~= "id" and k ~= "owner" and k ~= "yAbs" and k ~= "toAbs" then return false end
  end
  if n ~= 5 then return false end
  local owner = M.frameId(f.id)
  if not owner or f.owner ~= owner then return false end
  if f.yAbs ~= true and f.yAbs ~= false then return false end
  if f.toAbs == false then return true end
  return M.toAbs(f.toAbs) and (not f.yAbs or f.toAbs.dy == 0)
end

function M.pos(p)
  if type(p) ~= "table" or p.v ~= 1 then return false end
  local n = 0
  for k in pairs(p) do
    n = n + 1
    if k ~= "v" and k ~= "frame" and k ~= "yAbs" and k ~= "dim" and k ~= "x" and k ~= "y"
      and k ~= "z" and k ~= "h" and k ~= "conf" and k ~= "src" and k ~= "anchoredAt" then return false end
  end
  if n ~= 11 then return false end
  if p.frame ~= "abs" and not M.frameId(p.frame) then return false end
  if p.yAbs ~= true and p.yAbs ~= false then return false end
  if p.frame == "abs" and p.yAbs ~= true then return false end
  if not confs[p.conf] or not sources[p.src] then return false end
  if not integer(p.h, 0, 3) or not integer(p.anchoredAt, 0, 9007199254740991) then return false end
  return dimOk(p.dim) and integer(p.x, -30000000, 30000000) and integer(p.y, -2048, 2048)
    and integer(p.z, -30000000, 30000000)
end

function M.makePos(fields)
  if type(fields) ~= "table" then return nil end
  local frame = fields.frame or "abs"
  local yAbs = fields.yAbs
  if yAbs == nil or frame == "abs" then yAbs = true end
  local p = {
    v = 1, frame = frame, yAbs = yAbs, dim = fields.dim,
    x = fields.x, y = fields.y, z = fields.z, h = fields.h,
    conf = fields.conf or "certain", src = fields.src, anchoredAt = fields.anchoredAt,
  }
  if not M.pos(p) then return nil end
  return p
end

-- Headings are nav.lua's: 0 north, 1 east, 2 south, 3 west. Directions 0..3 match those headings.
function M.rotate(localFaces, h)
  if type(localFaces) ~= "table" or not integer(h, 0, 3) then return nil end
  return {
    [h] = localFaces.front,
    [(h + 1) % 4] = localFaces.right,
    [(h + 2) % 4] = localFaces.back,
    [(h + 3) % 4] = localFaces.left,
    [4] = localFaces.top,
    [5] = localFaces.bottom,
  }
end

function M.matches(recorded, localFaces, h)
  if type(recorded) ~= "table" then return false end
  local world = M.rotate(localFaces, h)
  if not world then return false end
  local n = 0
  for k, name in pairs(recorded) do
    if type(k) ~= "number" or k < 0 or k > 5 or k % 1 ~= 0 then return false end
    if type(name) ~= "string" or world[k] ~= name then return false end
    n = n + 1
  end
  return n >= 1
end

local function hasFace(faces)
  if type(faces) ~= "table" then return false end
  for _ in pairs(faces) do return true end
  return false
end

local function fingerprint(fromFaces, toFaces, localFaces)
  if not hasFace(fromFaces) or not hasFace(toFaces) then return nil end
  local cells, headings = {}, { from = {}, to = {} }
  for h = 0, 3 do
    local fromOk = M.matches(fromFaces, localFaces, h)
    local toOk = M.matches(toFaces, localFaces, h)
    if fromOk and not toOk then
      cells.from = true
      headings.from[#headings.from + 1] = h
    elseif toOk and not fromOk then
      cells.to = true
      headings.to[#headings.to + 1] = h
    end
  end
  if cells.from and cells.to then return nil end
  if cells.from then return "from", headings.from end
  if cells.to then return "to", headings.to end
  return nil
end

local function fuelCell(obs)
  if obs.charging ~= "none" or obs.regeneration ~= "none" then return nil end
  local now, before, cost = obs.fuelNow, obs.fuelBefore, obs.moveCost
  if type(now) ~= "number" or now ~= now or type(before) ~= "number" or before ~= before then return nil end
  if type(cost) ~= "number" or cost ~= cost or cost < 1 or cost % 1 ~= 0 then return nil end
  if now == before then return "from" end
  if now == before - cost then return "to" end
  return nil
end

local function pickHeading(list, saved)
  if not list or #list == 0 then return saved end
  if #list == 1 then return list[1] end
  for i = 1, #list do if list[i] == saved then return saved end end
  return nil
end

function M.resolveMove(obs)
  if type(obs) ~= "table" then return { conf = "lost" } end
  local fuel = fuelCell(obs)
  local cell, headings = fingerprint(obs.fromFaces, obs.toFaces, obs.localFaces)
  if fuel and cell and fuel ~= cell then return { conf = "lost" } end
  local chosen = fuel or cell
  if not chosen then return { conf = "lost" } end
  local heading
  if cell == chosen then
    heading = pickHeading(headings, obs.heading)
    if heading == nil then return { conf = "lost" } end
  else
    heading = obs.heading
  end
  if not integer(heading, 0, 3) then return { conf = "lost" } end
  return { conf = "certain", cell = chosen, heading = heading, method = cell and "fingerprint" or "fuel" }
end

function M.resolveBoot(obs)
  if type(obs) ~= "table" then return { conf = "suspect" } end
  if obs.unresolved then return M.resolveMove(obs) end
  local hits = {}
  for h = 0, 3 do
    if M.matches(obs.faces, obs.localFaces, h) then hits[#hits + 1] = h end
  end
  if #hits == 1 then return { conf = "certain", heading = hits[1], method = "fingerprint" } end
  return { conf = "suspect" }
end

function M.playerCell(player)
  if type(player) ~= "table" then return nil end
  local x, y, z = player.x, player.y, player.z
  if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
  if x ~= x or y ~= y or z ~= z or math.abs(x) == math.huge or math.abs(y) == math.huge or math.abs(z) == math.huge then
    return nil
  end
  local dim = player.dim or player.dimension
  if not dimOk(dim) then return nil end
  return { x = math.floor(x), y = math.floor(y) - 1, z = math.floor(z), dim = dim }
end

function M.parseAnchor(text)
  if type(text) ~= "string" then return nil end
  local id = text:match("^%$anchor%s+(%d+)%s*$")
  if not id or (#id > 1 and id:sub(1, 1) == "0") then return nil end
  local n = tonumber(id)
  if not integer(n, 0, 2147483647) then return nil end
  return n
end

function M.transform(x, y, z, h, yAbs, toAbs)
  if not M.toAbs(toAbs) or not integer(x, -30000000, 30000000) or not integer(y, -2048, 2048)
    or not integer(z, -30000000, 30000000) then return nil end
  if h ~= nil and not integer(h, 0, 3) then return nil end
  if yAbs and toAbs.dy ~= 0 then return nil end
  local rot = toAbs.rot
  local rx, rz
  if rot == 0 then rx, rz = x, z
  elseif rot == 1 then rx, rz = -z, x
  elseif rot == 2 then rx, rz = -x, -z
  else rx, rz = z, -x end
  local y2 = yAbs and y or y + toAbs.dy
  local x2, z2 = rx + toAbs.dx, rz + toAbs.dz
  if not integer(x2, -30000000, 30000000) or not integer(y2, -2048, 2048) or not integer(z2, -30000000, 30000000) then
    return nil
  end
  return x2, y2, z2, h and (h + rot) % 4 or nil
end

local function volume(a, b, c, d)
  local bax, bay, baz = b.x - a.x, b.y - a.y, b.z - a.z
  local cax, cay, caz = c.x - a.x, c.y - a.y, c.z - a.z
  local dax, day, daz = d.x - a.x, d.y - a.y, d.z - a.z
  local cx = cay * daz - caz * day
  local cy = caz * dax - cax * daz
  local cz = cax * day - cay * dax
  return math.abs(bax * cx + bay * cy + baz * cz)
end

local function coplanar(refs)
  local n = #refs
  if n < 4 then return true end
  for a = 1, n - 3 do
    for b = a + 1, n - 2 do
      for c = b + 1, n - 1 do
        for d = c + 1, n do
          if volume(refs[a], refs[b], refs[c], refs[d]) > 1e-6 then return false end
        end
      end
    end
  end
  return true
end

local function solve3(ata, atb)
  local m = {
    { ata[1][1], ata[1][2], ata[1][3], atb[1] },
    { ata[2][1], ata[2][2], ata[2][3], atb[2] },
    { ata[3][1], ata[3][2], ata[3][3], atb[3] },
  }
  for col = 1, 3 do
    local pivot = col
    for row = col + 1, 3 do
      if math.abs(m[row][col]) > math.abs(m[pivot][col]) then pivot = row end
    end
    m[col], m[pivot] = m[pivot], m[col]
    local div = m[col][col]
    if math.abs(div) < 1e-8 then return nil end
    for k = col, 4 do m[col][k] = m[col][k] / div end
    for row = 1, 3 do
      if row ~= col then
        local f = m[row][col]
        for k = col, 4 do m[row][k] = m[row][k] - f * m[col][k] end
      end
    end
  end
  return m[1][4], m[2][4], m[3][4]
end

local function hypot(x, y, z)
  return math.sqrt(x * x + y * y + z * z)
end

local function residual(refs, x, y, z)
  local worst = 0
  for i = 1, #refs do
    local e = math.abs(hypot(x - refs[i].x, y - refs[i].y, z - refs[i].z) - refs[i].dist)
    if e > worst then worst = e end
  end
  return worst
end

function M.triangulate(points)
  if type(points) ~= "table" then return nil end
  local refs, dim = {}, nil
  for i = 1, #points do
    local p = points[i]
    if type(p) == "table" and p.loaded ~= false and (p.frame == nil or p.frame == "abs")
      and (p.conf == nil or p.conf == "certain")
      and integer(p.x, -30000000, 30000000) and integer(p.y, -2048, 2048) and integer(p.z, -30000000, 30000000)
      and type(p.dist) == "number" and p.dist == p.dist and p.dist >= 0 and p.dist < 1e7 then
      if p.dim ~= nil and not dimOk(p.dim) then return nil end
      if p.dim and dim and p.dim ~= dim then return nil end
      dim = dim or p.dim
      if #refs < 16 then refs[#refs + 1] = { x = p.x, y = p.y, z = p.z, dist = p.dist, dim = p.dim } end
    end
  end
  if #refs < 4 or coplanar(refs) then return nil end
  local ata = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
  local atb = { 0, 0, 0 }
  local origin = refs[1]
  local base = origin.x * origin.x + origin.y * origin.y + origin.z * origin.z - origin.dist * origin.dist
  for i = 2, #refs do
    local r = refs[i]
    local row = { r.x - origin.x, r.y - origin.y, r.z - origin.z }
    local bi = 0.5 * ((r.x * r.x + r.y * r.y + r.z * r.z - r.dist * r.dist) - base)
    for a = 1, 3 do
      atb[a] = atb[a] + row[a] * bi
      for b = 1, 3 do ata[a][b] = ata[a][b] + row[a] * row[b] end
    end
  end
  local x, y, z = solve3(ata, atb)
  if not x or x ~= x or y ~= y or z ~= z then return nil end
  local function round(n) return math.floor(n + 0.5) end
  local cx, cy, cz = round(x), round(y), round(z)
  local winners = {}
  for dx = -1, 1 do
    for dy = -1, 1 do
      for dz = -1, 1 do
        local px, py, pz = cx + dx, cy + dy, cz + dz
        if residual(refs, px, py, pz) <= residualLimit then
          winners[#winners + 1] = { x = px, y = py, z = pz, dim = dim }
        end
      end
    end
  end
  if #winners ~= 1 then return nil end
  local best = winners[1]
  if not integer(best.x, -30000000, 30000000) or not integer(best.y, -2048, 2048)
    or not integer(best.z, -30000000, 30000000) then return nil end
  return best
end

return M
