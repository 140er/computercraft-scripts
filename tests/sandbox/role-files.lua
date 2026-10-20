local root, kind, which = arg[1], arg[2], arg[3]
local roles = dofile(root .. "/roles.lua")
local function sizeOf(name)
  local handle = io.open(root .. "/" .. name, "rb")
  if not handle then return 0 end
  local text = handle:read("*a")
  handle:close()
  return #text
end
local names
if kind == "program" then
  names = roles.program(which)
elseif kind == "union" then
  local union = roles.union(which, sizeOf)
  names = {}
  for name in pairs(union.files) do names[#names + 1] = name end
  table.sort(names)
else
  error("kind")
end
for _, name in ipairs(names) do print(name) end
