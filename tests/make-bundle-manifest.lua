local function read(path)
  local f = assert(io.open(path, "rb"))
  local code = f:read("*a")
  f:close()
  return code:gsub("\r\n", "\n")
end
local function hash(code)
  local h = 5381
  for i = 1, #code do h = (h * 33 + code:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end
local source = read("update.lua")
local list = assert(load("return " .. assert(source:match("local KNOWN = (%b{})"))))()
table.sort(list)
local rows = {}
for _, file in ipairs(list) do
  if file ~= "bundle-manifest.lua" then rows[#rows + 1] = string.format("    [%q] = %q,", file, hash(read(file))) end
end
local body = table.concat(rows, "\n")
local manifest = 'return {\n  schema = 1,\n  version = "' .. hash(body) .. '",\n  files = {\n' .. body .. "\n  },\n}\n"
local f = assert(io.open("bundle-manifest.lua", "wb"))
f:write(manifest)
f:close()
print("Bundle manifest " .. hash(body))
