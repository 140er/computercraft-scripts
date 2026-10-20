local P = dofile("probe.lua")
local result = {v = 1, runtime = _HOST, computer = os.getComputerID(),
  kind = turtle and "turtle" or "computer", capacity = fs.getCapacity("/"),
  freeBefore = fs.getFreeSpace("/"), files = {}}
assert(not fs.exists("storage-fixture"), "storage fixture already exists")
local before = fs.getFreeSpace("/")
fs.makeDir("storage-fixture")
result.directoryCost = before - fs.getFreeSpace("/")
for _, bytes in ipairs({0, 1, 499, 500, 501, 1000}) do
  sleep(0)
  local free = fs.getFreeSpace("/")
  local path = "storage-fixture/" .. bytes
  local f = assert(fs.open(path, "wb"))
  f.write(("x"):rep(bytes))
  f.close()
  local cost = free - fs.getFreeSpace("/")
  result.files[#result.files + 1] = {bytes = bytes, allocated = cost, readSize = fs.getSize(path)}
end
result.freeAfter = fs.getFreeSpace("/")
result.ok = result.capacity == 1000000
result.matchesMinimumFileCost = true
for _, file in ipairs(result.files) do
  result.ok = result.ok and file.readSize == file.bytes
  result.matchesMinimumFileCost = result.matchesMinimumFileCost and file.allocated == math.max(500, file.bytes)
end
P.save("storage", result)
return result
