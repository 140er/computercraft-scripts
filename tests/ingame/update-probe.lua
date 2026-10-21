local D = dofile("depth-result.lua")
local checks = {}

local function write(path, text)
  local handle = fs.open(path, "w")
  handle.write(text)
  handle.close()
end

local function read(path)
  if not fs.exists(path) then return nil end
  local handle = fs.open(path, "r")
  local text = handle.readAll()
  handle.close()
  return text
end

write("server-version.txt", "server-9")
write("client-version.txt", "client-4")
local skew = read("server-version.txt") ~= read("client-version.txt")
D.check(checks, "version skew is visible", skew == true, "versions match")

local good = "return 'good'\n"
write("role-good.lua", good)
write("role-good.lua.fleet-backup", good)
write("role-good.lua", "return 'bad'\n")
local journal = textutils.serialize({
  version = 1,
  files = { { file = "role-good.lua", existed = true } },
})
write(".fleet-update-journal", journal)
shell.run("update.lua", "--repair", "noreboot")
local restored = read("role-good.lua")
D.check(checks, "interrupted update rolls back", restored == good, restored)
D.check(checks, "journal is cleared after rollback", not fs.exists(".fleet-update-journal"), "journal remains")
write("update-record.json", textutils.serializeJSON({
  server = read("server-version.txt"), client = read("client-version.txt"), restored = restored,
}))
D.finish(checks)
