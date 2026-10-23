local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local S = {
  points = {},
  box = nil,
  rev = 0,
  views = {},
  message = "type x y z, then add",
  wired = false,
  cap = 64,
  strikes = 3,
  kinds = { fuel = true, ore = true, junk = true, wood = true, storage = true, any = true },
  kindOrder = { "fuel", "ore", "junk", "wood", "storage", "any" },
  face = {
    front = { "inspect", "drop" },
    down = { "inspectDown", "dropDown" },
  },
  draft = { dim = 0, x = 0, y = 64, z = 0, side = "front", kind = "ore" },
  nudge = {
    ["dim+"] = { "dim", 1 }, ["dim-"] = { "dim", -1 },
    ["x+"] = { "x", 1 }, ["x-"] = { "x", -1 },
    ["y+"] = { "y", 1 }, ["y-"] = { "y", -1 },
    ["z+"] = { "z", 1 }, ["z-"] = { "z", -1 },
  },
  errText = {
    full = "64 points",
    bad = "bad field",
    kind = "bad kind",
    side = "bad side",
    exists = "id exists",
    missing = "missing point",
  },
}

S.whole = function(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n == math.floor(n)
end

S.recordOk = function(p)
  if type(p) ~= "table" then return false end
  local keys = 0
  for key in pairs(p) do
    keys = keys + 1
    if key ~= "id" and key ~= "dim" and key ~= "x" and key ~= "y" and key ~= "z"
      and key ~= "side" and key ~= "kind" and key ~= "fails" then
      return false
    end
  end
  if keys ~= 8 then return false end
  if type(p.id) ~= "string" or not p.id:match("^[%w_%-]+$") then return false end
  if not S.whole(p.dim) or not S.whole(p.x) or not S.whole(p.y) or not S.whole(p.z) then return false end
  if not S.face[p.side] or not S.kinds[p.kind] then return false end
  if not S.whole(p.fails) or p.fails < 0 or p.fails > S.strikes then return false end
  return true
end

S.valid = function(value)
  if type(value) ~= "table" or type(value.points) ~= "table" then return false end
  for key in pairs(value) do
    if key ~= "points" then return false end
  end
  local points = value.points
  local n = #points
  if n > S.cap then return false end
  local seen = {}
  local count = 0
  for key in pairs(points) do
    count = count + 1
    if not S.whole(key) or key < 1 or key > n then return false end
  end
  if count ~= n then return false end
  for i = 1, n do
    local row = points[i]
    if not S.recordOk(row) or seen[row.id] then return false end
    seen[row.id] = true
  end
  return true
end

S.clone = function(list)
  local out = {}
  for i = 1, #list do
    local p = list[i]
    out[i] = {
      id = p.id, dim = p.dim, x = p.x, y = p.y, z = p.z,
      side = p.side, kind = p.kind, fails = p.fails,
    }
  end
  return out
end

S.pub = function(p)
  return { id = p.id, dim = p.dim, x = p.x, y = p.y, z = p.z, side = p.side, kind = p.kind }
end

S.find = function(id)
  for i = 1, #S.points do
    if S.points[i].id == id then return i end
  end
end

S.same = function(p, point)
  return p.dim == point.dim and p.x == point.x and p.y == point.y and p.z == point.z
    and p.side == point.side and p.kind == point.kind
end

S.emit = function(key, value)
  local state = SO.mods.state
  if type(state) ~= "table" or type(state.emit) ~= "function" then return end
  state.emit(key, value)
end

S.commit = function(previous, op, id)
  local ok, err = S.box.save({ points = S.clone(S.points) })
  if not ok then
    S.points = previous
    return false, err
  end
  S.rev = S.rev + 1
  S.emit("drops", { op = op, id = id })
  return true
end

S.add = function(point)
  if type(point) ~= "table" or type(point.id) ~= "string" or not point.id:match("^[%w_%-]+$") then
    return false, "bad"
  end
  if not S.whole(point.dim) or not S.whole(point.x) or not S.whole(point.y) or not S.whole(point.z) then
    return false, "bad"
  end
  if not S.kinds[point.kind] then return false, "kind" end
  if not S.face[point.side] then return false, "side" end
  local idx = S.find(point.id)
  if idx then
    if S.same(S.points[idx], point) then return true end
    return false, "exists"
  end
  if #S.points >= S.cap then return false, "full" end
  local previous = S.clone(S.points)
  S.points[#S.points + 1] = {
    id = point.id, dim = point.dim, x = point.x, y = point.y, z = point.z,
    side = point.side, kind = point.kind, fails = 0,
  }
  return S.commit(previous, "add", point.id)
end

S.remove = function(id)
  local idx = S.find(id)
  if not idx then return true end
  local previous = S.clone(S.points)
  table.remove(S.points, idx)
  return S.commit(previous, "remove", id)
end

S.fix = function(id)
  local idx = S.find(id)
  if not idx then return false, "missing" end
  if S.points[idx].fails == 0 then return true end
  local previous = S.clone(S.points)
  S.points[idx].fails = 0
  return S.commit(previous, "fix", id)
end

S.note = function(id, blockName)
  local idx = S.find(id)
  if not idx then return false, "missing" end
  local fails = S.points[idx].fails
  if fails >= S.strikes then return true end
  local nextFails
  if blockName == nil then
    nextFails = fails + 1
  elseif type(blockName) == "string" and blockName ~= "" then
    if fails == 0 then return true end
    nextFails = 0
  else
    return false, "bad"
  end
  local previous = S.clone(S.points)
  S.points[idx].fails = nextFails
  return S.commit(previous, "note", id)
end

S.scan = function(kind, nearPos)
  local want, wantDist, wantId
  local anyPoint, anyDist, anyId
  for i = 1, #S.points do
    local p = S.points[i]
    if p.dim == nearPos.dim and p.fails < S.strikes and (p.kind == kind or p.kind == "any") then
      local dx = p.x - nearPos.x
      local dy = p.y - nearPos.y
      local dz = p.z - nearPos.z
      local dist = dx * dx + dy * dy + dz * dz
      if p.kind == kind and (not want or dist < wantDist or (dist == wantDist and p.id < wantId)) then
        want, wantDist, wantId = p, dist, p.id
      end
      if p.kind == "any" and (not anyPoint or dist < anyDist or (dist == anyDist and p.id < anyId)) then
        anyPoint, anyDist, anyId = p, dist, p.id
      end
    end
  end
  return want, anyPoint
end

S.pick = function(kind, nearPos)
  if type(kind) ~= "string" or not S.kinds[kind] then return nil end
  if type(nearPos) ~= "table" or not S.whole(nearPos.dim) or not S.whole(nearPos.x)
    or not S.whole(nearPos.y) or not S.whole(nearPos.z) then
    return nil
  end
  local want, anyPoint = S.scan(kind, nearPos)
  local chain = { { kind = kind, point = want and S.pub(want) or nil, usable = want ~= nil } }
  if kind ~= "any" then
    chain[2] = { kind = "any", point = anyPoint and S.pub(anyPoint) or nil, usable = anyPoint ~= nil }
  end
  chain[#chain + 1] = "hold"
  local point
  for i = 1, #chain - 1 do
    if chain[i].usable then
      point = chain[i].point
      break
    end
  end
  local alert
  if not point then
    alert = "drops: hold " .. kind
    S.emit("drops.alert", { kind = kind, text = alert })
  end
  return { point = point, chain = chain, alert = alert }
end

S.steps = function(point)
  if type(point) ~= "table" or type(point.id) ~= "string" then return {} end
  local ops = S.face[point.side]
  if not ops then return {} end
  return { { op = ops[1] }, { op = ops[2] } }
end

S.replyErr = function(reply, code)
  local text = S.errText[code]
  if text then
    reply("err", { code = code, text = text })
    return
  end
  reply("err", { code = "store", text = tostring(code) })
end

S.onEdit = function(msg, reply)
  local body = type(msg) == "table" and msg.body or nil
  if type(body) ~= "table" or type(body.op) ~= "string" then
    S.replyErr(reply, "bad")
    return
  end
  local ok, err
  if body.op == "add" then
    ok, err = S.add(body)
  elseif body.op == "remove" or body.op == "fix" then
    if type(body.id) ~= "string" then
      S.replyErr(reply, "bad")
      return
    end
    if body.op == "remove" then ok, err = S.remove(body.id) else ok, err = S.fix(body.id) end
  else
    S.replyErr(reply, "bad")
    return
  end
  if ok then
    reply("ack", { ok = true, id = body.id })
    return
  end
  S.replyErr(reply, err)
end

S.row = function(text)
  return { text = text, fg = "0", bg = "f" }
end

S.button = function(id, x, y, label)
  return { id = id, x = x, y = y, w = #label, label = label }
end

S.view = function(id)
  id = id or 0
  if not S.views[id] then S.views[id] = { page = 1, pages = 1 } end
  return S.views[id]
end
setmetatable(S.views, { __mode = "k" })

S.legacyRender = function(w, h, clientId)
  w, h = w or 26, h or 9
  local rows = { S.row("drops") }
  local buttons = {}
  local view = S.view(clientId)
  local count = math.max(1, math.floor((h - 7) / 2))
  view.pages = math.max(1, math.ceil(#S.points / count))
  view.page = math.min(view.page, view.pages)
  local first = (view.page - 1) * count + 1
  for i = first, math.min(#S.points, first + count - 1) do
    local p = S.points[i]
    local detail = " " .. p.kind .. " " .. p.side .. (p.fails >= S.strikes and " broken" or "")
    rows[#rows + 1] = S.row(p.id:sub(1, math.max(1, w - #detail)) .. detail)
    rows[#rows + 1] = S.row("")
    buttons[#buttons + 1] = S.button("fix:" .. p.id, 1, #rows, "fix")
    buttons[#buttons + 1] = S.button("remove:" .. p.id, 6, #rows, "remove")
  end
  rows[#rows + 1] = S.row("          " .. view.page .. "/" .. view.pages)
  buttons[#buttons + 1] = S.button("prev", 1, #rows, "prev")
  buttons[#buttons + 1] = S.button("next", 6, #rows, "next")
  local d = S.draft
  rows[#rows + 1] = S.row(string.format("draft %s %s dim %d", d.kind, d.side, d.dim))
  rows[#rows + 1] = S.row(string.format("%d %d %d", d.x, d.y, d.z))
  for _, names in ipairs({ { "kind", "side", "add", "dim+", "dim-" },
      { "x+", "x-", "y+", "y-", "z+", "z-" } }) do
    rows[#rows + 1] = S.row("")
    local x = 1
    for _, label in ipairs(names) do
      buttons[#buttons + 1] = S.button(label, x, #rows, label)
      x = x + #label + 1
    end
  end
  rows[#rows + 1] = S.row(S.message)
  return { rev = S.rev, rows = rows, buttons = buttons }
end

S.addDraft = function()
  local d = S.draft
  local id = string.format("%d_%d_%d_%d_%s_%s", d.dim, d.x, d.y, d.z, d.side, d.kind)
  local ok, err = S.add({
    id = id, dim = d.dim, x = d.x, y = d.y, z = d.z, side = d.side, kind = d.kind,
  })
  S.message = ok and "point added" or (S.errText[err] or tostring(err))
end

S.typed = function(text)
  local words = {}
  for word in text:gmatch("%S+") do words[#words + 1] = word end
  local d = S.draft
  local dim, x, y, z, kind, side = d.dim, nil, nil, nil, d.kind, d.side
  local direct = words[1] == "add"
  if direct then
    if #words < 5 or #words > 7 then S.message = "add kind x y z [side/dim]" return end
    kind = words[2]
    if not S.kinds[kind] then S.message = "bad kind" return end
    x, y, z = tonumber(words[3]), tonumber(words[4]), tonumber(words[5])
    if words[6] then
      if S.face[words[6]] then
        side = words[6]
        if words[7] then dim = tonumber(words[7]) end
      elseif #words == 6 then
        dim = tonumber(words[6])
      else
        S.message = "bad side" return
      end
    end
  elseif #words == 3 then
    x, y, z = tonumber(words[1]), tonumber(words[2]), tonumber(words[3])
  elseif #words == 4 then
    dim, x, y, z = tonumber(words[1]), tonumber(words[2]), tonumber(words[3]), tonumber(words[4])
  else
    S.message = "use x y z or dim x y z" return
  end
  if not S.whole(dim) or not S.whole(x) or not S.whole(y) or not S.whole(z) then
    S.message = "dim/x/y/z: integers only" return
  end
  S.draft = { dim = dim, x = x, y = y, z = z, kind = kind, side = side }
  S.drafted = true
  S.message = "draft set; tap add"
  if direct then S.addDraft() end
end

-- Route A screen (docs/ui/SCHEMATIC-SPEC.md); docs/ui/schematic/jobs.py is the twin of S.gather
-- and the layouts and writes their fixtures. Page, selection and the editor belong to the display.
S.hints = { ["type x y z, then add"] = true, ["draft set; tap add"] = true }
S.scales = { 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64 }
S.dirs = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
S.key = function(session, from)
  if type(session) == "table" then return session.id or session end
  return from or session
end
S.selectedPoint = function(view)
  if view and view.selected and S.find(view.selected) then return view.selected end
  for _, p in ipairs(S.points) do if p.fails >= S.strikes then return p.id end end
  return S.points[1] and S.points[1].id
end
S.call = function(name, fn)
  local mod = SO.mods[name]
  if type(mod) ~= "table" or type(mod[fn]) ~= "function" then return end
  local ok, got = pcall(mod[fn])
  if ok and type(got) == "table" then return got end
end
-- The plan's context: the server from so-server.cfg, the shaft and the farm, read every five seconds.
S.context = function()
  local now = SO.now()
  if S.ctx and now >= S.ctx.at and now < S.ctx.at + 5000 then return S.ctx end
  local ctx, read = { at = now }, SO.store.read
  local cfg = type(read) == "function" and read("so-server.cfg")
  if type(cfg) == "table" and type(cfg.pos) == "table" and S.whole(cfg.pos.x) and S.whole(cfg.pos.z) then
    ctx.server = { x = cfg.pos.x, z = cfg.pos.z }
  end
  local mine, wood = S.call("mine", "mapView"), S.call("lumber", "mapView")
  local home = mine and mine.homeSet ~= false and mine.home
  if type(home) == "table" and S.dirs[home.facing] then
    ctx.shaft = { x = home.x + S.dirs[home.facing][1], z = home.z + S.dirs[home.facing][2] }
  end
  if wood and type(wood.area) == "table" then ctx.area = wood.area end
  S.ctx = ctx
  return ctx
end
S.gather = function(view)
  local ctx, list = S.context(), {}
  for i, p in ipairs(S.points) do
    list[i] = { n = i, id = p.id, dim = p.dim, kind = p.kind, x = p.x, y = p.y, z = p.z, side = p.side,
      broken = p.fails >= S.strikes }
  end
  return { points = list, selected = S.selectedPoint(view), page = view.page, editing = view.editing,
    message = not S.hints[S.message] and S.message or nil, draft = S.draft,
    server = ctx.server, shaft = ctx.shaft, area = ctx.area }
end
S.at = function(p) return p.x .. "," .. p.y .. "," .. p.z end
-- The chests around home, one block per cell when they fit, labelled by number; the server, the
-- shaft and the farm edge for context. Returns the last row drawn.
S.plan = function(C, m, x0, y0, pw, ph, draft)
  local pts, items, dim = {}, {}, 0
  for _, p in ipairs(m.points) do if p.id == m.selected then dim = p.dim end end
  if draft then dim = draft.dim end
  for _, p in ipairs(m.points) do if p.dim == dim then pts[#pts + 1] = p items[#items + 1] = { p.x, p.z } end end
  -- The server, the shaft and the farm are in the overworld.
  if dim ~= 0 then m = { points = m.points, selected = m.selected } end
  local function span(i)
    local lo, hi = math.huge, -math.huge
    for _, it in ipairs(items) do lo, hi = math.min(lo, it[i]), math.max(hi, it[i]) end
    return lo, hi
  end
  if draft and #items > 0 then
    local x1, x2 = span(1)
    local z1, z2 = span(2)
    if draft.x < x1 - 32 or draft.x > x2 + 32 or draft.z < z1 - 32 or draft.z > z2 + 32 then draft = nil end
  end
  if draft then items[#items + 1] = { draft.x, draft.z } end
  if #items == 0 then return y0 - 1 end
  -- North is up, as on the map; the compass sits on the row above the plan.
  if y0 > 2 then C.put(x0 + pw - 2, y0 - 1, "\24N", "8") end
  for _, k in ipairs({ "server", "shaft" }) do if m[k] then items[#items + 1] = { m[k].x, m[k].z } end end
  local bx1, bx2 = span(1)
  local bz1, bz2 = span(2)
  local s = S.scales[#S.scales]
  for _, v in ipairs(S.scales) do
    if math.floor((bx2 - bx1) / v) + 1 <= pw - 4 and math.floor((bz2 - bz1) / v) + 1 <= ph then s = v break end
  end
  local left = bx1 - math.floor((pw - math.floor((bx2 - bx1) / s) - 1) / 2) * s
  local top = bz1 - math.floor((ph - math.floor((bz2 - bz1) / s) - 1) / 2) * s
  local function cell(x, z)
    local c, r = math.floor((x - left) / s), math.floor((z - top) / s)
    if c >= 0 and c < pw and r >= 0 and r < ph then return { x0 + c, y0 + r } end
  end
  local taken, marks = {}, {}
  local function take(x, y) taken[x .. "," .. y] = true end
  local a = m.area
  local c1, c2 = a and cell(a.x1, a.z1), a and cell(a.x2, a.z2)
  if c1 and c2 then
    for x = c1[1], c2[1] do
      for _, y in ipairs({ c1[2], c2[2] }) do C.put(x, y, "-", "c") take(x, y) end
    end
    for y = c1[2], c2[2] do
      for _, x in ipairs({ c1[1], c2[1] }) do C.put(x, y, "|", "c") take(x, y) end
    end
    for _, p in ipairs({ { c1[1], c1[2] }, { c2[1], c1[2] }, { c1[1], c2[2] }, { c2[1], c2[2] } }) do C.put(p[1], p[2], "+", "c") end
  end
  if m.shaft then marks[#marks + 1] = { cell(m.shaft.x, m.shaft.z), U.g.shaft, "9", nil, "shaft", "8" } end
  if m.server then marks[#marks + 1] = { cell(m.server.x, m.server.z), "@", "9", nil, "server", "8" } end
  for _, p in ipairs(pts) do
    local c = p.broken and "e" or "0"
    marks[#marks + 1] = { cell(p.x, p.z), p.broken and U.g.cross or U.g.bullet, c, p.id == m.selected and not draft and c or nil,
      tostring(p.n), p.broken and "e" or "8", not draft and "select:" .. p.id or nil }
  end
  if draft then marks[#marks + 1] = { cell(draft.x, draft.z), U.g.bullet, "9", "9" } end
  local drawn = {}
  for _, mk in ipairs(marks) do
    local at = mk[1]
    if at then
      C.put(at[1], at[2], mk[2], mk[4] and "f" or mk[3], mk[4])
      if mk[7] then C.hit(mk[7], at[1], at[2], 1, 1) end
      take(at[1], at[2])
      drawn[#drawn + 1] = mk
    end
  end
  for _, mk in ipairs(drawn) do
    local at, label = mk[1], mk[5]
    if label then
      for _, x in ipairs({ at[1] + 1, at[1] - #label }) do
        local free = x >= x0 and x + #label <= x0 + pw
        for j = -1, #label do
          if free and taken[(x + j) .. "," .. at[2]] and x + j ~= at[1] then free = false end
        end
        if free then
          C.put(x, at[2], label, mk[6])
          for j = 0, #label - 1 do take(x + j, at[2]) end
          break
        end
      end
    end
  end
  return y0 + ph - 1
end
S.list = function(C, m)
  local w, h = C.w, C.h
  local room = w >= 52 and h >= 22
  local ya, pts, broken = room and h - 1 or h, m.points, {}
  for _, p in ipairs(pts) do if p.broken then broken[#broken + 1] = p end end
  local nf = math.min(#broken, h >= 19 and 2 or 1)
  local lw, head, roomy = room and 34 or w - 1, h >= 14 and 4 or 3, w >= 30
  local cap = math.max(1, math.min(24, ya - 1 - (nf > 0 and nf + 1 or 0) - head - (room and 1 or 0) + 1))
  local pages = math.max(1, math.ceil(#pts / cap))
  local page = math.min(m.page, pages)
  local right = tostring(#pts)
  if pages > 1 then right = string.format(roomy and "    %d/%d    " or " %d/%d ", page, pages) end
  C.bar(roomy and "DROP POINTS" or "DROPS", {}, nil, right, "8")
  if pages > 1 then
    C.chip(w - #right, 1, U.g.left, "prev", "plain", roomy and 3 or 1)
    C.chip(w - (roomy and 3 or 1), 1, U.g.right, "next", "plain", roomy and 3 or 1)
  end
  local wide = lw >= 30
  if head == 4 then
    C.put(2, 3, "id", "8")
    C.put(5, 3, "kind", "8")
    C.put(wide and 15 or 14, 3, "where", "8")
    if wide then C.put(29, 3, "side", "8") end
  end
  local shown, sel = 0, nil
  for i = (page - 1) * cap + 1, math.min(#pts, page * cap) do
    local p, y = pts[i], head + shown
    local bg = p.id == m.selected and "7" or nil
    if bg then C.fill(1, y, lw, 1, "7") end
    local c = p.broken and "e" or "0"
    C.put(2, y, tostring(p.n), c, bg)
    C.put(5, y, p.kind:sub(1, 8), c, bg)
    if wide then
      C.put(15, y, S.at(p):sub(1, 13), "8", bg)
      C.put(29, y, p.side, "8", bg)
    else C.put(14, y, S.at(p):sub(1, lw - 14), "8", bg) end
    C.hit("select:" .. p.id, 1, y, lw, 1)
    shown = shown + 1
  end
  for i = 1, nf do
    local p = broken[i]
    local text = (i == nf and #broken > nf) and (#broken .. " broken") or (p.n .. " " .. p.kind .. " broken")
    C.flag(2, head + shown + i, lw - 1, text)
  end
  for _, p in ipairs(pts) do if p.id == m.selected then sel = p end end
  local tag = sel and " " .. sel.n or ""
  local fix, rem = "FIX" .. tag, "REMOVE" .. tag
  if #rem > math.floor((w - 2 - 2 * (room and 2 or 1)) / 3) then fix, rem = "FIX", "REMOVE" end
  U.actions(C, ya, { { fix, "fix", sel and sel.broken and "primary" or "muted" }, { rem, "remove", sel and "stop" or "muted" },
    { "ADD", "new", "plain" } }, room and 2 or 1)
  if room then
    local bottom = S.plan(C, m, 38, 3, math.min(w - 38, 48), math.min(ya - 4, 32))
    for y = 3, bottom do C.put(36, y, "|", "c") end
  end
end
S.editor = function(C, m)
  local w, h = C.w, C.h
  local room = w >= 52 and h >= 22
  local ya, d = room and h - 1 or h, m.draft
  C.bar("ADD DROP POINT", {}, nil, "", "8")
  local step, vx, vw = h >= 19 and 2 or 1, w >= 36 and 13 or 8, w >= 36 and 8 or 6
  local y = h >= 12 and 3 or 2
  for _, field in ipairs({ "kind", "side" }) do
    if w < 24 then C.chip(2, y, d[field], field, "plain", w - 2)
    else
      C.put(2, y, field, "8")
      C.chip(vx, y, d[field], field, "plain", vw + 9)
    end
    y = y + step
  end
  for _, field in ipairs({ "dim", "x", "y", "z" }) do
    if y > ya - 2 then break end
    C.put(2, y, field, "8")
    if w < 24 then
      C.put(3 + #field, y, tostring(d[field]):sub(1, math.max(0, w - 10 - #field)), "0")
      C.chip(w - 7, y, "-", field .. "-")
      C.chip(w - 3, y, "+", field .. "+")
    else U.stepper(C, vx, y, d[field], field, vw) end
    y = y + step
  end
  if m.message == "point added" then C.put(2, ya - 1, m.message, "d")
  elseif m.message then C.flag(2, ya - 1, w - 2, m.message) end
  U.actions(C, ya, { { "ADD", "add", "primary" }, { "BACK", "list", "plain" } }, room and 3 or 1)
  if room then
    local rx = vx + vw + 13
    local bottom = S.plan(C, m, rx + 2, 3, math.min(w - rx - 2, 48), math.min(ya - 4, 32), d)
    for yy = 3, bottom do C.put(rx, yy, "|", "c") end
  end
end
S.layout = function(model, w, h)
  local C = U.canvas(w, h)
  if model.editing then S.editor(C, model) else S.list(C, model) end
  return C.frame()
end
S.listSize = function(count, w, h)
  local room = w >= 52 and h >= 22
  local broken = 0
  for _, p in ipairs(S.points) do if p.fails >= S.strikes then broken = broken + 1 end end
  local nf = math.min(broken, h >= 19 and 2 or 1)
  local cap = math.max(1, math.min(24, (room and h - 1 or h) - 1 - (nf > 0 and nf + 1 or 0) - (h >= 14 and 4 or 3) - (room and 1 or 0) + 1))
  return { pages = math.max(1, math.ceil(count / cap)) }
end

S.render = function(w, h, session)
  if not U then return S.legacyRender(w, h, session) end
  w, h = w or 57, h or 24
  local view = S.view(S.key(session))
  local model = S.gather(view)
  model.page = math.min(model.page, S.listSize(#model.points, w, h).pages)
  view.page, view.armed = model.page, true
  local frame = S.layout(model, w, h)
  frame.rev = S.rev
  return frame
end

S.input = function(ev)
  if type(ev) ~= "table" then return end
  local view = S.view(S.key(ev.session, ev.from))
  if type(ev.text) == "string" then S.typed(ev.text); if U then view.editing = true end; return end
  if type(ev.id) ~= "string" then return end
  if ev.id == "new" then
    view.editing = true
    local idx = S.find(S.selectedPoint(view) or "")
    if not S.drafted and idx then
      local p = S.points[idx]
      S.draft = { dim = p.dim, x = p.x, y = p.y, z = p.z, side = p.side, kind = p.kind }
    end
    return
  end
  if ev.id == "list" then view.editing = false return end
  if not U and (ev.id == "prev" or ev.id == "next") then
    view.page = math.max(1, math.min(view.pages, view.page + (ev.id == "next" and 1 or -1)))
    return
  end
  if ev.id == "next" then view.page = view.page + 1 return end
  if ev.id == "prev" then view.page = math.max(1, view.page-1) return end
  local selected = ev.id:match("^select:(.+)$")
  if selected and S.find(selected) then view.selected = selected return end
  if ev.id == "fix" then local id = S.selectedPoint(view); if id then view.selected = id; S.fix(id) end return end
  -- A second REMOVE before the next frame would hit the fallback selection, so it waits for a frame.
  if ev.id == "remove" then
    local id = S.selectedPoint(view)
    if id and view.armed ~= false then view.armed = false S.remove(id) end
    return
  end
  local fixId = ev.id:match("^fix:(.+)$")
  if fixId then S.fix(fixId) return end
  local removeId = ev.id:match("^remove:(.+)$")
  if removeId then S.remove(removeId) return end
  if ev.id == "kind" then
    local at = 1
    for i = 1, #S.kindOrder do
      if S.kindOrder[i] == S.draft.kind then at = i end
    end
    S.draft.kind, S.drafted = S.kindOrder[at % #S.kindOrder + 1], true
    return
  end
  if ev.id == "side" then
    if S.draft.side == "front" then S.draft.side = "down" else S.draft.side = "front" end
    S.drafted = true
    return
  end
  if ev.id == "add" then
    -- The tapped ADD says when the draft is a point that already exists; typed add stays as it was.
    local d = S.draft
    if S.find(string.format("%d_%d_%d_%d_%s_%s", d.dim, d.x, d.y, d.z, d.side, d.kind)) then S.message = S.errText.exists return end
    S.addDraft()
    return
  end
  local step = S.nudge[ev.id]
  if not step then return end
  S.draft[step[1]] = S.draft[step[1]] + step[2]
  S.drafted = true
end

S.tick = function()
  if S.wired then return end
  local display = SO.mods.display
  if type(display) ~= "table" or type(display.screen) ~= "function" then return end
  display.screen("generic", S.render, S.input)
  S.wired = true
end

S.box = SO.store.store("so-drops", S.valid)
if S.box.value and type(S.box.value.points) == "table" then
  S.points = S.clone(S.box.value.points)
end

return {
  name = "drops",
  handlers = { ["drops.edit"] = S.onEdit },
  tick = S.tick,
  list = function()
    local out = {}
    for i, point in ipairs(S.points) do
      out[i] = S.pub(point)
      out[i].broken = point.fails >= S.strikes
    end
    return out
  end,
  pick = S.pick,
  steps = S.steps,
  add = S.add,
  remove = S.remove,
  fix = S.fix,
  note = S.note,
}
