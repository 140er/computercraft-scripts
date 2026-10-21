local D = dofile("depth-result.lua")
local checks = {}

local function check(name, ok, err)
  D.check(checks, name, ok, err)
end

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

local function phase()
  return read("faults-phase") or ""
end

local function waitFor(name)
  write("faults-need", name)
  while not fs.exists("faults-need.done") do sleep(0.2) end
  fs.delete("faults-need")
  fs.delete("faults-need.done")
end

if phase() == "" then
  local x = gps.locate(2)
  write("gps-result.txt", x == nil and "down" or tostring(x))
  local moved = false
  pcall(function() moved = turtle.forward() end)
  write("applied.txt", moved and "1" or "0")
  write("attempt-lost-commit.txt", "moved=" .. tostring(moved) .. " commit=absent")
  write("faults-phase", "reboot")
  write("faults-ready", "reboot")
  return
end

check("gps host down returns no fix", read("gps-result.txt") == "down", read("gps-result.txt"))
check("lost commit is not applied twice", read("applied.txt") == "1" and not fs.exists("commit.txt"), read("applied.txt"))
write("attempt-lost-commit.txt", "reboot applied=" .. tostring(read("applied.txt")) .. " commit=absent")

local A = dofile("atomic.lua")
local store = A.mount("/"):open("fault.slot", function(v)
  return type(v) == "table" and type(v.n) == "number"
end, { class = "bulk", limit = 4096 })
check("small save lands", store:save({ n = 1 }) == true, "first save")
local free = fs.getFreeSpace("/")
if type(free) == "number" then
  local handle = fs.open("fill.bin", "w")
  local chunk = string.rep("x", 512)
  while type(fs.getFreeSpace("/")) == "number" and fs.getFreeSpace("/") > 1500 do
    handle.write(chunk)
  end
  handle.close()
end
local failed = store:save({ n = 2, pad = string.rep("y", 2000) })
check("full disk save recovers the old value", failed ~= true and store.value and store.value.n == 1,
  "save returned " .. tostring(failed))
write("attempt-disk-full.txt", "free=" .. tostring(fs.getFreeSpace("/")) .. " kept=" .. tostring(store.value and store.value.n))
fs.delete("fill.bin")

local Client = dofile("ssot-client.lua")
local cfg = { server = 0, secret = "test-secret-123456", counterFile = "ssot.counter", timeout = 0.05 }
local first = Client.new(cfg)
local boot = first.boot
write("saved-boot.txt", boot)
local sent = {}
rednet.send = function(_, message)
  sent[#sent + 1] = message
end
first.call("commit", { x = 1 })
local envelope = sent[1]
write("attempt-after-save.txt", textutils.serialize(envelope or { missing = true }))
write("attempt-after-transmit.txt", "sends=" .. tostring(#sent))
local progress, seen = 0, {}
local function accept(message)
  if type(message) ~= "table" or seen[message.rid] then return end
  seen[message.rid] = true
  progress = progress + 1
end
accept(envelope)
accept(envelope)
write("attempt-after-commit.txt", "progress=" .. tostring(progress) .. " rid=" .. tostring(envelope and envelope.rid))
check("same envelope is not counted twice", progress == 1 and envelope and envelope.counter == 1, tostring(progress))
local second = Client.new(cfg)
write("attempt-boot.txt", "old=" .. boot .. " new=" .. tostring(second.boot))
check("reboot keeps the old boot identity", second.boot == boot, "old " .. boot .. " new " .. tostring(second.boot))

waitFor("modem-on")
local modem = peripheral.find("modem")
check("ender modem is present", modem ~= nil, "modem missing")
waitFor("modem-off")
check("ender modem removal is observed", peripheral.find("modem") == nil, "modem still attached")

local before = turtle.getFuelLevel()
waitFor("charger-on")
sleep(3)
local mid = turtle.getFuelLevel()
waitFor("charger-off")
sleep(3)
local after = turtle.getFuelLevel()
write("attempt-charger.txt", "before=" .. tostring(before) .. " mid=" .. tostring(mid) .. " after=" .. tostring(after))
check("charger power loss stops fuel gain", type(mid) == "number" and mid > before and after == mid,
  "before " .. tostring(before) .. " mid " .. tostring(mid) .. " after " .. tostring(after))
D.finish(checks)
