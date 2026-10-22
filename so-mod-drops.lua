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

S.render = function(w, h, clientId)
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
  local ok, err = S.add({
    id = string.format("%d_%d_%d_%d_%s_%s", d.dim, d.x, d.y, d.z, d.side, d.kind),
    dim = d.dim, x = d.x, y = d.y, z = d.z, side = d.side, kind = d.kind,
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
  S.message = "draft set; tap add"
  if direct then S.addDraft() end
end

S.input = function(ev)
  if type(ev) ~= "table" then return end
  if type(ev.text) == "string" then S.typed(ev.text) return end
  if type(ev.id) ~= "string" then return end
  local view = S.view(ev.from)
  if ev.id == "prev" then view.page = math.max(1, view.page - 1) return end
  if ev.id == "next" then view.page = math.min(view.pages, view.page + 1) return end
  local fixId = ev.id:match("^fix:(.+)$")
  if fixId then S.fix(fixId) return end
  local removeId = ev.id:match("^remove:(.+)$")
  if removeId then S.remove(removeId) return end
  if ev.id == "kind" then
    local at = 1
    for i = 1, #S.kindOrder do
      if S.kindOrder[i] == S.draft.kind then at = i end
    end
    S.draft.kind = S.kindOrder[at % #S.kindOrder + 1]
    return
  end
  if ev.id == "side" then
    if S.draft.side == "front" then S.draft.side = "down" else S.draft.side = "front" end
    return
  end
  if ev.id == "add" then
    S.addDraft()
    return
  end
  local step = S.nudge[ev.id]
  if not step then return end
  S.draft[step[1]] = S.draft[step[1]] + step[2]
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
