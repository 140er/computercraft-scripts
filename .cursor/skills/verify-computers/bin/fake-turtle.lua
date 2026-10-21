local function mark(text)
  local h = fs.open("/turtle-up.txt", "w")
  h.writeLine(text)
  h.close()
end
mark("booted")
if fs.exists("/delay") then
  local h = fs.open("/delay", "r")
  local d = tonumber(h.readAll())
  h.close()
  sleep(d)
end
mark("up")
periphemu.create("back", "modem")
rednet.open("back")
rednet.host("roomsorter", "storage1")
local function reply()
  return {
    version = 15,
    totals = { ["minecraft:iron_ingot"] = 64, ["minecraft:coal"] = 12 },
    state = "idle",
    crafty = false,
    cutoff = 0,
    recipes = {},
    orders = {},
  }
end
local tick = os.startTimer(1)
while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "rednet_message" and c == "roomsorter" and type(b) == "table" then
    local r = b.cmd == "stock" and reply() or { "ok " .. tostring(b.cmd) }
    r.rid = b.rid
    rednet.send(a, r, "roomsorter")
  elseif ev == "timer" and a == tick then
    rednet.broadcast({ totals = reply().totals, state = "idle" }, "roomsorter_stock")
    tick = os.startTimer(2)
  end
end
