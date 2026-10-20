if fs and fs.exists("wh2-program.lua") and not rawget(_ENV,"__wh2Running") then
  if dofile("wh2-program.lua").run("sorter.lua",...) then return end
end
-- sorter.lua - Sorter & Smelter (CC: Tweaked)
-- Runs on a turtle or computer connected to a WIRED modem network of chests and
-- furnaces. It empties the input chests (e.g. the Mine Army chests), smelts raw
-- ores in all furnaces / blast furnaces on the network, keeps them fuelled, and
-- sorts everything into storage chests.
--
--   sorter setup     give every chest on the network a role (run this first)
--   sorter           start
--   sorter install   start automatically on boot
--   sorter list      show the chests, furnaces and their roles
--
-- While running, type at the > prompt:
--   get <item> [n]   put items in the pickup chest (e.g. "get iron ingot 32")
--   find <item>      how many are in storage
--   pause / resume, help, quit

local CFG_FILE = "sorter.cfg"
local STATS_FILE = "sorter.stats"
local LOG_FILE = "sorter.log"

local args = { ... }
if args[1]=="ssot" then shell.run("store",table.unpack(args,2)) return end
if args[1] == "update" then
  -- latest version from GitHub (update.lua does the work, fetched here if missing)
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
  end
  shell.run("update")
  return
end
if args[1] == "install" then
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("sorter")\n')
  h.close()
  print("Sorter will now start automatically on boot.")
  return
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local function loadTable(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local t = textutils.unserialize(h.readAll())
  h.close()
  return type(t) == "table" and t or nil
end

local function saveTable(path, t)
  local h = fs.open(path, "w")
  h.write(textutils.serialize(t))
  h.close()
end

local cfg = loadTable(CFG_FILE) or {}
if wh2 then wh2.bindConfig(cfg) end
cfg.roles = cfg.roles or {}        -- [peripheral name] = { role = "input"|"storage"|..., cat = "any"|... }
cfg.interval = cfg.interval or 3   -- seconds between rounds when there is nothing to do
cfg.queue = cfg.queue or 32        -- max items waiting in one furnace
-- Extra items to smelt (normal furnaces only), e.g. "minecraft:oak_log" for charcoal
cfg.extraSmelt = cfg.extraSmelt or {}
-- Smeltable items that should be stored as they are
cfg.noSmelt = cfg.noSmelt or {}
-- Left in the input chests: [item] = how many. The miners need their buckets.
cfg.leave = cfg.leave or {
  ["minecraft:bucket"] = 9999, ["minecraft:lava_bucket"] = 9999, ["minecraft:water_bucket"] = 9999,
}
-- Fuel, most preferred first
cfg.fuels = cfg.fuels or { "minecraft:charcoal", "minecraft:coal", "minecraft:coal_block",
  "minecraft:dried_kelp_block", "minecraft:lava_bucket" }
-- Also burn coal that ended up in storage (e.g. mined coal) when the fuel chest is empty
if cfg.useStorageFuel == nil then cfg.useStorageFuel = true end

local stats = loadTable(STATS_FILE) or {}
stats.smelted = stats.smelted or {} -- [output item] = count
stats.sorted = stats.sorted or 0
stats.since = stats.since or os.epoch("utc")
local statsDirty = false
local runStart = os.epoch("utc")
local runSmelted = 0

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
local BUCKET = "minecraft:bucket"
-- How many items one fuel item smelts in a normal furnace (blast furnace: half)
local FUEL_VALUE = {
  ["minecraft:coal"] = 8, ["minecraft:charcoal"] = 8, ["minecraft:coal_block"] = 80,
  ["minecraft:lava_bucket"] = 100, ["minecraft:dried_kelp_block"] = 20, ["minecraft:blaze_rod"] = 12,
}
local GEMS = { diamond = true, emerald = true, lapis_lazuli = true, redstone = true, quartz = true,
  amethyst_shard = true, glowstone_dust = true, prismarine_crystals = true }

local function short(name) return name:match(":(.+)$") or name end

local function pretty(name)
  local s = short(name):gsub("_", " ")
  return s:sub(1, 1):upper() .. s:sub(2)
end

local function listHas(list, name)
  for _, n in ipairs(list) do if n == name then return true end end
  return false
end

-- Ores and raw metals: smeltable in furnaces AND blast furnaces
local function isOreSmelt(name)
  if listHas(cfg.noSmelt, name) then return false end
  local n = short(name)
  if n:find("_block$") then return false end -- raw iron blocks etc. can't be smelted
  return n:find("^raw_") ~= nil or n:find("_ore$") ~= nil or n == "ancient_debris"
end

local function smeltKind(name)
  if wh2 and not wh2.allowed("smelting") then return nil end
  if isOreSmelt(name) then return "ore" end
  if listHas(cfg.extraSmelt, name) and not listHas(cfg.noSmelt, name) then return "extra" end
  return nil
end

local CATS = { "any", "ores", "ingots", "gems", "fuel", "misc" }
local function category(name)
  local n = short(name)
  if FUEL_VALUE[name] then return "fuel" end
  if n:find("_ingot$") or n:find("_nugget$") or n == "netherite_scrap" then return "ingots" end
  if n:find("^raw_") or n:find("_ore$") or n == "ancient_debris" then return "ores" end
  if GEMS[n] or n:find("_gem$") or n:find("_dust$") then return "gems" end
  return "misc"
end

---------------------------------------------------------------------------
-- Peripherals
---------------------------------------------------------------------------
local function isInventory(n)
  if peripheral.hasType then return peripheral.hasType(n, "inventory") end
  local m = peripheral.getMethods(n)
  if not m then return false end
  for _, x in ipairs(m) do if x == "pushItems" then return true end end
  return false
end

local function furnaceKind(n)
  local t = peripheral.getType(n)
  if type(t) ~= "string" then return nil end
  if t:find("blast_furnace") then return "blast" end
  if t:find("smoker") then return nil end -- smokers only do food
  if t:find("furnace") then return "furnace" end
  return nil
end

local sizes = {}
local function sizeOf(n)
  if not sizes[n] then
    local ok, s = pcall(peripheral.call, n, "size")
    sizes[n] = ok and s or 0
  end
  return sizes[n]
end

-- What is on the network right now, grouped by role
local net
local function scan()
  local r = { input = {}, storage = {}, overflow = {}, fuel = {}, pickup = {}, furnaces = {}, unassigned = 0 }
  for _, n in ipairs(peripheral.getNames()) do
    if isInventory(n) then
      local role = cfg.roles[n]
      local fk = furnaceKind(n)
      if role and role.role == "ignore" then
        -- skip
      elseif fk then
        r.furnaces[#r.furnaces + 1] = { name = n, kind = fk }
      elseif not role then
        r.unassigned = r.unassigned + 1
      elseif r[role.role] then
        local list = r[role.role]
        list[#list + 1] = { name = n, cat = role.cat or "any" }
      end
    end
  end
  for _, l in pairs(r) do
    if type(l) == "table" then table.sort(l, function(a, b) return a.name < b.name end) end
  end
  net = r
  return r
end

-- list() of many inventories at once (each call takes a game tick, so in parallel)
local function listAll(names)
  local res, fns = {}, {}
  for _, n in ipairs(names) do
    fns[#fns + 1] = function()
      local ok, l = pcall(peripheral.call, n, "list")
      res[n] = ok and l or nil
    end
  end
  for i = 1, #fns, 128 do
    parallel.waitForAll(table.unpack(fns, i, math.min(i + 127, #fns)))
  end
  return res
end

---------------------------------------------------------------------------
-- Log
---------------------------------------------------------------------------
local logLines = {}
local function log(msg, isError)
  table.insert(logLines, 1, { textutils.formatTime(os.time(), true) .. " " .. msg, isError })
  while #logLines > 20 do table.remove(logLines) end
  if isError then
    local h = fs.open(LOG_FILE, "a")
    if h then h.writeLine(os.date("%Y-%m-%d %H:%M ") .. msg) h.close() end
  end
  os.queueEvent("sorter_redraw")
end

---------------------------------------------------------------------------
-- Moving items
---------------------------------------------------------------------------
local lists = {} -- [inventory] = list(), kept up to date while moving
local has = {}   -- [inventory] = { [item] = true }
local noRoom = {} -- [inventory .. item] = true: it took none of that item this round

local function move(from, slot, to, n, toSlot)
  local ok, moved = pcall(peripheral.call, from, "pushItems", to, slot, n, toSlot)
  if not ok then
    log("Move " .. short(from) .. " > " .. short(to) .. ": " .. tostring(moved), true)
    return 0
  end
  moved = moved or 0
  local l = lists[from]
  if moved > 0 and l and l[slot] then
    l[slot].count = l[slot].count - moved
    if l[slot].count <= 0 then l[slot] = nil end
  end
  return moved
end

-- Where an item goes: chests of its category that already hold it, other chests
-- of its category, "any" chests that hold it, other "any" chests, overflow.
local function targetsFor(name)
  local cat = category(name)
  local catC, anyC = {}, {}
  if cat == "fuel" then for _, c in ipairs(net.fuel) do catC[#catC + 1] = c.name end end
  for _, c in ipairs(net.storage) do
    if c.cat == cat then catC[#catC + 1] = c.name
    elseif c.cat == "any" then anyC[#anyC + 1] = c.name end
  end
  local out = {}
  local function addHolding(l, holding)
    for _, n in ipairs(l) do
      if ((has[n] and has[n][name]) and true or false) == holding then out[#out + 1] = n end
    end
  end
  addHolding(catC, true) addHolding(catC, false)
  addHolding(anyC, true) addHolding(anyC, false)
  for _, c in ipairs(net.overflow) do out[#out + 1] = c.name end
  return out
end

local storageFull = false
local function store(from, slot, name, count)
  local left = count
  for _, to in ipairs(targetsFor(name)) do
    if left <= 0 then break end
    if to ~= from and not noRoom[to .. name] then
      local m = move(from, slot, to, left)
      if m > 0 then
        left = left - m
        has[to] = has[to] or {}
        has[to][name] = true
      else
        noRoom[to .. name] = true
      end
    end
  end
  if left > 0 then storageFull = true end
  return count - left
end

---------------------------------------------------------------------------
-- One round
---------------------------------------------------------------------------
local status = { furnaces = {}, toSmelt = 0, noFuel = false, used = 0, slots = 0, fuelItems = 0 }
local lastAction = "Starting"

-- Slots of an input chest and how much may be taken from each (cfg.leave stays)
local function takeable(l)
  local keep, out = {}, {}
  for slot, it in pairs(l) do
    if keep[it.name] == nil then keep[it.name] = cfg.leave[it.name] or 0 end
    local k = math.min(it.count, keep[it.name])
    keep[it.name] = keep[it.name] - k
    if it.count - k > 0 then out[#out + 1] = { slot = slot, name = it.name, n = it.count - k } end
  end
  table.sort(out, function(a, b) return a.slot < b.slot end)
  return out
end

-- 1. Take the smelted items (and empty lava buckets) out of the furnaces
local function collect()
  local moved = 0
  for _, f in ipairs(net.furnaces) do
    local l = lists[f.name]
    if l and l[3] then
      local name, n = l[3].name, l[3].count
      local m = store(f.name, 3, name, n)
      if m > 0 then
        moved = moved + m
        stats.smelted[name] = (stats.smelted[name] or 0) + m
        runSmelted = runSmelted + m
        statsDirty = true
        lastAction = "Smelted " .. m .. " " .. pretty(name)
      end
    end
    if l and l[2] and l[2].name == BUCKET then moved = moved + store(f.name, 2, BUCKET, l[2].count) end
  end
  return moved
end

-- 2. Fill the furnaces from the input chests, then from storage
local function feed()
  local furn = {}
  for _, f in ipairs(net.furnaces) do
    local l = lists[f.name]
    if l then
      furn[#furn + 1] = { name = f.name, blast = f.kind == "blast", input = l[1] and { name = l[1].name, count = l[1].count } }
    end
  end
  local sources = {}
  for _, c in ipairs(net.input) do
    for _, s in ipairs(takeable(lists[c.name] or {})) do sources[#sources + 1] = { chest = c.name, slot = s.slot, name = s.name, n = s.n } end
  end
  for _, c in ipairs(net.storage) do
    for slot, it in pairs(lists[c.name] or {}) do sources[#sources + 1] = { chest = c.name, slot = slot, name = it.name, n = it.count } end
  end
  for _, c in ipairs(net.overflow) do
    for slot, it in pairs(lists[c.name] or {}) do sources[#sources + 1] = { chest = c.name, slot = slot, name = it.name, n = it.count } end
  end

  local moved, waiting = 0, 0
  for _, s in ipairs(sources) do
    local kind = smeltKind(s.name)
    if kind then
      while s.n > 0 do
        -- The furnace with the shortest queue (a blast furnace is twice as fast)
        local best, bestScore
        for _, f in ipairs(furn) do
          if not f.full and (kind == "ore" or not f.blast) and (not f.input or f.input.name == s.name) then
            local c = f.input and f.input.count or 0
            if c < cfg.queue then
              local score = c / (f.blast and 2 or 1)
              if not bestScore or score < bestScore then best, bestScore = f, score end
            end
          end
        end
        if not best then break end
        local c = best.input and best.input.count or 0
        local m = move(s.chest, s.slot, best.name, math.min(8, s.n, cfg.queue - c), 1)
        if m == 0 then
          best.full = true
        else
          s.n = s.n - m
          moved = moved + m
          best.input = { name = s.name, count = c + m }
        end
      end
      waiting = waiting + s.n
    end
  end
  status.toSmelt = waiting
  -- keep the queues for fuel()
  for _, f in ipairs(furn) do
    local l = lists[f.name]
    if l then l[1] = f.input and { name = f.input.name, count = f.input.count } or nil end
  end
  return moved
end

-- 3. Fuel: enough in each furnace for what is waiting in it
local function fuelSources(name)
  local out = {}
  local function add(chests)
    for _, c in ipairs(chests) do
      for slot, it in pairs(lists[c.name] or {}) do
        if it.name == name then out[#out + 1] = { chest = c.name, slot = slot } end
      end
    end
  end
  add(net.fuel)
  if cfg.useStorageFuel and name ~= "minecraft:lava_bucket" then add(net.storage) add(net.overflow) end
  return out
end

local function fuel()
  local moved = 0
  status.noFuel = false
  status.furnaces = {}
  for _, f in ipairs(net.furnaces) do
    local l = lists[f.name] or {}
    local div = f.kind == "blast" and 2 or 1
    local need = l[1] and l[1].count or 0
    local fslot = l[2]
    local have = 0
    if fslot then have = FUEL_VALUE[fslot.name] and math.floor(FUEL_VALUE[fslot.name] / div * fslot.count) or math.huge end
    if need > 0 and have < need and not (fslot and fslot.name == BUCKET) then
      local done = false
      for pass = 1, 2 do -- pass 1: no waste (no coal block for 10 items), pass 2: anything
        local cands = fslot and { fslot.name } or cfg.fuels
        for _, fname in ipairs(cands) do
          local per = (FUEL_VALUE[fname] or 8) / div
          if not done and (pass == 2 or fslot or per <= math.max(need - have, 8)) then
            local want = math.ceil((need - have) / per)
            if fname == "minecraft:lava_bucket" then want = 1 end
            for _, src in ipairs(fuelSources(fname)) do
              if want <= 0 then break end
              local m = move(src.chest, src.slot, f.name, want, 2)
              want = want - m
              moved = moved + m
              if m > 0 then
                done = true
                fslot = { name = fname, count = (fslot and fslot.count or 0) + m }
                l[2] = fslot
              end
            end
          end
        end
        if done or fslot then break end
      end
      if not done and not fslot then status.noFuel = true end -- empty and nothing to put in
    end
    status.furnaces[#status.furnaces + 1] = { name = f.name, blast = f.kind == "blast",
      input = l[1], fuel = l[2] }
  end
  return moved
end

-- 4. Everything else from the input chests into storage
local function sortInputs()
  local moved = 0
  for _, c in ipairs(net.input) do
    for _, s in ipairs(takeable(lists[c.name] or {})) do
      local m = store(c.name, s.slot, s.name, s.n)
      if m > 0 then
        moved = moved + m
        stats.sorted = stats.sorted + m
        statsDirty = true
        lastAction = "Sorted " .. m .. " " .. pretty(s.name)
      end
    end
  end
  return moved
end

local function round()
  scan()
  local names = {}
  for _, k in ipairs({ "input", "storage", "overflow", "fuel", "pickup", "furnaces" }) do
    for _, c in ipairs(net[k]) do names[#names + 1] = c.name end
  end
  lists = listAll(names)
  has, noRoom, storageFull = {}, {}, false
  for n, l in pairs(lists) do
    has[n] = {}
    for _, it in pairs(l) do has[n][it.name] = true end
  end

  local moved = collect() + feed() + fuel() + sortInputs()

  -- Numbers for the screen
  local used, slots, fuelItems = 0, 0, 0
  for _, k in ipairs({ "storage", "overflow" }) do
    for _, c in ipairs(net[k]) do
      slots = slots + sizeOf(c.name)
      for _ in pairs(lists[c.name] or {}) do used = used + 1 end
    end
  end
  for _, c in ipairs(net.fuel) do
    for _, it in pairs(lists[c.name] or {}) do if FUEL_VALUE[it.name] then fuelItems = fuelItems + it.count end end
  end
  status.used, status.slots, status.fuelItems = used, slots, fuelItems
  status.storageFull = storageFull
  if statsDirty then saveTable(STATS_FILE, stats) statsDirty = false end
  return moved
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
local ROLE_KEYS = { i = "input", f = "fuel", s = "storage", o = "overflow", p = "pickup", x = "ignore" }
local CAT_KEYS = { a = "any", o = "ores", i = "ingots", g = "gems", f = "fuel", m = "misc" }

local function contents(n)
  local ok, l = pcall(peripheral.call, n, "list")
  if not ok or not l then return "?" end
  local seen, out = {}, {}
  for _, it in pairs(l) do
    if not seen[it.name] then seen[it.name] = true out[#out + 1] = pretty(it.name) end
  end
  if #out == 0 then return "empty" end
  local s = table.concat(out, ", ", 1, math.min(#out, 3))
  if #out > 3 then s = s .. ", +" .. (#out - 3) end
  return s
end

local function roleText(r)
  if not r then return "not set" end
  if r.role == "storage" then return "storage (" .. (r.cat or "any") .. ")" end
  return r.role
end

local function listNetwork()
  local r = scan()
  print(("%d furnace(s), %d input, %d storage, %d overflow, %d fuel, %d pickup"):format(#r.furnaces,
    #r.input, #r.storage, #r.overflow, #r.fuel, #r.pickup))
  local names = {}
  for _, n in ipairs(peripheral.getNames()) do if isInventory(n) then names[#names + 1] = n end end
  table.sort(names)
  for _, n in ipairs(names) do
    local fk = furnaceKind(n)
    local r_ = cfg.roles[n]
    print(" " .. n .. ": " .. ((r_ and r_.role == "ignore") and "ignore" or fk and (fk == "blast" and "blast furnace" or "furnace") or roleText(r_)))
  end
end

local function setup()
  local names, furn = {}, 0
  for _, n in ipairs(peripheral.getNames()) do
    if isInventory(n) then
      if furnaceKind(n) then furn = furn + 1 else names[#names + 1] = n end
    end
  end
  table.sort(names)
  print("Found " .. furn .. " furnace(s) and " .. #names .. " chest(s).")
  if #names == 0 then
    print("Connect your chests with wired modems and cables, and right-click each modem so it turns red.")
    return
  end
  print("Tip: to tell chests apart, put a marker item (dirt, a flower) in them first.")
  print()
  for i, n in ipairs(names) do
    local cur = cfg.roles[n]
    print(("[%d/%d] %s (%d slots)"):format(i, #names, n, sizeOf(n)))
    print("  holds: " .. contents(n))
    local def = cur and cur.role or "storage"
    write("  i)nput f)uel s)torage o)verflow p)ickup x)ignore [" .. def .. "]: ")
    local a = (read() or ""):lower():sub(1, 1)
    local role = ROLE_KEYS[a] or def
    local entry = { role = role }
    if role == "storage" then
      local defCat = (cur and cur.role == "storage" and cur.cat) or "any"
      write("  holds a)ny o)res i)ngots g)ems f)uel m)isc [" .. defCat .. "]: ")
      local c = (read() or ""):lower():sub(1, 1)
      entry.cat = CAT_KEYS[c] or defCat
    end
    cfg.roles[n] = entry
    print("  -> " .. roleText(entry))
  end
  saveTable(CFG_FILE, cfg)
  print()
  listNetwork()
  print("Saved. Start with: sorter")
end

if args[1] == "setup" then setup() return end
if args[1] == "list" then listNetwork() return end

---------------------------------------------------------------------------
-- Commands: get / find
---------------------------------------------------------------------------
local function matchItems(text)
  local q = text:lower():gsub("%s+", "_")
  local chests = {}
  for _, k in ipairs({ "storage", "overflow", "fuel" }) do
    for _, c in ipairs(net[k]) do chests[#chests + 1] = c.name end
  end
  local l = listAll(chests)
  local totals, exact = {}, nil
  for _, n in ipairs(chests) do
    for _, it in pairs(l[n] or {}) do
      if short(it.name) == q or it.name == q then exact = it.name end
      if it.name:find(q, 1, true) then totals[it.name] = (totals[it.name] or 0) + it.count end
    end
  end
  return totals, exact, l, chests
end

local function cmdFind(text)
  local totals = matchItems(text)
  local any = false
  for name, n in pairs(totals) do print(" " .. pretty(name) .. ": " .. n) any = true end
  if not any then print(" none") end
end

local function cmdGet(text, count)
  if #net.pickup == 0 then print("No pickup chest. Give one with: sorter setup") return end
  local totals, exact, l, chests = matchItems(text)
  local name = exact
  if not name then
    local found = {}
    for n in pairs(totals) do found[#found + 1] = n end
    if #found == 0 then print("None in storage.") return end
    if #found > 1 then
      print("Which one?")
      for _, n in ipairs(found) do print(" " .. short(n)) end
      return
    end
    name = found[1]
  end
  local left = count
  for _, c in ipairs(chests) do
    for slot, it in pairs(l[c] or {}) do
      if left > 0 and it.name == name then
        for _, p in ipairs(net.pickup) do
          if left <= 0 then break end
          local ok, m = pcall(peripheral.call, c, "pushItems", p.name, slot, math.min(left, it.count))
          if ok and m then left = left - m it.count = it.count - m end
        end
      end
    end
  end
  print("Put " .. (count - left) .. " " .. pretty(name) .. " in the pickup chest." .. (left > 0 and count - left > 0 and " (that's all)" or ""))
end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------
local paused = false
local W, H = term.getSize()
local native = term.current()
local statusWin = window.create(native, 1, 1, W, H - 1)
local promptWin = window.create(native, 1, H, W, 1)
local screens = { statusWin }
for _, m in ipairs({ peripheral.find("monitor") }) do
  m.setTextScale(1)
  local mw, mh = m.getSize()
  if mw < 30 or mh < 12 then m.setTextScale(0.5) end
  screens[#screens + 1] = m
end

local function fmtTime(ms)
  local s = math.floor(ms / 1000)
  if s >= 3600 then return ("%dh%02dm"):format(math.floor(s / 3600), math.floor(s / 60) % 60) end
  return ("%dm"):format(math.floor(s / 60))
end

local function draw(t)
  local w, h = t.getSize()
  local color = t.isColor and t.isColor()
  local function c(x) return color and x or colors.white end
  t.setBackgroundColor(colors.black)
  t.clear()
  local y = 1
  local function line(text, col, right, rcol)
    if y > h then return end
    t.setCursorPos(1, y)
    t.setTextColor(c(col or colors.white))
    if right then text = text:sub(1, math.max(0, w - #right - 1)) end
    t.write(text:sub(1, w))
    if right and #right < w then
      t.setCursorPos(w - #right + 1, y)
      t.setTextColor(c(rcol or colors.lightGray))
      t.write(right)
    end
    y = y + 1
  end

  line("SORTER & SMELTER", colors.yellow, paused and "PAUSED" or textutils.formatTime(os.time(), true),
    paused and colors.red or colors.lightGray)
  line(string.rep("-", w), colors.gray)
  if not net then line("Starting...") return end
  if net.unassigned > 0 then line(net.unassigned .. " new chest(s): run sorter setup", colors.orange) end
  if #net.input == 0 then line("No input chest: run sorter setup", colors.red) end
  local busy = 0
  for _, f in ipairs(status.furnaces) do if f.input then busy = busy + 1 end end
  line(("Furnaces %d, busy %d"):format(#net.furnaces, busy), colors.white, "to smelt " .. status.toSmelt)
  if status.noFuel then line("NO FUEL! Put coal in the fuel chest", colors.red)
  elseif #net.fuel > 0 then line("Fuel chest: " .. status.fuelItems .. " items", colors.white) end
  local pct = status.slots > 0 and math.floor(status.used * 100 / status.slots) or 100
  line(("Storage %d/%d slots"):format(status.used, status.slots),
    status.storageFull and colors.red or pct >= 90 and colors.orange or colors.white,
    status.storageFull and "FULL" or pct .. "%", status.storageFull and colors.red or nil)
  line(lastAction, colors.lightGray)
  y = y + 1

  -- Smelted
  local l = {}
  for name, n in pairs(stats.smelted) do l[#l + 1] = { name = name, n = n } end
  table.sort(l, function(a, b) return a.n > b.n end)
  local mins = (os.epoch("utc") - runStart) / 60000
  line("SMELTED", colors.yellow, mins >= 1 and (runSmelted .. " in " .. fmtTime(os.epoch("utc") - runStart)) or nil)
  if #l == 0 then line(" nothing yet", colors.gray) end
  for i = 1, math.min(#l, 4, h - y - 1) do line(" " .. pretty(l[i].name), colors.white, tostring(l[i].n), colors.white) end

  -- Furnaces, as many as fit (leave room for the log)
  if y + 2 <= h - 2 then
    y = y + 1
    line("FURNACES", colors.yellow)
    for _, f in ipairs(status.furnaces) do
      if y > h - 2 then break end
      local name = short(f.name):gsub("blast_furnace", "blast")
      local what = f.input and (f.input.count .. " " .. pretty(f.input.name)) or "idle"
      line(" " .. name .. " " .. what, f.input and colors.white or colors.gray,
        f.fuel and (f.fuel.count .. " " .. short(f.fuel.name):gsub("_.*", "")) or "no fuel",
        f.fuel and colors.lightGray or (f.input and colors.red or colors.gray))
    end
  end
  -- Last log lines at the bottom
  y = math.max(y, h - 1)
  for i = 2, 1, -1 do
    local e = logLines[i]
    if e and y <= h then line(e[1], e[2] and colors.red or colors.gray) else y = y + 1 end
  end
end

local showingOutput = false
local function redraw()
  for _, s in ipairs(screens) do pcall(draw, s) end
  if not showingOutput then promptWin.restoreCursor() end -- keep the cursor on the > line
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
local function worker()
  while true do
    local moved = 0
    if not paused then
      local ok, res = pcall(round)
      if ok then moved = res else log("Error: " .. tostring(res), true) end
    end
    os.queueEvent("sorter_redraw")
    if moved == 0 then sleep(cfg.interval) else sleep(0.5) end
  end
end

local function screenLoop()
  local tick = os.startTimer(1)
  while true do
    redraw()
    local ev, a = os.pullEvent()
    if ev == "timer" and a == tick then tick = os.startTimer(1)
    end
  end
end

local function help()
  print("get <item> [n]  find <item>")
  print("pause  resume  quit")
end

local function prompt()
  local history = {}
  while true do
    term.redirect(promptWin)
    promptWin.clear()
    promptWin.setCursorPos(1, 1)
    promptWin.setTextColor(colors.white)
    write("> ")
    local line = read(nil, history)
    term.redirect(native)
    if line and line:find("%S") then
      history[#history + 1] = line
      local words = {}
      for wd in line:gmatch("%S+") do words[#words + 1] = wd end
      local cmd = words[1]:lower()
      if cmd == "quit" or cmd == "q" or cmd == "exit" then return end
      -- Command output: show it on the whole terminal until a key is pressed
      native.setBackgroundColor(colors.black)
      native.clear()
      native.setCursorPos(1, 1)
      showingOutput = true
      statusWin.setVisible(false)
      if cmd == "pause" then paused = true print("Paused.")
      elseif cmd == "resume" then paused = false print("Running.")
      elseif (cmd == "get" or cmd == "find") and #words >= 2 then
        local n = tonumber(words[#words])
        local last = n and #words - 1 or #words
        local text = table.concat(words, " ", 2, last)
        if not net then scan() end
        if cmd == "get" then cmdGet(text, n or 64) else cmdFind(text) end
      else
        help()
      end
      print("Press any key")
      os.pullEvent("key")
      showingOutput = false
      statusWin.setVisible(true)
      statusWin.redraw()
    end
  end
end

if not peripheral.find("modem", function(_, m) return not m.isWireless() end) then
  print("No wired modem found. Connect this " .. (turtle and "turtle" or "computer") ..
    " to the chests and furnaces with wired modems and cables.")
  return
end
if not next(cfg.roles) then
  print("Not set up yet. Run: sorter setup")
  return
end

parallel.waitForAny(worker, screenLoop, prompt)
term.redirect(native)
native.setBackgroundColor(colors.black)
native.clear()
native.setCursorPos(1, 1)
saveTable(STATS_FILE, stats)
print("Sorter stopped.")
