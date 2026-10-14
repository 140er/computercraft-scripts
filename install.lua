-- install.lua - downloads a bot's script from GitHub
-- Usage: install <bot>
--   miner       mining turtle (Mine Army)
--   hub         Mine Army base computer (also fetches miner.lua for the turtles)
--   relay       range booster for normal wireless modems
--   roomsorter  Storage Room turtle (no modems needed)
--   sorter      Sorter & Smelter on a wired network
--   lumber      tree farm turtle
--   buddy       companion turtle you can chat with
--   panel       pocket computer control panel
--   farmer      crop farming turtle
--   fuel        lava fuel runner: brings lava buckets to the other bots' chests
--   builder     building turtle: clear land, floors, walls, tunnels
--   factory     turtle factory: crafts new turtles and sends them to work
--   gpshost     a GPS host computer (4 of them = GPS for the map and easy setup)
--   smartmine   old standalone tunnel miner
-- Every install also gets update.lua, so "update" (or "<bot> update") fetches new versions later.
local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"
local NEXT = {
  miner = "miner setup <x> <y> <z> <facing> <role>",
  hub = "hub install, then hub",
  relay = "relay install, then relay",
  roomsorter = "roomsorter scan (facing the input chest), roomsorter install, then roomsorter",
  sorter = "sorter setup, sorter install, then sorter",
  lumber = "lumber setup [radius]",
  buddy = "buddy server <url> (or buddy key <xAI key>), buddy setup, then buddy",
  panel = "panel install, then panel",
  farmer = "farmer setup <x> <y> <z> <facing> <length> <width> [left]",
  fuel = "fuel setup <x> <y> <z> <facing>, then fuel cauldrons / fuel lake / fuel add",
  builder = "builder setup <x> <y> <z> <facing>, then builder tunnel ... (or flatten, floor, walls)",
  factory = "factory setup <x> <y> <z> <facing>, then factory build ...",
  gpshost = "gpshost <x> <y> <z> (this computer's coordinates)",
  smartmine = "smartmine <length> [tunnels] [gap] [blocks]",
}
local what = ({ ... })[1]
if not what or not NEXT[what] then
  print("Usage: install <bot>")
  local names = {}
  for k in pairs(NEXT) do names[#names + 1] = k end
  table.sort(names)
  print("Bots: " .. table.concat(names, ", "))
  return
end
local files = { what .. ".lua", "update.lua" }
if what == "hub" then files[#files + 1] = "miner.lua" end -- the hub hands it to the turtles
-- the newer bots share botlib.lua
if what == "farmer" or what == "fuel" or what == "builder" or what == "factory" then files[#files + 1] = "botlib.lua" end
for _, f in ipairs(files) do
  if fs.exists(f) then fs.delete(f) end
  shell.run("wget", BASE .. f, f)
end
print("Done. Next: " .. NEXT[what])
