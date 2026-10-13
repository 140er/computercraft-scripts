-- install.lua - downloads the Mine Army scripts from GitHub
-- Usage: install miner   (on a turtle)
--        install hub     (on the base computer)
--        install sorter  (sorter & smelter turtle/computer)
local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"
local what = ({ ... })[1] or (turtle and "miner" or "hub")
local files = { what .. ".lua" }
for _, f in ipairs(files) do
  if fs.exists(f) then fs.delete(f) end
  shell.run("wget", BASE .. f, f)
end
local NEXT = { miner = "miner setup <x> <y> <z> <facing> <role>", hub = "hub install, then hub",
  sorter = "sorter setup, sorter install, then sorter", relay = "relay install, then relay" }
print("Done. Next: " .. (NEXT[what] or what))
