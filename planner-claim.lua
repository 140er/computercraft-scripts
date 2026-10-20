-- Turtle-side claim for a planner copy code.
-- install.lua does not accept planner codes until I1. This program sends plan-claim itself.
-- The player types the code and the facing. Headings are north 0, east 1, south 2, west 3.

local args = { ... }
local PROTOCOL = "fleetserver"

local function say(text)
  print(text)
end

local function wireless()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem and modem.isWireless() then return name end
    end
  end
end

local function heading(text)
  local n = tonumber(text)
  if n == 0 or n == 1 or n == 2 or n == 3 then return n end
end

local function ask(prompt, parse)
  local value = parse(args[1])
  if value ~= nil then
    table.remove(args, 1)
    return value
  end
  while true do
    write(prompt)
    local line = read()
    value = parse(line)
    if value ~= nil then return value end
    say("That value is not usable. Try again.")
  end
end

local function blockName(ok, data)
  if ok and type(data) == "table" and type(data.name) == "string" then return data.name end
  return "minecraft:air"
end

local function sample(blocks, peripherals, side)
  local ok, data = turtle.inspect()
  blocks[side] = blockName(ok, data)
  local kind = peripheral.getType("front")
  if type(kind) == "string" then peripherals[side] = kind end
  turtle.turnRight()
end

local function observe(facing)
  local blocks, peripherals = {}, {}
  blocks.up = blockName(turtle.inspectUp())
  blocks.down = blockName(turtle.inspectDown())
  local above = peripheral.getType("top")
  local below = peripheral.getType("bottom")
  if type(above) == "string" then peripherals.up = above end
  if type(below) == "string" then peripherals.down = below end
  sample(blocks, peripherals, "front")
  sample(blocks, peripherals, "right")
  sample(blocks, peripherals, "back")
  sample(blocks, peripherals, "left")
  return { h = facing, blocks = blocks, peripherals = peripherals }
end

local function nextCounter()
  local n = 0
  if fs.exists("planner-claim.counter") then
    local handle = fs.open("planner-claim.counter", "r")
    n = tonumber(handle.readAll()) or 0
    handle.close()
  end
  n = n + 1
  local handle = fs.open("planner-claim.counter", "w")
  handle.write(tostring(n))
  handle.close()
  return n
end

local function waitReply(rid)
  local timer = os.startTimer(5)
  while true do
    local event, sender, message, protocol = os.pullEvent()
    if event == "rednet_message" and protocol == PROTOCOL and type(message) == "table"
      and message.v == 1 and message.type == "ssot_reply" and message.rid == rid then
      os.cancelTimer(timer)
      return message
    end
    if event == "timer" and sender == timer then return nil end
  end
end

local function save(reply)
  local handle = fs.open("planner-enrol.state", "w")
  handle.write(textutils.serialize({
    role = reply.role, settings = reply.settings, pose = reply.pose,
    error = reply.error, screen = reply.screen,
  }))
  handle.close()
end

if not turtle then
  say("Run this on the turtle that should take the planned cell.")
  return
end

local modem = wireless()
if not modem then
  say("Attach a wireless modem, then run this again.")
  return
end
rednet.open(modem)

local code = ask("Copy code: ", function(text)
  if type(text) ~= "string" then return nil end
  text = text:upper()
  if #text == 10 then return text end
end)
local facing = ask("Facing (0 north, 1 east, 2 south, 3 west): ", heading)
local server = rednet.lookup(PROTOCOL, "server")
if type(server) ~= "number" then
  say("No fleet server answered.")
  return
end

local boot = "claim-" .. os.getComputerID()
local counter = nextCounter()
local rid = boot .. ":" .. counter
local message = {
  v = 1, type = "ssot", expect = "ssot_reply", op = "plan-claim",
  boot = boot, rid = rid, counter = counter,
  code = code, observe = observe(facing),
}
local reply
for _ = 1, 3 do
  rednet.send(server, message, PROTOCOL)
  reply = waitReply(rid)
  if reply then break end
end
if not reply then
  say("The server did not answer. The code was not burned. Run this again.")
  return
end
save(reply)
if type(reply.screen) == "string" then say(reply.screen) end
if reply.ok and type(reply.pose) == "table" then
  say("Pose " .. reply.pose.x .. "," .. reply.pose.y .. "," .. reply.pose.z
    .. " facing " .. reply.pose.h .. " (" .. tostring(reply.pose.conf) .. ")")
  say("Role " .. tostring(reply.role))
else
  say(tostring(reply.error or "claim failed"))
end
