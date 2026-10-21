local id = os.getComputerID()
local D = dofile("depth-result.lua")
local modem = peripheral.find("modem")
rednet.open(peripheral.getName(modem))

if id == 2 then
  local timer = os.startTimer(30)
  while true do
    local event, _, message = os.pullEvent()
    if event == "rednet_message" and type(message) == "table" and message.depth == "ready" then break end
    if event == "timer" and _ == timer then error("saver did not start", 0) end
  end
  local sent = 0
  for n = 1, 40 do
    rednet.send(1, { depth = "burst", n = n }, "depth-burst")
    sent = sent + 1
  end
  local handle = fs.open("events-sent.json", "w")
  handle.write(textutils.serializeJSON({ sent = sent }))
  handle.close()
  local checks = {}
  D.check(checks, "burst sent", sent == 40, tostring(sent))
  D.finish(checks)
  return
end

local A = dofile("atomic.lua")
local store = A.mount("/"):open("event.state", function(v)
  return type(v) == "table" and type(v.n) == "number"
end, { class = "bulk", limit = 4096 })
rednet.broadcast({ depth = "ready" }, "depth-burst")
local got, saves, timerFired, httpDone, httpCalled = 0, 0, false, false, false
local timer = os.startTimer(0.2)
local deadline = os.startTimer(25)
while got < 40 or saves < 20 or not timerFired do
  if saves < 20 then
    local saved = store:save({ n = saves + 1 })
    if saved then saves = saves + 1 end
    if saves == 10 then
      httpCalled = true
      if http and http.get then
        pcall(http.get, "http://127.0.0.1:1/")
      else
        local note = fs.open("http-disabled", "w")
        note.write("http api missing")
        note.close()
      end
    end
  end
  local event, token, message = os.pullEvent()
  if event == "rednet_message" and type(message) == "table" and message.depth == "burst" then
    got = got + 1
  elseif event == "timer" and token == timer then
    timerFired = true
  elseif event == "http_success" or event == "http_failure" then
    httpDone = true
  elseif event == "timer" and token == deadline then
    break
  end
end
local handle = fs.open("events-got.json", "w")
handle.write(textutils.serializeJSON({ got = got, saves = saves, timer = timerFired, http = httpDone }))
handle.close()
local checks = {}
D.check(checks, "save ran during the burst", saves == 20, tostring(saves))
D.check(checks, "no rednet request dropped", got == 40, tostring(got))
D.check(checks, "timer fired during the burst", timerFired == true, "timer missing")
D.check(checks, "http call during the burst", httpCalled == true and not fs.exists("http-disabled"),
  fs.exists("http-disabled") and "http api missing" or "http was not called")
D.finish(checks)
