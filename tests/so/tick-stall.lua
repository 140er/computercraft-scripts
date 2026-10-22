-- Gate B C7: planning froze while beacons still arrived. A sleep(0) inside a
-- handler swallowed the one-second tick timer, and the loop only rearmed on
-- that timer.
local H = dofile("tests/so/harness.lua")

local PROBE = [[
local P = PROBE
return {
  name = "zprobe",
  handlers = {},
  tick = function() P.ticks = P.ticks + 1 end,
  listen = {
    bulk = function(from, n)
      local cells = {}
      for i = 1, n do cells[i] = { "minecraft:overworld", i, 0, 0 } end
      assert(SO.mods.cells.reserveMany("probe", cells))
      P.counted = SO.mods.cells.counts().reserved.probe
      P.got[#P.got + 1] = "bulk"
    end,
    rogue = function()
      os.pullEvent()
      P.got[#P.got + 1] = "rogue"
    end,
    beacon = function(from, body) P.got[#P.got + 1] = body end,
  },
}
]]

local function boot()
  local net = H.new()
  local m = net.machine({ id = 1, modem = true, guardServer = true })
  m.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-mod-cells.lua" })
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path)); m.files[path] = f:read("*a"); f:close()
  end
  m.files["so-mod-zprobe.lua"] = PROBE
  m.env.PROBE = { ticks = 0, got = {} }
  m.boot("so-server.lua")
  net.flush()
  assert(m.alive(), tostring(m.error))
  net.advance(2.5)
  return net, m, m.env.PROBE
end

-- Fire the pending tick timer now, queued right behind a listener message,
-- as happens when that timer comes due while the handler runs.
local function fireTickBehind(m, protocol, body)
  assert(#m.timers == 1, "expected only the tick timer")
  local tick = table.remove(m.timers, 1)
  m.inbox[#m.inbox + 1] = table.pack("rednet_message", 7, body, protocol)
  m.inbox[#m.inbox + 1] = table.pack("timer", tick.id)
  m.inbox[#m.inbox + 1] = table.pack("rednet_message", 7, "after", "beacon")
end

return function(test, equal)
  test("tick-stall: a bulk cells call in a handler keeps the tick timer and later messages", function()
    local net, m, P = boot()
    local before = P.ticks
    assert(before >= 2, "server did not tick before the probe")
    fireTickBehind(m, "bulk", 300)
    net.advance(5)
    assert(m.alive(), tostring(m.error))
    equal(P.counted, 300)
    equal(P.got, { "bulk", "after" })
    assert(P.ticks >= before + 5, "ticks stopped after the bulk handler: " .. P.ticks - before)
    equal(m.waits, nil)
  end)

  test("tick-stall: server modules never call sleep", function()
    -- The installer lists every server file; the suite may run without git.
    local names, seen = {}, {}
    local f = assert(io.open("install.lua")); local install = f:read("*a"); f:close()
    for name in install:gmatch('"(so%-[%w%-]+%.lua)"') do
      if not seen[name] and (name:match("^so%-mod%-") or name == "so-log.lua") then
        names[#names + 1], seen[name] = name, true
      end
    end
    assert(#names > 5 and seen["so-mod-cells.lua"] and seen["so-log.lua"], "module list")
    for _, name in ipairs(names) do
      local f = assert(io.open(name)); local text = f:read("*a"); f:close()
      for line in text:gmatch("[^\n]+") do
        local code = line:gsub("%-%-.*$", "")
        assert(not code:find("%f[%w_]sleep%s*%("), name .. " calls sleep: " .. line)
      end
    end
  end)

  test("tick-stall: the server rearms ticks after a handler swallows its timer", function()
    local net, m, P = boot()
    local before = P.ticks
    fireTickBehind(m, "rogue", nil)
    net.flush()
    equal(P.got, { "rogue", "after" })
    net.advance(5)
    equal(P.ticks, before)
    m.inbox[#m.inbox + 1] = table.pack("rednet_message", 7, "late", "beacon")
    net.flush()
    equal(P.got, { "rogue", "after", "late" })
    equal(P.ticks, before + 1)
    net.advance(5)
    assert(P.ticks >= before + 5, "ticks did not resume: " .. P.ticks - before)
    local logged = false
    for _, line in ipairs(m.log) do
      if line:find("rearming the tick timer", 1, true) then logged = true end
    end
    assert(logged, "rearm was not logged")
  end)
end
