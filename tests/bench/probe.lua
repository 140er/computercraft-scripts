local M = {}

function M.hex(bytes)
  return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

function M.unhex(text)
  assert(#text % 2 == 0 and not text:find("[^%da-f]"), "invalid hex")
  return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

function M.measure(fn)
  local started = os.epoch("utc")
  local thread = coroutine.create(fn)
  local event, yields, longest = table.pack(), 0, 0
  while true do
    local before = os.epoch("utc")
    local values = table.pack(coroutine.resume(thread, table.unpack(event, 1, event.n)))
    longest = math.max(longest, os.epoch("utc") - before)
    if not values[1] or coroutine.status(thread) == "dead" then
      return {
        ok = values[1], elapsedMs = os.epoch("utc") - started,
        yields = yields, longestSliceMs = longest, belowTimeout = longest < 7000,
        value = values[1] and values[2] or false,
        error = not values[1] and tostring(values[2]):gsub("https?://%S+", "<redacted URL>") or false,
      }
    end
    yields = yields + 1
    local filter = values[2]
    repeat event = table.pack(os.pullEventRaw()) until filter == nil or event[1] == filter or event[1] == "terminate"
  end
end

function M.save(name, value)
  fs.makeDir("results")
  local path = "results/" .. name .. ".json"
  local f = assert(fs.open(path .. ".tmp", "w"))
  f.write(textutils.serializeJSON(value))
  f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".tmp", path)
  sleep(0)
  local monitor = peripheral and peripheral.find("monitor")
  local previous
  if monitor then
    monitor.setTextScale(.5)
    previous = term.redirect(monitor)
  end
  term.setBackgroundColour(colours.black)
  term.setTextColour(value.ok == false and colours.red or colours.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("P0 " .. name)
  print("Computer " .. os.getComputerID())
  if value.elapsedMs then print(value.elapsedMs .. " ms; " .. value.yields .. " yields") end
  if value.capacity then print("Capacity " .. value.capacity .. "; free " .. value.freeBefore) end
  if value.successful then print(value.successful .. " passed; " .. value.failed .. " failed") end
  print(value.ok == false and "FAIL" or "Recorded")
  if value.error then print(value.error) end
  if value.value then print(textutils.serializeJSON(value.value)) end
  if previous then term.redirect(previous) end
  if (value.round == 1 or name == "storage" or name == "initial" or name == "randomness")
    and config and config.get and config.get("useHardwareRenderer") == false and term.screenshot then
    sleep(1.1)
    term.screenshot()
    sleep(1.1)
  end
end

return M
