-- builder.lua - building turtle: clears land, lays floors and walls, bores tunnels (CC: Tweaked)
--
-- A mining turtle (pickaxe) with a chest next to it. Give it jobs with world coordinates
-- (F3); it works through them one by one and comes home to unload, refuel and get blocks.
--
-- One-time setup:
--   builder setup <x> <y> <z> <facing>   where the turtle is (with GPS hosts: builder setup)
-- Jobs (type them on the turtle after pressing Q, or use the pocket panel's Bots tab):
--   builder clear <x1> <y1> <z1> <x2> <y2> <z2>      dig out everything in that box
--   builder flatten <x1> <z1> <x2> <z2> <y> [height] clear everything above height y
--                                                    (default 16 up) and fill holes at y
--   builder floor <x1> <z1> <x2> <z2> <y> [block]     lay a floor at height y
--   builder walls <x1> <z1> <x2> <z2> <y> <height> [block]  walls round that rectangle
--   builder tunnel <x> <y> <z> <dir> <length> [width] [height]
--        a lit tunnel (default 3x3): x y z = the floor-level middle of its mouth (the
--        block you'd stand in, open from above), dir = north/east/south/west. It fills
--        gaps in the floor (bridges), seals lava, water and cave openings in the walls
--        and ceiling, and puts a torch down every 8 blocks.
--   builder list      builder cancel (drop the current job)      builder clearall
-- Then:
--   builder           run (starts by itself on boot after setup). Keys: P pause, H home, Q quit
--   builder home      after putting it back on its home spot by hand: reset position
--
-- Blocks: it uses cobblestone, dirt, deepslate, netherrack and the like (what it digs up
-- is fine) unless a job names a block, e.g. "builder floor 0 0 9 9 63 stone_bricks".
-- Put blocks, torches and fuel (lava buckets / coal) in its chest. Order them from the
-- storage room and drop them in. It never digs chests, furnaces, computers, beds or doors.

local lib = dofile("botlib.lua")
local CFG_FILE = "builder.cfg"
local TORCH_EVERY = 8     -- tunnel: a torch every this many blocks
local KEEP_FILLER = 192   -- filler blocks it keeps on board; more gets thrown away while digging
local FILLER = {
  "minecraft:cobblestone", "minecraft:cobbled_deepslate", "minecraft:dirt", "minecraft:stone", "minecraft:netherrack",
  "minecraft:andesite", "minecraft:diorite", "minecraft:granite", "minecraft:tuff", "minecraft:deepslate",
  "minecraft:blackstone", "minecraft:basalt", "minecraft:sandstone", "minecraft:end_stone", "minecraft:calcite",
}
local JUNK = { ["minecraft:gravel"] = true, ["minecraft:flint"] = false }
local TORCH = "minecraft:torch"

local args = { ... }
if args[1] == "update" then lib.update() return end

local function isFiller(d)
  for _, f in ipairs(FILLER) do if d.name == f then return true end end
  return false
end

---------------------------------------------------------------------------
-- Jobs: parsing
---------------------------------------------------------------------------
local function blockName(s)
  if not s then return nil end
  s = s:lower()
  if not s:find(":") then s = "minecraft:" .. s end
  return s
end

-- words -> job table, or nil and a usage line
local function parseJob(w)
  local kind = (w[1] or ""):lower()
  local n = {}
  for i = 2, 9 do n[i] = tonumber(w[i]) end
  local function all(a, b)
    for i = a, b do if not n[i] then return false end end
    return true
  end
  if kind == "clear" then
    if not all(2, 7) then return nil, "clear <x1> <y1> <z1> <x2> <y2> <z2>" end
    return { kind = "clear", x1 = n[2], y1 = n[3], z1 = n[4], x2 = n[5], y2 = n[6], z2 = n[7] }
  elseif kind == "flatten" then
    if not all(2, 6) then return nil, "flatten <x1> <z1> <x2> <z2> <y> [height]" end
    return { kind = "flatten", x1 = n[2], z1 = n[3], x2 = n[4], z2 = n[5], y = n[6], h = math.max(1, math.floor(n[7] or 16)) }
  elseif kind == "floor" then
    if not all(2, 6) then return nil, "floor <x1> <z1> <x2> <z2> <y> [block]" end
    return { kind = "floor", x1 = n[2], z1 = n[3], x2 = n[4], z2 = n[5], y = n[6], block = blockName(w[7]) }
  elseif kind == "walls" then
    if not all(2, 7) then return nil, "walls <x1> <z1> <x2> <z2> <y> <height> [block]" end
    return { kind = "walls", x1 = n[2], z1 = n[3], x2 = n[4], z2 = n[5], y = n[6], h = math.max(1, math.floor(n[7])),
      block = blockName(w[8]) }
  elseif kind == "tunnel" then
    local d = lib.DIRS[(w[5] or ""):lower()]
    if not (all(2, 4) and d and n[6]) then return nil, "tunnel <x> <y> <z> <north|east|south|west> <length> [width] [height]" end
    return { kind = "tunnel", x = n[2], y = n[3], z = n[4], d = d, len = math.max(1, math.floor(n[6])),
      w = math.max(1, math.floor(n[7] or 3)), h = math.max(1, math.floor(n[8] or 3)) }
  end
  return nil, "Jobs: clear, flatten, floor, walls, tunnel"
end

local function describe(j)
  if j.kind == "tunnel" then
    return ("tunnel %d long %s from %d %d %d"):format(j.len, lib.DIRNAME[j.d], j.x, j.y, j.z)
  elseif j.kind == "clear" then
    return ("clear %d %d %d to %d %d %d"):format(j.x1, j.y1, j.z1, j.x2, j.y2, j.z2)
  end
  return ("%s %d %d to %d %d at y %d"):format(j.kind, j.x1, j.z1, j.x2, j.z2, j.y)
end

---------------------------------------------------------------------------
-- Setup and shell commands
---------------------------------------------------------------------------
if args[1] == "setup" then
  if not turtle then error("builder.lua only runs on a turtle", 0) end
  local home, msg = lib.parsePlace(args, 2)
  if not home then
    print(msg)
    print("Usage: builder setup <x> <y> <z> <facing>")
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
  lib.saveTable(CFG_FILE, { home = home, chest = chest or (home.f + 2) % 4 })
  local s0 = lib.loadTable("builder.state") or {}
  lib.saveTable("builder.state", { jobs = s0.jobs or {}, job = s0.job, done = s0.done })
  lib.startup("builder")
  os.setComputerLabel(os.getComputerLabel() or "Builder")
  if not chest then print("WARNING: no chest found next to the turtle!") end
  print("Saved. Give it a job, e.g. builder tunnel 100 64 200 east 50")
  print("Then start with: builder   (or reboot the turtle)")
  return
end

if not turtle then error("builder.lua only runs on a turtle", 0) end
local cfg = lib.loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: builder setup <x> <y> <z> <facing>")
  return
end

-- Queue commands from the shell (while the builder isn't running)
local function queueCommand(st, w)
  local cmd = (w[1] or ""):lower()
  st.jobs = st.jobs or {}
  if cmd == "list" then
    local l = {}
    if st.job then l[#l + 1] = "Now: " .. describe(st.job) .. " (" .. (st.job.i or 1) .. "/" .. (st.job.total or "?") .. ")" end
    for k, j in ipairs(st.jobs) do l[#l + 1] = k .. ". " .. describe(j) end
    return #l > 0 and table.concat(l, "\n") or "No jobs"
  elseif cmd == "cancel" then
    if not st.job then return "No job running" end
    local d = describe(st.job)
    st.job = nil
    return "Cancelled: " .. d
  elseif cmd == "clearall" then
    st.jobs, st.job = {}, nil
    return "All jobs dropped"
  end
  local job, err = parseJob(w)
  if not job then return err end
  st.jobs[#st.jobs + 1] = job
  return "Queued: " .. describe(job)
end

if args[1] == "home" then
  local s0 = lib.loadTable("builder.state") or {}
  s0.pos = { x = cfg.home.x, y = cfg.home.y, z = cfg.home.z }
  s0.h, s0.pending = cfg.home.f, nil
  lib.saveTable("builder.state", s0)
  print("Position reset to the home spot. Start with: builder")
  return
end
if args[1] then
  local s0 = lib.loadTable("builder.state") or {}
  print(queueCommand(s0, { table.unpack(args) }))
  lib.saveTable("builder.state", s0)
  return
end

local B = lib.bot("builder", cfg, { title = "BUILDER", color = colors.brown })
local st, pos = B.st, B.pos
st.jobs = st.jobs or {}
st.done = st.done or 0
st.dug = st.dug or 0
st.placed = st.placed or 0
local UP, DOWN = lib.UP, lib.DOWN

---------------------------------------------------------------------------
-- Jobs: the steps. Each step is a spot for the turtle and what to do there.
---------------------------------------------------------------------------
local function range(a, b) if a <= b then return a, b end return b, a end

-- Columns of a rectangle in rows going back and forth
local function serpentine(x1, z1, x2, z2, flip)
  x1, x2 = range(x1, x2)
  z1, z2 = range(z1, z2)
  local l = {}
  local row = 0
  for z = z1, z2 do
    local a, b, s = x1, x2, 1
    if row % 2 == 1 then a, b, s = x2, x1, -1 end
    for x = a, b, s do l[#l + 1] = { x, z } end
    row = row + 1
  end
  if flip then
    local r = {}
    for k = #l, 1, -1 do r[#r + 1] = l[k] end
    return r
  end
  return l
end

-- Dig out a box: bands of 3 layers, top down. The turtle goes through the middle
-- layer and digs the layers above and under it.
local function clearSteps(steps, x1, y1, z1, x2, y2, z2)
  local ybot, ytop = range(y1, y2)
  local y, band = ytop, 0
  while y >= ybot do
    local mid = math.max(y - 1, ybot)
    for _, c in ipairs(serpentine(x1, z1, x2, z2, band % 2 == 1)) do
      steps[#steps + 1] = { x = c[1], y = mid, z = c[2], up = mid + 1 <= y, down = mid - 1 >= ybot and mid - 1 >= y - 2 }
    end
    y, band = y - 3, band + 1
  end
end

-- Lay blocks at height y on these columns (the turtle flies one above and places down)
local function layerSteps(steps, cols, y)
  for _, c in ipairs(cols) do steps[#steps + 1] = { x = c[1], y = y + 1, z = c[2], put = DOWN } end
end

local function perimeter(x1, z1, x2, z2)
  x1, x2 = range(x1, x2)
  z1, z2 = range(z1, z2)
  local l = {}
  for x = x1, x2 do l[#l + 1] = { x, z1 } end
  for z = z1 + 1, z2 do l[#l + 1] = { x2, z } end
  if z2 > z1 then for x = x2 - 1, x1, -1 do l[#l + 1] = { x, z2 } end end
  if x2 > x1 then for z = z2 - 1, z1 + 1, -1 do l[#l + 1] = { x1, z } end end
  return l
end

-- Tunnel: slice by slice; in a slice, column by column, up and down, so every next
-- spot is next to the last one. Edge spots seal the floor, walls and ceiling.
local function tunnelSteps(steps, j)
  local right, left = (j.d + 1) % 4, (j.d + 3) % 4
  local lo = -math.floor((j.w - 1) / 2)
  local hi = lo + j.w - 1
  local goingUp, leftToRight = true, true
  for k = 0, j.len - 1 do
    local bx, bz = j.x + lib.DX[j.d] * k, j.z + lib.DZ[j.d] * k
    local c1, c2, cs = lo, hi, 1
    if not leftToRight then c1, c2, cs = hi, lo, -1 end
    for c = c1, c2, cs do
      local r1, r2, rs = 0, j.h - 1, 1
      if not goingUp then r1, r2, rs = j.h - 1, 0, -1 end
      for r = r1, r2, rs do
        steps[#steps + 1] = { x = bx + lib.DX[right] * c, y = j.y + r, z = bz + lib.DZ[right] * c, tunnel = true,
          floor = r == 0, ceil = r == j.h - 1, sideL = c == lo and left or nil, sideR = c == hi and right or nil }
      end
      goingUp = not goingUp
    end
    leftToRight = not leftToRight
    if k % TORCH_EVERY == 0 and j.h >= 2 then
      steps[#steps + 1] = { x = bx + lib.DX[right] * lo, y = j.y + 1, z = bz + lib.DZ[right] * lo, torch = true }
    end
  end
end

local function stepsOf(j)
  local steps = {}
  if j.kind == "clear" then
    clearSteps(steps, j.x1, j.y1, j.z1, j.x2, j.y2, j.z2)
  elseif j.kind == "flatten" then
    clearSteps(steps, j.x1, j.y + 1, j.z1, j.x2, j.y + j.h, j.z2)
    layerSteps(steps, serpentine(j.x1, j.z1, j.x2, j.z2, false), j.y)
  elseif j.kind == "floor" then
    layerSteps(steps, serpentine(j.x1, j.z1, j.x2, j.z2, false), j.y)
  elseif j.kind == "walls" then
    local p = perimeter(j.x1, j.z1, j.x2, j.z2)
    for k = 0, j.h - 1 do layerSteps(steps, p, j.y + k) end
  elseif j.kind == "tunnel" then
    tunnelSteps(steps, j)
  end
  return steps
end

---------------------------------------------------------------------------
-- Doing the steps
---------------------------------------------------------------------------
local function blockTest(j)
  if j and j.block then return function(d) return d.name == j.block end end
  return isFiller
end

local NEED = "__need_blocks"

-- Put a block on side d if there's air, liquid or a plant there. Solid blocks stay.
local function putBlock(d, j)
  local info = B.inspect(d)
  local c = lib.classify(info)
  if c == "solid" then return end
  if c == "soft" then B.dig(d) end
  local s = B.findSlot(blockTest(j))
  if not s then error(NEED, 0) end
  if B.place(d, s) then st.placed = st.placed + 1 end
end

local function digSide(d)
  local info = B.inspect(d)
  local c = lib.classify(info)
  if (c == "solid" or c == "soft") and not lib.isProtected(info) then
    for _ = 1, 10 do -- gravel and sand keep falling in
      if not B.dig(d) then break end
      st.dug = st.dug + 1
      sleep(0.2)
      if lib.classify(B.inspect(d)) ~= "solid" then break end
    end
  end
end

-- Step into side d inside the job. Lava or water there gets a block put in and dug out
-- again, so the tunnel ends up dry.
local function enter(d, j)
  local info = B.inspect(d)
  if lib.isLiquid(info) and B.findSlot(blockTest(nil)) then
    B.place(d, B.findSlot(blockTest(nil)))
  end
  if lib.classify(B.inspect(d)) ~= "air" then st.dug = st.dug + 1 end
  if not B.step(d, "dig") then error("Blocked at " .. B.at() .. " (" .. tostring((B.inspect(d) or {}).name) .. ")", 0) end
end

-- Walk to a nearby spot through the job area: sideways first, then up or down
local function walkTo(x, y, z, j)
  while pos.x ~= x do enter(pos.x < x and 1 or 3, j) end
  while pos.z ~= z do enter(pos.z < z and 2 or 0, j) end
  while pos.y ~= y do enter(pos.y < y and UP or DOWN, j) end
end

local function near(s) return math.abs(pos.x - s.x) + math.abs(pos.y - s.y) + math.abs(pos.z - s.z) end

-- Get to a step from wherever the turtle is: walk when close, else fly over. Into a
-- tunnel it goes through the mouth and along the middle.
local function reach(s, j)
  if near(s) <= 6 then walkTo(s.x, s.y, s.z, j) return end
  if j.kind == "tunnel" then
    local ax, az = lib.DX[j.d], lib.DZ[j.d]
    local function along(x, z) return (x - j.x) * ax + (z - j.z) * az end
    -- not in the tunnel yet: fly to the mouth
    local side = (pos.x - j.x) * lib.DX[(j.d + 1) % 4] + (pos.z - j.z) * lib.DZ[(j.d + 1) % 4]
    local inside = along(pos.x, pos.z) >= 0 and along(pos.x, pos.z) < j.len and math.abs(side) < j.w
      and pos.y >= j.y and pos.y < j.y + j.h
    if not inside then B.goTo(j.x, j.y, j.z) end
    -- along the middle row to the slice
    walkTo(pos.x, j.y, pos.z, j)
    local k = along(s.x, s.z)
    walkTo(j.x + ax * k, j.y, j.z + az * k, j)
    walkTo(s.x, s.y, s.z, j)
    return
  end
  -- fly in over the top, then dig down into the area
  local top = s.y
  if j.kind == "clear" then top = math.max(j.y1, j.y2) + 1 elseif j.kind == "flatten" then top = j.y + j.h + 1 end
  B.flyTo(s.x, s.z, math.max(pos.y, top, s.y) + B.hop)
  while pos.y > top and pos.y > s.y do
    if not B.step(DOWN) then break end
  end
  walkTo(s.x, s.y, s.z, j)
end

local function doStep(s, j)
  reach(s, j)
  if s.up then digSide(UP) end
  if s.down then digSide(DOWN) end
  if s.put then putBlock(s.put, j) end
  if s.tunnel then
    if s.floor then putBlock(DOWN, j) end
    if s.ceil then putBlock(UP, j) end
    if s.sideL then putBlock(s.sideL, j) end
    if s.sideR then putBlock(s.sideR, j) end
  end
  if s.torch then
    local t = B.findSlot(function(d) return d.name == TORCH end)
    if t and B.inspect(DOWN) == nil then B.place(DOWN, t) end
  end
end

-- Inventory nearly full: throw away gravel and spare filler (it digs plenty)
local function makeRoom()
  if B.freeSlots() >= 2 then return end
  local filler = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then
      if JUNK[d.name] then
        turtle.select(s) turtle.dropUp()
      elseif isFiller(d) then
        filler = filler + d.count
        if filler > KEEP_FILLER then turtle.select(s) turtle.dropUp() end
      end
    end
  end
  turtle.select(1)
end

local function trip()
  if not st.job then
    if #st.jobs == 0 then return end
    st.job = table.remove(st.jobs, 1)
    st.job.i = 1
    B.save()
  end
  local j = st.job
  local steps = stepsOf(j)
  j.total = #steps
  B.setStatus("Job: " .. describe(j))
  local fails = 0
  while j.i <= #steps do
    if B.stopAsked() or st.job ~= j then return end -- paused, or the job was cancelled
    if not B.fuelFor(40) then return "fuel" end
    makeRoom()
    if B.freeSlots() == 0 then return "again" end -- full of things worth keeping: unload
    local ok, err = pcall(doStep, steps[j.i], j)
    if not ok then
      if err == "Terminated" then error(err, 0) end
      if err == NEED then
        st.needBlocks = true
        B.setStatus("Out of blocks: getting more")
        return "again"
      end
      -- a chest or a computer in the way, or something it can't get past: skip that spot
      B.logError(err)
      fails = fails + 1
      if fails >= 8 then
        st.job = nil
        B.save()
        error("Too many spots it can't reach, stopped the job here: " .. tostring(err), 0) end
    else
      fails = 0
    end
    j.i = j.i + 1
    if j.i % 10 == 0 then B.save() end
  end
  B.setStatus("Done: " .. describe(j))
  st.job = nil
  st.done = st.done + 1
  B.save()
  return #st.jobs > 0 and "again" or nil
end

-- Home again. From inside a tunnel: along the middle row out of the mouth first.
local booted = false
local function recover()
  if not booted then
    booted = true
    if st.job and not st.paused then return end -- just rebooted mid-job: carry on from here
  end
  local j = st.job
  if j and j.kind == "tunnel" and not B.atHome() then
    local ax, az = lib.DX[j.d], lib.DZ[j.d]
    local k = (pos.x - j.x) * ax + (pos.z - j.z) * az
    if k >= 0 and k < j.len and pos.y >= j.y and pos.y < j.y + j.h then
      pcall(function()
        walkTo(j.x + ax * k, j.y, j.z + az * k, j)
        walkTo(j.x, j.y, j.z, j)
      end)
    end
  end
  B.goHome()
end

local function service()
  B.setStatus("Unloading")
  B.refuelFrom(cfg.chest)
  local j = st.job or st.jobs[1]
  local want = blockTest(j)
  while not B.unload(cfg.chest, function(d)
    if d.name == TORCH then return 64 end
    if want(d) then return KEEP_FILLER end
    return 0
  end) do
    B.setStatus("Chest full! Empty it and I'll carry on")
    sleep(30)
  end
  if j then
    local have = B.count(want)
    if have < 128 then B.take(cfg.chest, want, 192 - have) end
    if j.kind == "tunnel" and B.count(function(d) return d.name == TORCH end) < 16 then
      B.take(cfg.chest, function(d) return d.name == TORCH end, 64)
    end
    if st.needBlocks and B.count(want) == 0 then
      B.setStatus("Need blocks: put " .. (j.block and j.block:match(":(.+)$") or "cobblestone") .. " in my chest")
      sleep(30)
    else
      st.needBlocks = nil
    end
  end
  B.face(cfg.home.f)
  B.save()
end

B.lines = function()
  local j = st.job
  local l = {
    { "Job", j and (j.kind .. " " .. math.floor(100 * ((j.i or 1) - 1) / math.max(1, j.total or 1)) .. "%") or "none" },
    { "Queued", #st.jobs },
    { "Dug", B.fmt(st.dug) }, { "Placed", B.fmt(st.placed) },
    { "Blocks", B.count(blockTest(j)) }, { "Torches", B.count(function(d) return d.name == TORCH end) },
    { "Jobs done", st.done },
  }
  return l
end
B.actions = {
  { label = "Tunnel", cmd = "job", ask = "tunnel <x> <y> <z> <dir> <length> [w] [h]", prefix = "tunnel" },
  { label = "Flatten", cmd = "job", ask = "flatten <x1> <z1> <x2> <z2> <y> [height]", prefix = "flatten" },
  { label = "Floor", cmd = "job", ask = "floor <x1> <z1> <x2> <z2> <y> [block]", prefix = "floor" },
  { label = "Walls", cmd = "job", ask = "walls <x1> <z1> <x2> <z2> <y> <h> [block]", prefix = "walls" },
  { label = "Clear box", cmd = "job", ask = "clear <x1> <y1> <z1> <x2> <y2> <z2>", prefix = "clear" },
  { label = "Jobs", cmd = "job", arg = "list" },
  { label = "Cancel job", cmd = "job", arg = "cancel" },
}
B.onCommand = function(m)
  if m.cmd == "job" then
    local words = {}
    for wd in tostring(m.arg or ""):gmatch("%S+") do words[#words + 1] = wd end
    local msg = queueCommand(st, words)
    B.save()
    B.wakeUp()
    return msg
  end
  return "Unknown command " .. tostring(m.cmd)
end

B.run({ service = service, trip = trip, recover = recover, wait = 3600, idleText = "No jobs: waiting for one" })
