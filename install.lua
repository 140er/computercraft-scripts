-- install.lua - downloads the Mine Army scripts from GitHub
-- Usage: install miner   (on a turtle)
--        install hub     (on the base computer)
--        install sorter  (sorter & smelter turtle/computer)
--        install roomsorter  (storage room turtle, no modems)
--        install lumber  (on a tree farm turtle)
local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"
local what = ({ ... })[1] or (turtle and "miner" or "hub")
local files = { what .. ".lua" }
for _, f in ipairs(files) do
  if fs.exists(f) then fs.delete(f) end
  shell.run("wget", BASE .. f, f)
end
local NEXT = { miner = "miner setup <x> <y> <z> <facing> <role>", hub = "hub install, then hub",
  sorter = "sorter setup, sorter install, then sorter",
  roomsorter = "roomsorter scan (facing the input chest), roomsorter install, then roomsorter", relay = "relay install, then relay" }
print("Done. Next: " .. (NEXT[what] or what))
local NEXT = {
  miner = "Next: miner setup <x> <y> <z> <facing> <role>",
  lumber = "Next: lumber setup [radius]",
}
print("Done. " .. (NEXT[what] or "Next: hub install, then hub"))
