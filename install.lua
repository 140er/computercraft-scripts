-- install.lua - haalt de Mine Army scripts van GitHub
-- Gebruik: install miner   (op een turtle)
--          install hub     (op de basis-computer)
local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/claude/mine-lua-turtle-9o3j9v/"
local what = ({ ... })[1] or (turtle and "miner" or "hub")
local files = { what .. ".lua" }
for _, f in ipairs(files) do
  if fs.exists(f) then fs.delete(f) end
  shell.run("wget", BASE .. f, f)
end
print("Klaar. " .. (what == "miner" and "Nu: miner setup <x> <y> <z> <facing> <rol>" or "Nu: hub install, daarna hub"))
