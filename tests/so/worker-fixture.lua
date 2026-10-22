local H = dofile("tests/so/harness.lua")
local F = {}
F.setup = function(opts, modules)
  local n = H.new()
  local s = n.machine({ id = 1, modem = true })
  local t = n.machine(opts or { id = 2, modem = true, turtle = true, capacity = 1000000 })
  for _, m in ipairs({s, t}) do
    m.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
      "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
      local path = "lib/ccryptolib/" .. name .. ".lua"
      local f = assert(io.open(path)); m.files[path] = f:read("*a"); f:close()
    end
    m.files["so-keys"] = H.encode({ schema=1, generation=1,
      value={ keys={ [tostring(m == s and 2 or 1)]=string.rep("a",64) } } })
  end
  s.install({ "so-server.lua" })
  if modules then s.install(modules) end
  s.boot("so-server.lua"); n.flush()
  t.install({ "worker.lua" }); t.boot("worker.lua"); n.flush()
  assert(not s.error, tostring(s.error)); assert(not t.error, tostring(t.error))
  return { n=n, s=s, t=t }
end
F.send = function(a, steps, ms)
  local msg = a.s.env.SO.proto.build(a.s.env.SO.pair.key(2), "lease.batch", {
    lease="test-" .. tostring(a.n.time), expires=a.n.time+(ms or 600000), steps=steps,
  })
  a.s.env.rednet.send(2, a.s.env.SO.proto.encode(msg), "so"); a.n.flush()
end
F.sent = function(t, kind)
  local out = {}
  for _, item in ipairs(t.sent) do if item.payload.t == kind then out[#out+1] = item.payload end end
  return out
end
F.journal = function(t)
  return assert(t.env.textutils.unserialize(t.files["so-journal"])).value
end
F.check = function(a)
  assert(a.t.alive(), tostring(a.t.error)); assert(a.s.alive(), tostring(a.s.error))
end
return F
