local W, H = term.getSize()
local win = window.create(term.native(), 1, 1, W, H)
term.redirect(win)
if not peripheral.isPresent("back") then periphemu.create("back", "modem") end
shell.run("store", "install")
local returned = false
local err = nil
parallel.waitForAny(function()
  local ok, why = pcall(shell.run, "store")
  returned = ok
  if not ok then err = tostring(why) end
end, function()
  sleep(4)
end)
local h = fs.open("store-boot-result.txt", "w")
h.writeLine("returned " .. tostring(returned))
h.writeLine("capacity " .. tostring(fs.getCapacity("/")))
if err then h.writeLine("err " .. err) end
h.writeLine("-- screen")
for y = 1, H do h.writeLine(win.getLine(y)) end
h.close()
os.shutdown()
