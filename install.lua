-- install.lua - downloads the Mine Army scripts from GitHub
-- Usage: install miner   (on a turtle)
--        install hub     (on the base computer)
local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"
local what = ({ ... })[1] or (turtle and "miner" or "hub")
local files = { what .. ".lua" }
for _, f in ipairs(files) do
  if fs.exists(f) then fs.delete(f) end
  shell.run("wget", BASE .. f, f)
end
print("Done. " .. (what == "miner" and "Next: miner setup <x> <y> <z> <facing> <role>" or "Next: hub install, then hub"))
