-- Per-section files for H4b1. Each section has two slots, map/a/<id> and
-- map/b/<id>. The index names the slot that is current. A flush writes the
-- other slot, checks the bytes, then publishes map/index. A crash before
-- that publish leaves the previous index in force.
--
-- Schema 1 chunks stay in map/legacy until the published sections match
-- them cell for cell. dropLegacy is the only delete.
--
-- H4a capacity stub. admit(fs, path, bytes, reserve) is true when
-- fs.getFreeSpace(path) is "unlimited", or a number at least bytes + reserve.
-- Otherwise it returns false, "capacity". controlReserve defaults to 65536.
-- H4a can replace M.admit without changing flush.

local Section = dofile("mapsection.lua")
local M = { admit = nil }

function M.admit(fs, path, bytes, reserve)
  if type(bytes) ~= "number" or bytes < 0 or type(reserve) ~= "number" or reserve < 0 then
    return false, "capacity"
  end
  local free = fs.getFreeSpace(path)
  if free == "unlimited" then return true end
  if type(free) ~= "number" then return false, "capacity" end
  if free >= bytes + reserve then return true end
  return false, "capacity"
end

local function readFile(fs, path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "rb")
  if not h then return nil end
  local ok, bytes = pcall(h.readAll)
  h.close()
  if ok and type(bytes) == "string" then return bytes end
end

local function writeFile(fs, path, bytes)
  local h = fs.open(path, "wb")
  if not h then return false, "open" end
  local ok, err = pcall(h.write, bytes)
  pcall(h.close)
  if not ok then return false, tostring(err) end
  if readFile(fs, path) ~= bytes then return false, "verify" end
  return true
end

local function slotPath(root, slot, id)
  return root .. "/" .. slot .. "/" .. tostring(id)
end

local function encodeIndex(index)
  local keys = {}
  for key in pairs(index.sections) do keys[#keys + 1] = key end
  table.sort(keys)
  local lines = { "CCS2IDX", "2", tostring(index.gen), tostring(#keys) }
  for _, key in ipairs(keys) do
    local meta = index.sections[key]
    lines[#lines + 1] = table.concat({
      key, tostring(meta.id), meta.slot, tostring(meta.rev), meta.hash, tostring(meta.bytes),
    }, "\t")
  end
  return table.concat(lines, "\n") .. "\n"
end

local function decodeIndex(text)
  if type(text) ~= "string" then return nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  if lines[#lines] == "" then lines[#lines] = nil end
  if lines[1] ~= "CCS2IDX" or lines[2] ~= "2" then return nil end
  local gen, count = tonumber(lines[3]), tonumber(lines[4])
  if not gen or gen % 1 ~= 0 or gen < 0 or not count or count % 1 ~= 0 or count < 0 then return nil end
  if #lines ~= 4 + count then return nil end
  local sections, seen = {}, {}
  for n = 1, count do
    local key, id, slot, rev, hash, bytes = lines[4 + n]:match("^([^\t]+)\t(%d+)\t([ab])\t(%d+)\t(%x+)\t(%d+)$")
    id, rev, bytes = tonumber(id), tonumber(rev), tonumber(bytes)
    if not key or not id or seen[key] or (slot ~= "a" and slot ~= "b") or not hash or #hash ~= 64 then
      return nil
    end
    if not Section.normalizeKey(key) or Section.normalizeKey(key) ~= key then return nil end
    seen[key] = true
    sections[key] = { id = id, slot = slot, rev = rev, hash = hash, bytes = bytes }
  end
  return { v = 2, gen = gen, sections = sections }
end

local function canonicalLegacy(names, chunks)
  local lines = { "CCS1MAP", tostring(#names) }
  for i = 1, #names do lines[#lines + 1] = names[i] end
  local keys = {}
  for key in pairs(chunks) do keys[#keys + 1] = key end
  table.sort(keys)
  lines[#lines + 1] = tostring(#keys)
  for _, key in ipairs(keys) do
    local chunk = chunks[key]
    lines[#lines + 1] = key
    lines[#lines + 1] = tostring(chunk.rev)
    local cells = {}
    for index in pairs(chunk.cells) do cells[#cells + 1] = index end
    table.sort(cells)
    lines[#lines + 1] = tostring(#cells)
    for _, index in ipairs(cells) do
      lines[#lines + 1] = tostring(index) .. " " .. tostring(chunk.cells[index])
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

local function parseLegacy(text)
  if type(text) ~= "string" then return nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  if lines[#lines] == "" then lines[#lines] = nil end
  if lines[1] ~= "CCS1MAP" then return nil end
  local count, pos = tonumber(lines[2]), 3
  if not count or count % 1 ~= 0 or count < 0 then return nil end
  local names = {}
  for i = 1, count do
    names[i] = lines[pos]
    pos = pos + 1
    if not names[i] then return nil end
  end
  local chunksN = tonumber(lines[pos])
  pos = pos + 1
  if not chunksN or chunksN % 1 ~= 0 or chunksN < 0 then return nil end
  local chunks = {}
  for _ = 1, chunksN do
    local key, rev, cellsN = lines[pos], tonumber(lines[pos + 1]), tonumber(lines[pos + 2])
    pos = pos + 3
    if type(key) ~= "string" or chunks[key] or not rev or not cellsN then return nil end
    local cells = {}
    for _ = 1, cellsN do
      local index, value = lines[pos]:match("^(%d+) (%d+)$")
      pos = pos + 1
      index, value = tonumber(index), tonumber(value)
      if not index or cells[index] ~= nil then return nil end
      cells[index] = value
    end
    chunks[key] = { rev = rev, cells = cells }
  end
  if lines[pos] ~= nil then return nil end
  return names, chunks
end

function M.open(fs, opts)
  fs = fs or _G.fs
  opts = opts or {}
  local root = opts.root or "map"
  local reserve = opts.reserve
  if reserve == nil then reserve = 65536 end
  local function hook(phase)
    if opts.hook then opts.hook(phase) end
  end
  local function yield()
    local sleep = rawget(_G, "sleep")
    if type(sleep) == "function" then sleep(0) end
  end
  fs.makeDir(root)
  fs.makeDir(root .. "/a")
  fs.makeDir(root .. "/b")

  local function sectionFile(meta)
    return readFile(fs, slotPath(root, meta.slot, meta.id))
  end
  local function indexOk(index)
    for key, meta in pairs(index.sections) do
      local bytes = sectionFile(meta)
      if type(bytes) ~= "string" or #bytes ~= meta.bytes then return false end
      local section = Section.decode(bytes)
      if not section or section.hash ~= meta.hash or section.rev ~= meta.rev or section.key ~= key then
        return false
      end
    end
    return true
  end
  local function loadIndex()
    local best, bestBytes
    for _, path in ipairs({ root .. "/index", root .. "/index.next", root .. "/index.bak" }) do
      local text = readFile(fs, path)
      local index = decodeIndex(text)
      if index and indexOk(index) and (not best or index.gen > best.gen) then
        best, bestBytes = index, text
      end
    end
    if fs.exists(root .. "/index") or fs.exists(root .. "/index.next") or fs.exists(root .. "/index.bak") then
      if not best then return nil, "no valid map index" end
    end
    best = best or { v = 2, gen = 0, sections = {} }
    local current = readFile(fs, root .. "/index")
    if bestBytes and current ~= bestBytes then
      local ok, err = writeFile(fs, root .. "/index", bestBytes)
      if not ok then return nil, err end
    end
    return best
  end

  local index, err = loadIndex()
  if not index then return nil, err end
  local dirty, snap = {}, {}
  local store = { index = index }

  function store:read(key)
    if dirty[key] then return dirty[key] end
    local meta = index.sections[key]
    if not meta then return nil end
    local section = Section.decode(sectionFile(meta) or "")
    if not section or section.hash ~= meta.hash then return nil end
    return section
  end
  function store:revision(key)
    local section = self:read(key)
    return section and section.rev or 0
  end
  function store:checkpoint()
    snap = {}
    for key, section in pairs(dirty) do snap[key] = section end
  end
  function store:rollback()
    dirty = {}
    for key, section in pairs(snap) do dirty[key] = section end
  end
  function store:observe(key, edits, rev, now)
    local section, why = Section.apply(self:read(key), key, edits, rev, now)
    if not section then return nil, why end
    dirty[key] = section
    return section
  end
  function store:touch(key, now)
    local section = self:read(key)
    if not section or section.lastRead == now then return end
    local copy = {
      v = 2, key = section.key, rev = section.rev, hash = section.hash,
      palette = section.palette, runs = section.runs,
      observedAt = section.observedAt, lastRead = now, tier = "hot",
    }
    dirty[key] = copy
  end
  function store:hasLegacy() return fs.exists(root .. "/legacy") end
  function store:sectionKey(pose) return Section.sectionKey(pose) end
  function store:cellIndex(x, y, z) return Section.cellIndex(x, y, z) end
  function store:normalizeKey(chunk) return Section.normalizeKey(chunk) end
  function store:get(section, index) return Section.get(section, index) end
  function store:wireName(name) return Section.wireName(name) end

  local function publish(sections, gen)
    local text = encodeIndex({ v = 2, gen = gen, sections = sections })
    local ok, why = writeFile(fs, root .. "/index.next", text)
    if not ok then return nil, why end
    if decodeIndex(readFile(fs, root .. "/index.next")) == nil then return nil, "verify" end
    if fs.exists(root .. "/index.bak") then fs.delete(root .. "/index.bak") end
    if fs.exists(root .. "/index") then fs.move(root .. "/index", root .. "/index.bak") end
    fs.move(root .. "/index.next", root .. "/index")
    if readFile(fs, root .. "/index") ~= text then return nil, "verify" end
    index = { v = 2, gen = gen, sections = sections }
    store.index = index
    return true
  end

  function store:flush()
    if not next(dirty) then return true end
    local encoded, total = {}, 0
    for key, section in pairs(dirty) do
      local bytes, why = Section.encode(section)
      if not bytes then return false, why end
      encoded[key] = { section = section, bytes = bytes }
      total = total + #bytes
    end
    local ok, why = M.admit(fs, root .. "/index", total, reserve)
    if not ok then return false, why end
    local maxId = 0
    for _, meta in pairs(index.sections) do if meta.id > maxId then maxId = meta.id end end
    local staged, n = {}, 0
    for key, item in pairs(encoded) do
      local meta = index.sections[key]
      local id, slot
      if meta then
        id, slot = meta.id, meta.slot == "a" and "b" or "a"
      else
        maxId = maxId + 1
        id, slot = maxId, "a"
      end
      local wrote, werr = writeFile(fs, slotPath(root, slot, id), item.bytes)
      if not wrote then return false, werr end
      local back = Section.decode(readFile(fs, slotPath(root, slot, id)) or "")
      if not back or back.hash ~= item.section.hash or back.key ~= key then return false, "verify" end
      staged[key] = { id = id, slot = slot, rev = item.section.rev, hash = item.section.hash, bytes = #item.bytes }
      n = n + 1
      if n % 4 == 0 then yield() end
    end
    hook("sections")
    local sections = {}
    for key, meta in pairs(index.sections) do sections[key] = meta end
    for key, meta in pairs(staged) do sections[key] = meta end
    local published, perr = publish(sections, index.gen + 1)
    if not published then return false, perr end
    dirty, snap = {}, {}
    hook("publish")
    return true
  end

  local function desiredFrom(names, chunks)
    local desired = {}
    for key, chunk in pairs(chunks) do
      if type(key) ~= "string" or Section.normalizeKey(key) == key then return nil, "bad chunk" end
      local storage = Section.normalizeKey("abs|" .. key)
      if not storage or type(chunk) ~= "table" or type(chunk.cells) ~= "table" then return nil, "bad chunk" end
      local cells, why = Section.schema1Cells(names, chunk.cells)
      if not cells then return nil, why end
      local section, serr = Section.fromCells(storage, chunk.rev, cells, 0, 0)
      if not section then return nil, serr end
      desired[storage] = section
    end
    return desired
  end
  local function sameCells(section, cells)
    for index = 0, 4095 do
      if Section.get(section, index) ~= cells[index] then return false end
    end
    return true
  end
  function store:matchesSchema1(names, chunks)
    local desired, why = desiredFrom(names, chunks)
    if not desired then return false, why end
    local count = 0
    for key in pairs(index.sections) do count = count + 1 end
    local want = 0
    for key, section in pairs(desired) do
      want = want + 1
      local bytes = Section.encode(section)
      local got = store:read(key)
      if not bytes or not got or got.rev ~= section.rev or got.hash ~= section.hash then return false end
      local legacy = key:match("^abs|(.+)$")
      local cells = legacy and Section.schema1Cells(names, chunks[legacy].cells)
      if not cells or not sameCells(got, cells) then return false end
    end
    return count == want
  end

  function store:stageSchema1(names, chunks)
    names, chunks = names or {}, chunks or {}
    local legacy = canonicalLegacy(names, chunks)
    local path = root .. "/legacy"
    local existing = readFile(fs, path)
    if existing and existing ~= legacy then return false, "legacy mismatch" end
    if not existing then
      local ok, why = writeFile(fs, path, legacy)
      if not ok then return false, why end
    end
    hook("legacy")
    local parsedNames, parsedChunks = parseLegacy(readFile(fs, path) or "")
    if canonicalLegacy(parsedNames or {}, parsedChunks or {}) ~= legacy then return false, "verify" end
    if store:matchesSchema1(names, chunks) then return true end
    local desired, why = desiredFrom(names, chunks)
    if not desired then return false, why end
    local total = 0
    local encoded = {}
    for key, section in pairs(desired) do
      local bytes, eerr = Section.encode(section)
      if not bytes then return false, eerr end
      encoded[key] = bytes
      total = total + #bytes
    end
    local ok, aerr = M.admit(fs, path, total, reserve)
    if not ok then return false, aerr end
    local maxId = 0
    for _, meta in pairs(index.sections) do if meta.id > maxId then maxId = meta.id end end
    local staged, n = {}, 0
    for key, bytes in pairs(encoded) do
      local meta = index.sections[key]
      local id, slot
      if meta then
        id, slot = meta.id, meta.slot == "a" and "b" or "a"
      else
        maxId = maxId + 1
        id, slot = maxId, "a"
      end
      staged[key] = { id = id, slot = slot, hold = bytes }
    end
    for key, item in pairs(staged) do
      local wrote, werr = writeFile(fs, slotPath(root, item.slot, item.id), item.hold)
      if not wrote then return false, werr end
      local back = Section.decode(readFile(fs, slotPath(root, item.slot, item.id)) or "")
      if not back or back.hash ~= desired[key].hash then return false, "verify" end
      local sourceKey = key:match("^abs|(.+)$")
      local cells = Section.schema1Cells(names, chunks[sourceKey].cells)
      if not cells or not sameCells(back, cells) or back.rev ~= chunks[sourceKey].rev then
        return false, "verify"
      end
      staged[key] = { id = item.id, slot = item.slot, rev = back.rev, hash = back.hash, bytes = #item.hold }
      n = n + 1
      if n % 4 == 0 then yield() end
    end
    hook("sections")
    hook("verify")
    local sections = {}
    for key, meta in pairs(staged) do sections[key] = meta end
    local published, perr = publish(sections, index.gen + 1)
    if not published then return false, perr end
    hook("publish")
    return true
  end

  function store:dropLegacy()
    local path = root .. "/legacy"
    if not fs.exists(path) then return true end
    local names, chunks = parseLegacy(readFile(fs, path) or "")
    if not names then return false, "bad legacy" end
    if not store:matchesSchema1(names, chunks) then return false, "unverified" end
    hook("drop")
    fs.delete(path)
    if fs.exists(path) then return false, "legacy remains" end
    return true
  end

  function store:maxRevision()
    local rev = 0
    for _, meta in pairs(index.sections) do if meta.rev > rev then rev = meta.rev end end
    return rev
  end
  function store:sizes()
    local payload, largest, count = 0, 0, 0
    for _, meta in pairs(index.sections) do
      count = count + 1
      payload = payload + meta.bytes
      if meta.bytes > largest then largest = meta.bytes end
    end
    local indexBytes = readFile(fs, root .. "/index")
    return {
      sections = count, payload = payload, largest = largest,
      index = indexBytes and #indexBytes or 0,
    }
  end
  return store
end

function M.schema1View(fs, root)
  root = root or "map"
  local best
  for _, path in ipairs({ root .. "/index", root .. "/index.next", root .. "/index.bak" }) do
    local index = decodeIndex(readFile(fs, path))
    if index and (not best or index.gen > best.gen) then best = index end
  end
  if not best then return nil end
  local names, chunks = {}, {}
  local function nameId(name)
    if name == "minecraft:air" then return 0 end
    for i, existing in ipairs(names) do
      if existing == name then return i end
    end
    names[#names + 1] = name
    return #names
  end
  for key, meta in pairs(best.sections) do
    local bytes = readFile(fs, slotPath(root, meta.slot, meta.id))
    if type(bytes) ~= "string" or #bytes ~= meta.bytes then return nil, nil, "bad section" end
    local section = Section.decode(bytes)
    if not section or section.key ~= key or section.rev ~= meta.rev or section.hash ~= meta.hash then
      return nil, nil, "bad section"
    end
    local legacy = key:match("^abs|(.+)$")
    if not legacy then return nil, nil, "bad section" end
    local cells = {}
    for index = 0, 4095 do
      local name = Section.get(section, index)
      if name then cells[index + 1] = nameId(name) end
    end
    chunks[legacy] = { rev = section.rev, cells = cells }
  end
  return names, chunks
end

return M
