-- fuel.lua - lava fuel runner (CC: Tweaked)
--
-- A turtle with buckets that keeps everyone's fuel chests full of lava. It fills its
-- empty buckets at lava cauldrons (a dripstone lava farm) and/or a lava lake, brings full
-- buckets to the chests you give it (the lumber turtle's chest, the miners' fuel chests,
-- ...) and takes their empty buckets back. Spare lava goes in its own chest (the depot).
-- It runs on that lava itself. No tool needed: it never digs.
--
-- Put it next to its depot chest (behind, beside or under it), with a few empty buckets
-- in the chest (or in the turtle).
--
-- One-time setup:
--   fuel setup <x> <y> <z> <facing>    where the turtle is (F3) and the way it faces
--                                      (with GPS hosts: just "fuel setup")
-- Where the lava comes from (add one or more):
--   fuel cauldrons <x> <y> <z> <count> <line> <walkway>
--        a straight line of cauldrons under dripstone: x y z = the first cauldron,
--        count = how many, line = the way the line runs (north/east/south/west),
--        walkway = the side of the line with a free walkway for the turtle
--        e.g. fuel cauldrons 100 64 200 8 east south
--   fuel lake <x> <y> <z> [radius]      a lava lake: x y z = a lava block on its surface
-- Where the lava goes:
--   fuel add <name> <x> <y> <z> [keep]  a chest at x y z; it keeps 'keep' full buckets in
--                                       it (default 4). It drops them in from ABOVE, so
--                                       leave the block on top of the chest free.
--   fuel remove <name>     fuel list     fuel clear (forget all lava sources)
-- Then:
--   fuel            run (starts by itself on boot after setup). Keys: P pause, H home, Q quit
--   fuel home       after putting it back on its home spot by hand: reset position
-- The pocket panel's Bots tab can add chests and sources too, and has a Run now button.

local lib = dofile("botlib.lua")
local CFG_FILE = "fuel.cfg"
local WAIT_MIN = 10   -- minutes between rounds (a dripstone cauldron fills in about that time)
local CARRY = 6       -- full buckets it carries around for deliveries
local BUCKETS = 10    -- empty buckets it takes along to fill
local LAKE_DEPTH = 3  -- layers of a lake it goes down when the top is used up

local args = { ... }
if args[1] == "update" then lib.update() return end
local LAVA, BUCKET = "minecraft:lava_bucket", "minecraft:bucket"
local function isLava(d) return d.name == LAVA end
local function isBucket(d) return d.name == BUCKET end

-- Commands that change the lists (from the shell, or the pocket panel). Returns a message.
local function configure(cfg, w)
  local cmd = (w[1] or ""):lower()
  local function num(i) return tonumber(w[i]) end
  cfg.sources, cfg.drops = cfg.sources or {}, cfg.drops or {}
  if cmd == "cauldrons" then
    local line, walk = lib.DIRS[(w[6] or ""):lower()], lib.DIRS[(w[7] or ""):lower()]
    if not (num(2) and num(3) and num(4) and num(5) and line and walk) or line % 2 == walk % 2 then
      return "cauldrons <x> <y> <z> <count> <line dir> <walkway side>, e.g. cauldrons 100 64 200 8 east south"
    end
    cfg.sources[#cfg.sources + 1] = { kind = "cauldrons", x = num(2), y = num(3), z = num(4), n = math.floor(num(5)),
      d = line, side = walk }
    return "Added " .. math.floor(num(5)) .. " cauldrons at " .. num(2) .. " " .. num(3) .. " " .. num(4)
  elseif cmd == "lake" then
    if not (num(2) and num(3) and num(4)) then return "lake <x> <y> <z> [radius]  (a lava block on the surface)" end
    cfg.sources[#cfg.sources + 1] = { kind = "lake", x = num(2), y = num(3), z = num(4), r = math.floor(num(5) or 8) }
    return "Added a lava lake at " .. num(2) .. " " .. num(3) .. " " .. num(4)
  elseif cmd == "add" then
    local name = w[2]
    if not (name and num(3) and num(4) and num(5)) then return "add <name> <x> <y> <z> [keep]" end
    for k = #cfg.drops, 1, -1 do if cfg.drops[k].name == name then table.remove(cfg.drops, k) end end
    cfg.drops[#cfg.drops + 1] = { name = name, x = num(3), y = num(4), z = num(5), keep = math.floor(num(6) or 4) }
    return "Delivering to " .. name .. " (" .. math.floor(num(6) or 4) .. " buckets)"
  elseif cmd == "remove" then
    for k = #cfg.drops, 1, -1 do
      if cfg.drops[k].name == w[2] then table.remove(cfg.drops, k) return "Removed " .. w[2] end
    end
    return "No chest called " .. tostring(w[2])
  elseif cmd == "clear" then
    cfg.sources = {}
    return "Forgot all lava sources"
  elseif cmd == "list" then
    local l = {}
    for _, s in ipairs(cfg.sources) do
      l[#l + 1] = s.kind == "lake" and ("lake " .. s.x .. " " .. s.y .. " " .. s.z)
        or (s.n .. " cauldrons " .. s.x .. " " .. s.y .. " " .. s.z)
    end
    for _, d in ipairs(cfg.drops) do l[#l + 1] = d.name .. " " .. d.x .. " " .. d.y .. " " .. d.z .. " keep " .. d.keep end
    return #l > 0 and table.concat(l, "\n") or "Nothing yet: add cauldrons, a lake and chests"
  end
  return nil
end

if args[1] == "setup" then
  if not turtle then error("fuel.lua only runs on a turtle", 0) end
  local home, msg = lib.parsePlace(args, 2)
  if not home then
    print(msg)
    print("Usage: fuel setup <x> <y> <z> <facing>")
    return
  end
  local chest
  local ok, info = turtle.inspectDown()
  if ok and lib.isChest(info) then chest = lib.DOWN end
  for k = 0, 3 do -- all the way round, so it ends up facing the way it started
    local ok2, info2 = turtle.inspect()
    if not chest and ok2 and lib.isChest(info2) then chest = (home.f + k) % 4 end
    turtle.turnRight()
  end
  local old = lib.loadTable(CFG_FILE) or {}
  lib.saveTable(CFG_FILE, { home = home, chest = chest or (home.f + 2) % 4, sources = old.sources or {}, drops = old.drops or {} })
  if fs.exists("fuel.state") then fs.delete("fuel.state") end
  lib.startup("fuel")
  os.setComputerLabel(os.getComputerLabel() or "Fuel runner")
  if not chest then print("WARNING: no chest found next to the turtle!") end
  print("Saved. Now tell it where lava comes from and where it goes:")
  print("  fuel cauldrons ...   fuel lake ...   fuel add ...")
  print("Then start with: fuel   (or reboot the turtle)")
  return
end

if not turtle then error("fuel.lua only runs on a turtle", 0) end
local cfg = lib.loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: fuel setup <x> <y> <z> <facing>")
  return
end

if args[1] == "home" then
  local s0 = lib.loadTable("fuel.state") or {}
  s0.pos = { x = cfg.home.x, y = cfg.home.y, z = cfg.home.z }
  s0.h, s0.pending = cfg.home.f, nil
  lib.saveTable("fuel.state", s0)
  print("Position reset to the home spot. Start with: fuel")
  return
end

if args[1] then
  local words = { table.unpack(args) }
  local msg = configure(cfg, words)
  if not msg then
    print("Commands: cauldrons, lake, add, remove, list, clear, home, setup, update")
    return
  end
  lib.saveTable(CFG_FILE, cfg)
  print(msg)
  return
end

local B = lib.bot("fuel", cfg, { title = "FUEL RUNNER", color = colors.orange, fuelTo = 3000, minFuel = 200 })
local st, pos = B.st, B.pos
st.collected = st.collected or 0 -- buckets filled, all time
st.delivered = st.delivered or 0 -- buckets delivered, all time
st.short = st.short or {}        -- chest name -> buckets it was short at the last visit
st.dry = st.dry or {}            -- source index -> rounds in a row it gave nothing

---------------------------------------------------------------------------
-- Filling buckets
---------------------------------------------------------------------------
local function canFill() return B.findSlot(isBucket) ~= nil and B.freeSlots() > 0 end

-- Use an empty bucket on side d (a lava cauldron or a lava source block)
local function fill(d)
  local s = B.findSlot(isBucket)
  if not s then return false end
  local before = B.count(isLava)
  B.place(d, s)
  if B.count(isLava) > before then
    st.collected = st.collected + 1
    return true
  end
  return false
end

local function cauldrons(src)
  local got = 0
  for k = 0, src.n - 1 do
    if not canFill() or B.stopAsked() then break end
    if not B.fuelFor(src.n * 2 + 20) then break end
    local cx, cz = src.x + lib.DX[src.d] * k, src.z + lib.DZ[src.d] * k
    local ok = pcall(B.goTo, cx + lib.DX[src.side], src.y, cz + lib.DZ[src.side])
    if ok then
      local look = lib.OPP[src.side]
      local info = B.inspect(look)
      if info and info.name == "minecraft:lava_cauldron" and fill(look) then got = got + 1 end
    end
  end
  return got
end

-- Square spiral of cells around 0,0 out to radius r
local function spiral(r)
  local cells = { { 0, 0 } }
  for ring = 1, r do
    for i = -ring, ring do cells[#cells + 1] = { i, -ring } end
    for i = -ring + 1, ring do cells[#cells + 1] = { ring, i } end
    for i = ring - 1, -ring, -1 do cells[#cells + 1] = { i, ring } end
    for i = ring - 1, -ring + 1, -1 do cells[#cells + 1] = { -ring, i } end
  end
  return cells
end

local function isSource(info)
  return info and info.name == "minecraft:lava" and (not info.state or (info.state.level or 0) == 0)
end

-- Fly over the lake one block above the lava and scoop up source blocks; when the top
-- layer is used up, the layers under it (turtles don't mind lava)
local function lake(src)
  local got = 0
  local cells = spiral(src.r or 8)
  for layer = 0, LAKE_DEPTH - 1 do
    local y = src.y + 1 - layer
    local found = false
    for _, c in ipairs(cells) do
      if not canFill() or B.stopAsked() then return got end
      if not B.fuelFor(40) then return got end
      local ok = pcall(B.goTo, src.x + c[1], y, src.z + c[2])
      if ok then
        local info = B.inspect(lib.DOWN)
        if isSource(info) then
          found = true
          if fill(lib.DOWN) then got = got + 1 end
        end
      end
    end
    if found then break end -- that layer had lava: next round starts at the top again
  end
  return got
end

---------------------------------------------------------------------------
-- Delivering
---------------------------------------------------------------------------
local function deliver(drop)
  if B.count(isLava) == 0 and B.freeSlots() == 0 then return end
  if not B.fuelFor(math.abs(drop.x - pos.x) + math.abs(drop.z - pos.z) + 40) then return end
  B.setStatus("Bringing lava to " .. drop.name)
  B.goTo(drop.x, drop.y + 1, drop.z)
  local have = B.chestCount(lib.DOWN, isLava)
  if not have then error("No chest under " .. drop.name .. " at " .. B.at(), 0) end
  local short = math.max(0, drop.keep - have)
  for s = 1, 16 do
    if short == 0 then break end
    local d = turtle.getItemDetail(s)
    if d and isLava(d) then
      turtle.select(s)
      if turtle.dropDown(1) then
        short = short - 1
        st.delivered = st.delivered + 1
      else
        break -- chest full
      end
    end
  end
  turtle.select(1)
  st.short[drop.name] = short
  -- the empty buckets the bot in that chest left behind
  if B.freeSlots() > 1 then B.take(lib.DOWN, isBucket, 16) end
  B.save()
end

---------------------------------------------------------------------------
-- A round: fill buckets, deliver, home
---------------------------------------------------------------------------
local function trip()
  if #cfg.sources == 0 and #cfg.drops == 0 then
    B.setStatus("Nothing to do yet: tell me where lava is (fuel cauldrons / fuel lake)")
    return
  end
  -- deliveries first if it already carries lava, then fetch more
  for _, drop in ipairs(cfg.drops) do
    if B.stopAsked() then return end
    if B.count(isLava) > 0 and (st.short[drop.name] == nil or st.short[drop.name] > 0 or drop.keep > 0) then
      local ok, err = pcall(deliver, drop)
      if not ok then
        if err == "Terminated" then error(err, 0) end
        B.logError(drop.name .. ": " .. tostring(err))
      end
    end
  end
  for k, src in ipairs(cfg.sources) do
    if not canFill() or B.stopAsked() then break end
    B.setStatus(src.kind == "lake" and "Scooping lava from the lake" or "Filling buckets at the cauldrons")
    local ok, got = pcall(src.kind == "lake" and lake or cauldrons, src)
    if not ok then
      if got == "Terminated" then error(got, 0) end
      B.logError("Lava source " .. k .. ": " .. tostring(got))
      got = 0
    end
    st.dry[k] = got > 0 and 0 or (st.dry[k] or 0) + 1
  end
  -- second delivery pass with the fresh lava, to chests still short
  for _, drop in ipairs(cfg.drops) do
    if B.stopAsked() then return end
    if B.count(isLava) > 0 and (st.short[drop.name] or 1) > 0 then
      local ok, err = pcall(deliver, drop)
      if not ok then
        if err == "Terminated" then error(err, 0) end
        B.logError(drop.name .. ": " .. tostring(err))
      end
    end
  end
  B.save()
end

-- At home: spare lava into the depot (it keeps CARRY), empty buckets out of it
local function service()
  B.setStatus("At the depot")
  B.burn(B.fuelTo) -- drinks a bucket of its own lava when low
  local ok = B.unload(cfg.chest, function(d)
    if isLava(d) then return CARRY end
    if isBucket(d) then return BUCKETS end
    return 0
  end)
  if not ok then B.setStatus("Depot chest full!") sleep(5) end
  local lava = B.count(isLava)
  if lava < CARRY then B.take(cfg.chest, isLava, CARRY - lava) end
  local empty = B.count(isBucket)
  if empty < BUCKETS then B.take(cfg.chest, isBucket, BUCKETS - empty) end
  st.depot = B.chestCount(cfg.chest, isLava)
  B.face(cfg.home.f)
  B.save()
end

B.lines = function()
  local short = 0
  for _, n in pairs(st.short) do short = short + n end
  return {
    { "Lava", B.count(isLava) }, { "Buckets", B.count(isBucket) },
    { "Depot", st.depot or "?" }, { "Short", short },
    { "Filled", B.fmt(st.collected) }, { "Delivered", B.fmt(st.delivered) },
    { "Sources", #cfg.sources }, { "Chests", #cfg.drops },
  }
end
B.actions = {
  { label = "Run now", cmd = "now" },
  { label = "Add chest", cmd = "config", ask = "add <name> <x> <y> <z> [keep]", prefix = "add" },
  { label = "Add lake", cmd = "config", ask = "lake <x> <y> <z> [radius]", prefix = "lake" },
  { label = "Add cauldrons", cmd = "config", ask = "cauldrons <x> <y> <z> <count> <line> <walkway>", prefix = "cauldrons" },
  { label = "List", cmd = "config", arg = "list" },
}
B.onCommand = function(m)
  if m.cmd == "now" then B.wakeUp() return "Going round now" end
  if m.cmd == "config" then
    local words = {}
    for wd in tostring(m.arg or ""):gmatch("%S+") do words[#words + 1] = wd end
    local msg = configure(cfg, words) or "Commands: add, remove, lake, cauldrons, clear, list"
    lib.saveTable(CFG_FILE, cfg)
    return msg
  end
  return "Unknown command " .. tostring(m.cmd)
end

B.run({ service = service, trip = trip, wait = WAIT_MIN * 60, idleText = "Waiting for lava to drip" })
