-- so-log.lua - append-only event segments and snapshots for SO1.
-- A snapshot file is written before its pointer, and old segments are
-- removed only after that pointer is durable, keeping the previous snapshot's
-- segments for fallback. A half-written segment
-- loses at most the event in that write.
-- New segments target 8 KB to bound synchronous rewrite work. The 64 KB
-- read and single-event limit stays compatible with previous releases.

local M, C, H = {}, {}, {}

C.log = "so-data/log/"
C.snap = "so-data/snap/"
C.latest = "so-data/snap/latest"
C.seg = 65536
C.target = 8192
C.window = 1048576
C.every = 2000

H.segPath = function(n)
  return string.format("%s%06d", C.log, n)
end

H.snapPath = function(n)
  return string.format("%s%06d", C.snap, n)
end

H.dirs = function()
  fs.makeDir("so-data")
  fs.makeDir("so-data/log")
  fs.makeDir("so-data/snap")
end

H.exists = function(path)
  return fs.exists(path) or fs.exists(path .. ".tmp") or fs.exists(path .. ".bak")
end

H.wipe = function(path)
  if fs.exists(path) then fs.delete(path) end
  if fs.exists(path .. ".tmp") then fs.delete(path .. ".tmp") end
  if fs.exists(path .. ".bak") then fs.delete(path .. ".bak") end
end

H.pruneSnaps = function(n)
  for _, name in ipairs(fs.list("so-data/snap")) do
    local digits = name:match("^(%d%d%d%d%d%d)$")
      or name:match("^(%d%d%d%d%d%d)%.tmp$")
      or name:match("^(%d%d%d%d%d%d)%.bak$")
    if digits and tonumber(digits) < n - 1 then
      fs.delete(C.snap .. name)
    end
  end
end

H.liveBytes = function(path)
  local pick = path
  if not fs.exists(pick) then pick = path .. ".bak" end
  if not fs.exists(pick) then return 0 end
  return fs.getSize(pick)
end

H.validSeg = function(v)
  return type(v) == "table" and type(v.events) == "table"
end

H.validSnap = function(v)
  return type(v) == "table"
    and type(v.seq) == "number" and v.seq % 1 == 0 and v.seq >= 0
    and type(v.first) == "number" and v.first % 1 == 0 and v.first >= 1 and v.first < 1000000
    and type(v.values) == "table" and type(v.machines) == "table"
end

H.validLatest = function(v)
  return type(v) == "table"
    and type(v.n) == "number" and v.n % 1 == 0 and v.n >= 1
    and type(v.seq) == "number" and type(v.first) == "number"
end

H.readBox = function(store, path, valid, budget)
  if not H.exists(path) then return nil end
  local ok, box = pcall(store.store, path, valid, budget)
  if not ok or type(box) ~= "table" or type(box.value) ~= "table" then return nil end
  return box
end

H.openBox = function(store, path, valid, budget)
  local ok, box = pcall(store.store, path, valid, budget)
  if ok then return box end
  if tostring(box):find("no valid generation", 1, true) then
    H.wipe(path)
    local again, opened = pcall(store.store, path, valid, budget)
    if again then return opened end
    return nil, opened
  end
  return nil, box
end

H.breathe = function(n)
  if n % 100 ~= 0 then return end
  if type(SO) == "table" and SO.breathe then return SO.breathe() end
  os.queueEvent("so-log")
  local guard = 0
  while guard < 20 do
    guard = guard + 1
    local packed = table.pack(os.pullEvent())
    if packed[1] == "so-log" then return end
    os.queueEvent(table.unpack(packed, 1, packed.n))
  end
end

H.raw = function(S)
  local total, i = 0, S.first
  while i <= S.last do
    total = total + (S.sizes[i] or 0)
    i = i + 1
  end
  return total
end

H.keep = function(S)
  local kept, i = {}, 1
  while i <= #S.all do
    local ev = S.all[i]
    if type(ev.seg) ~= "number" or ev.seg >= S.first then kept[#kept + 1] = ev end
    i = i + 1
  end
  S.all = kept
end

H.rotate = function(S)
  local n = S.last + 1
  if n >= 1000000 then return false, "segment" end
  local box, err = H.openBox(S.store, H.segPath(n), H.validSeg, C.seg)
  if not box then return false, err or "segment" end
  S.last = n
  S.box = box
  S.cur = {}
  S.estimate = 96
  S.sizes[n] = 0
  return true
end

H.saveCur = function(S)
  local ok, err = S.box.save({ events = S.cur })
  if ok then S.sizes[S.last] = S.box.bytes or H.liveBytes(H.segPath(S.last)) end
  return ok, err
end

H.drop = function(S, ev)
  if S.cur and #S.cur > 0 and S.cur[#S.cur] == ev then S.cur[#S.cur] = nil end
end

H.fits = function(ev)
  local copy = {}
  for key, value in pairs(ev) do copy[key] = value end
  copy.seg = 999999
  return #textutils.serialize({events={copy}}) + 96 <= C.seg
end

H.append = function(S, ev)
  if type(ev) ~= "table" or type(ev.kind) ~= "string" then return false, "event" end
  if not S.box then
    local ok, err = H.rotate(S)
    if not ok then return false, err end
  end
  ev.seq = S.seq + 1
  ev.seg = S.last
  S.cur[#S.cur + 1] = ev
  -- A singleton wrapper overcounts each array entry, including its index.
  local bytes = #textutils.serialize({ events = { ev } }, { compact = true }) + 16
  local estimate = S.estimate + bytes
  if estimate > C.target and #S.cur > 1 then
    H.drop(S, ev)
    local ok, err = H.rotate(S)
    if not ok then return false, err end
    ev.seg = S.last
    S.cur[#S.cur + 1] = ev
    estimate = S.estimate + bytes
  end
  local ok, err = H.saveCur(S)
  if not ok and type(err) == "string" and err:find("budget", 1, true) and #S.cur > 1 then
    H.drop(S, ev)
    local rotated, rerr = H.rotate(S)
    if not rotated then return false, rerr end
    ev.seg = S.last
    S.cur[#S.cur + 1] = ev
    estimate = S.estimate + bytes
    ok, err = H.saveCur(S)
  end
  if not ok then
    H.drop(S, ev)
    return false, err
  end
  S.seq = ev.seq
  S.estimate = estimate
  S.all[#S.all + 1] = ev
  return true
end

H.due = function(S, pressure)
  if S.seq > 0 and S.seq % (pressure and C.every * 5 or C.every) == 0 then return true end
  if H.raw(S) > C.window - C.seg and S.first < S.last then return true end
  return false
end

H.checkpoint = function(S, payload)
  if type(payload) ~= "table" or type(payload.values) ~= "table" or type(payload.machines) ~= "table" then
    return false, "snapshot"
  end
  local retain = S.snap and S.snap.first or 1
  local planned, drop = H.raw(S), S.first
  -- Leave room for another segment while the previous snapshot pins old ones.
  local target = planned > C.window - C.seg and C.window - C.seg * 4 or C.window
  -- Small segments must not force a full snapshot after every 8 KB of growth.
  while drop < S.last and (drop < retain or planned > target) do
    planned = planned - (S.sizes[drop] or 0)
    drop = drop + 1
  end
  local n = S.snapN + 1
  if n >= 1000000 then return false, "snapshot" end
  payload.seq = S.seq
  payload.first = drop
  local box, err = H.openBox(S.store, H.snapPath(n), H.validSnap, 900000)
  if not box then return false, err or "snapshot" end
  local saved, saveErr = box.save(payload)
  if not saved then return false, saveErr end
  local latest, lerr = H.openBox(S.store, C.latest, H.validLatest, 8000)
  if not latest then return false, lerr or "snapshot" end
  local pointed, perr = latest.save({ n = n, seq = S.seq, first = drop })
  if not pointed then return false, perr end
  S.snapN, S.snap = n, payload
  H.pruneSnaps(n)
  while S.first < retain do
    S.sizes[S.first] = nil
    H.wipe(H.segPath(S.first))
    S.first = S.first + 1
  end
  H.keep(S)
  return true
end

H.take = function(S, n, box)
  local evs = box.value.events
  local e = 1
  while e <= #evs do
    local ev = evs[e]
    if type(ev) == "table" and type(ev.seq) == "number" and type(ev.kind) == "string" then
      if type(ev.seg) ~= "number" then ev.seg = n end
      S.all[#S.all + 1] = ev
      if ev.seq > S.seq then S.seq = ev.seq end
      H.breathe(#S.all)
    end
    e = e + 1
  end
  S.sizes[n] = box.bytes or H.liveBytes(H.segPath(n))
  S.last = n
  S.box = nil
  S.cur = evs
  S.estimate = #textutils.serialize({ events = evs }, { compact = true }) + 96
end

H.load = function(S)
  H.dirs()
  local latest = H.readBox(S.store, C.latest, H.validLatest, 8000)
  local previous
  if latest then
    H.pruneSnaps(latest.value.n)
    S.snapN = latest.value.n
    if S.snapN > 1 then
      previous = H.readBox(S.store, H.snapPath(S.snapN - 1), H.validSnap, 900000)
    end
    local box = H.readBox(S.store, H.snapPath(S.snapN), H.validSnap, 900000)
    if not box and S.snapN > 1 then
      box = previous
      if box then S.snapN = S.snapN - 1 end
    end
    if box then S.snap = box.value end
  end
  local first = 1
  if S.snap and type(S.snap.first) == "number" then first = S.snap.first end
  if S.snap and previous then first = math.min(first, previous.value.first) end
  S.first = first
  if S.snap and type(S.snap.seq) == "number" and S.snap.seq > S.seq then S.seq = S.snap.seq end
  local i = 1
  while i < first do
    if H.exists(H.segPath(i)) then H.wipe(H.segPath(i)) end
    i = i + 1
  end
  S.last = first - 1
  local n, guard = first, 0
  while guard < 1000000 do
    guard = guard + 1
    local path = H.segPath(n)
    if not H.exists(path) then break end
    local box = H.readBox(S.store, path, H.validSeg, C.seg)
    if not box then
      if H.exists(H.segPath(n + 1)) then
        n = n + 1
      else
        H.wipe(path)
        break
      end
    else
      H.take(S, n, box)
      S.box = box
      n = n + 1
    end
  end
end

M.open = function(store)
  local S = {
    store = store, seq = 0, first = 1, last = 0, all = {}, sizes = {},
    snapN = 0, cur = nil, box = nil, snap = nil,
  }
  H.load(S)
  return {
    snap = S.snap,
    events = function() return S.all end,
    fits = H.fits,
    append = function(ev) return H.append(S, ev) end,
    due = function(pressure) return H.due(S, pressure) end,
    checkpoint = function(payload) return H.checkpoint(S, payload) end,
    rawBytes = function() return H.raw(S) end,
    status = function()
      return { available=true, seq=S.seq, segments=math.max(0,S.last-S.first+1), bytes=H.raw(S),
        snapshot=S.snapN, snapshotAt=S.snap and S.snap.gameAt, due=H.due(S) }
    end,
  }
end

return M
