-- Harness only. http.get reads the files already on this disk so
-- `install role roomclient quick` installs this branch, not GitHub alpha.
local lines = {}
local function note(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  lines[#lines + 1] = table.concat(parts, " ")
end
local nativePrint = _G.print
_G.print = function(...)
  note(...)
  nativePrint(...)
end
_G.http = _G.http or {}
function _G.http.get(url)
  local file = url:match("/([%w%._%-]+)%?")
  note("http", file, fs.exists(file) and "yes" or "no")
  if not file or not fs.exists(file) then return nil, "missing " .. tostring(file) end
  local h = fs.open(file, "r")
  local text = h.readAll()
  h.close()
  return { readAll = function() return text end, close = function() end }
end
local ran, err = pcall(function()
  local returned = shell.run("install", "role", "roomclient", "quick")
  note("shell.run", tostring(returned))
end)
note("pcall", tostring(ran), tostring(err))
local out = fs.open("install-out.txt", "w")
for _, line in ipairs(lines) do out.writeLine(line) end
out.writeLine("startup " .. tostring(fs.exists("startup.lua")))
if fs.exists("startup.lua") then
  local h = fs.open("startup.lua", "r")
  out.writeLine(h.readAll())
  h.close()
end
out.close()
os.shutdown()
