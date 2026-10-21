local D = dofile("depth-result.lua")
local L = dofile("wh2-layout.lua")
local checks = {}

local function ctx(now)
  return {
    now = now, epoch = 1,
    config = L.config({ enabled = true, operators = { ["4"] = true } }),
  }
end

local function pos(x, y, z, h)
  return {
    v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
    x = x, y = y, z = z, h = h or 0, conf = "certain", src = "typed", anchoredAt = 1000,
  }
end

local function room(id)
  return {
    v = 1, id = id, revision = 0, scanComplete = false,
    bounds = { min = pos(0, 64, 0, 0), max = pos(3, 66, 3, 0) },
    observedChunks = {}, blocked = {}, accessPaths = {}, reserved = {},
  }
end

local function check(name, ok, err)
  D.check(checks, name, ok, err)
end

local phasePath = "layout-phase"
local statePath = "layout-state"

local function saveState(state)
  local handle = fs.open(statePath, "w")
  handle.write(textutils.serialize(state))
  handle.close()
end

local function loadState()
  local handle = fs.open(statePath, "r")
  local text = handle.readAll()
  handle.close()
  return textutils.unserialize(text)
end

local function phase()
  if not fs.exists(phasePath) then return "" end
  local handle = fs.open(phasePath, "r")
  local text = handle.readAll()
  handle.close()
  return text
end

local function setPhase(text)
  local handle = fs.open(phasePath, "w")
  handle.write(text)
  handle.close()
end

if phase() == "" then
  local state = {}
  local made = L.run(state, 4, {
    op = "wh2-layout", kind = "room", id = "room:main", baseRevision = 0, value = room("room:main"),
  }, ctx(1000))
  check("room record", made.ok == true, made.error)
  local blocked = L.run(state, 4, {
    op = "wh2-layout", kind = "room", id = "room:main", field = "blocked",
    uploadId = "layout:4:1", baseRevision = made.revision, offset = 0, final = false,
    records = { { key = "abs|minecraft:overworld|1|65|1", value = "minecraft:stone" } },
  }, ctx(5000))
  check("blocked upload opened", blocked.ok == true, blocked.error)
  local reserved = L.run(state, 4, {
    op = "wh2-layout", kind = "room", id = "room:main", field = "reserved",
    uploadId = "layout:4:2", baseRevision = made.revision, offset = 0, final = false,
    records = {},
  }, ctx(20000))
  check("reserved upload opened", reserved.ok == true, reserved.error)
  saveState(state)
  setPhase("reboot")
  local handle = fs.open("layout-ready", "w")
  handle.write("reboot")
  handle.close()
  return
end

local state = loadState()
local expired = L.run(state, 4, {
  op = "wh2-layout", action = "status", uploadId = "layout:4:1",
}, ctx(35000))
check("blocked upload expired after reboot", expired.code == "upload_expired", expired.error or expired.code)
local open = L.run(state, 4, {
  op = "wh2-layout", action = "status", uploadId = "layout:4:2",
}, ctx(35000))
check("reserved upload resumes by id", open.ok == true and open.final == false, open.error or open.code)
local retry = L.run(state, 4, {
  op = "wh2-layout", kind = "room", id = "room:main", field = "blocked",
  uploadId = "layout:4:1", baseRevision = state.wh2.layout.revision, offset = 0, final = true,
  records = {},
}, ctx(35000))
check("expired retry reports upload_expired", retry.code == "upload_expired", retry.error or retry.code)
local kept = state.wh2.layout.rooms["room:main"]
check("published room record stays", type(kept) == "table" and kept.blocked["abs|minecraft:overworld|1|65|1"] == nil, "room record changed")
local handle = fs.open("board.txt", "w")
handle.write("Layout upload layout:4:2 is open. Upload layout:4:1 expired.")
handle.close()
D.finish(checks)
