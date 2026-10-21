local cfg = {}
if fs.exists("/wrap.cfg") then
  local h = fs.open("/wrap.cfg", "r")
  cfg = textutils.unserialize(h.readAll()) or {}
  h.close()
end
if cfg.pre and cfg.pre ~= "" then
  local fn, err = load(cfg.pre, "=pre", "t", _ENV)
  if not fn then error(err, 0) end
  fn()
end
if cfg.modem ~= false and not peripheral.isPresent("back") then
  periphemu.create("back", "modem")
end
if cfg.peer then periphemu.create(1, "computer") end
local call0, wrap0 = peripheral.call, peripheral.wrap
peripheral.call = function(n, m, ...)
  if m == "isWireless" and peripheral.getType(n) == "modem" then return true end
  return call0(n, m, ...)
end
peripheral.wrap = function(n)
  local p = wrap0(n)
  if p and peripheral.getType(n) == "modem" then
    p.isWireless = function() return true end
  end
  return p
end
local find0 = peripheral.find
local mon
if cfg.monitor then
  local hidden = window.create(term.native(), 1, 1, 36, 24, false)
  mon = window.create(hidden, 1, 1, 36, 24, false)
  mon.setTextScale = function() end
end
peripheral.find = function(kind, filter)
  if cfg.monitor and kind == "monitor" then
    if not filter or filter("right", mon) then return mon end
    return nil
  end
  return find0(kind, filter)
end
if cfg.monitor then
  local getName0 = peripheral.getName
  peripheral.getName = function(p)
    if p == mon then return "right" end
    return getName0(p)
  end
end
local W, H = term.getSize()
local win = window.create(term.native(), 1, 1, W, H)
term.redirect(win)
local err, done = nil, false
parallel.waitForAny(function()
  local ok, e = pcall(shell.run, "startup_real.lua")
  if not ok then err = e end
  done = true
end, function()
  sleep(cfg.secs or 12)
end)
local out = fs.open("/result.txt", "w")
out.writeLine("program returned: " .. tostring(done) .. "  pcall err: " .. tostring(err))
out.writeLine("capacity " .. tostring(fs.getCapacity("/")) .. " free " .. tostring(fs.getFreeSpace("/")))
local function walk(d)
  for _, f in ipairs(fs.list(d)) do
    if f ~= "rom" and f ~= "verify" then
      local p = fs.combine(d, f)
      if fs.isDir(p) then walk(p)
      else out.writeLine(("  %7d %s"):format(fs.getSize(p), p)) end
    end
  end
end
walk("/")
out.writeLine("-- screen")
for y = 1, H do out.writeLine(win.getLine(y)) end
if mon then
  local mw, mh = mon.getSize()
  out.writeLine("-- monitor")
  for y = 1, mh do out.writeLine(mon.getLine(y)) end
end
out.close()
os.shutdown()
