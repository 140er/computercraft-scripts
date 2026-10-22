local H = dofile("tests/so/harness.lua")
local key = string.rep("a", 64)
local function libs(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path, "rb"))
    m.files[path] = f:read("*a")
    f:close()
  end
end
local function setup(paired)
  local net = H.new()
  local s = net.machine({ id = 1, modem = true })
  s.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
  libs(s)
  s.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["2"]=key}}})
  local w = net.machine({ id = 2, modem = true, turtle = true, capacity = 1000000 })
  w.install({ "worker.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
  libs(w)
  if paired then w.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["1"]=key}}}) end
  w.env.read = function() w.reads = (w.reads or 0) + 1; return coroutine.yield() end
  local lookup = w.env.rednet.lookup
  w.lookups = 0
  w.env.rednet.lookup = function(...) w.lookups = w.lookups + 1; return lookup(...) end
  w.boot("worker.lua")
  return net, s, w
end
return function(test, equal)
  test("worker paired boot recovers without keyboard after server outage", function()
    local n, s, w = setup(true)
    n.advance(120)
    equal(w.reads or 0, 0)
    assert(w.lookups > 2, "lookup never retried")
    assert(w.lookups <= 10, "discovery did not back off")
    assert(table.concat(w.screen, " "):find("waiting for server", 1, true), "waiting status missing")
    w.env.rednet.lookup = function() return nil end
    s.boot("so-server.lua")
    n.advance(31)
    assert(w.alive(), tostring(w.error))
    assert(s.alive(), tostring(s.error))
    equal(w.reads or 0, 0)
    equal(w.screen[2], "step idle")
    local hello = false
    for _, wire in ipairs(w.sent) do
      if wire.payload.t == "hello" then hello = true end
    end
    assert(hello, "hello missing")
  end)
  test("worker unpaired code prompt keeps retrying discovery", function()
    local n, _, w = setup(false)
    n.advance(20)
    assert(w.alive(), tostring(w.error))
    assert(w.lookups > 2, "prompt blocked discovery")
    equal(w.reads or 0, 0)
    assert((w.screen[5] or ""):find("Code:", 1, true), "code prompt missing")
  end)
  test("worker accepts typed code after discovering a late server", function()
    local n, s, w = setup(false)
    n.advance(10)
    s.boot("so-server.lua")
    n.advance(3)
    local code = s.env.SO.pair.invite()
    w.inbox[#w.inbox + 1] = table.pack("paste", code)
    w.inbox[#w.inbox + 1] = table.pack("key", 257)
    n.flush()
    n.advance(3)
    assert(w.alive(), tostring(w.error))
    assert(w.files["so-keys"], "typed code did not pair")
    equal(w.reads or 0, 0)
    equal(w.screen[2], "step idle")
  end)

end
