return function(test, equal)
  local plug = dofile("plug.lua")
  local enrol = dofile("enrol.lua")

  test("explicit config wins over a saved answer and over discovery", function()
    local value, source = plug.resolve(7, 9, 4)
    equal(value, 7)
    equal(source, "config")
    value, source = plug.resolve({ x = 1, y = 2, z = 3 }, nil, { x = 9, y = 9, z = 9 })
    equal(value.x, 1)
    equal(source, "config")
    equal(plug.present(""), false)
    equal(plug.present(0), true)
  end)

  test("one discovery is kept and several discoveries ask", function()
    local value, source = plug.resolve(nil, nil, 12)
    equal(value, 12)
    equal(source, "discover")
    value, source = plug.resolve(nil, nil, { choices = { 4 } })
    equal(value, 4)
    equal(source, "discover")
    value, source = plug.resolve(nil, nil, { choices = { 4, 8 } })
    equal(value, nil)
    equal(source, "ask")
    value, source = plug.resolve(nil, 3, { choices = { 4, 8 } })
    equal(value, 3)
    equal(source, "saved")
  end)

  test("lookup uses the only host and asks when several answer", function()
    local calls = {}
    local env = {
      peripheral = {
        find = function() return { isWireless = function() return true end } end,
        getName = function() return "radio" end,
      },
      rednet = {
        open = function(name) calls.open = name end,
        lookup = function(protocol, host)
          calls.protocol, calls.host = protocol, host
          return 5
        end,
      },
    }
    equal(plug.lookup(env, "fleetserver", "server"), 5)
    equal(calls.open, "radio")
    equal(calls.protocol, "fleetserver")
    env.rednet.lookup = function() return 5, 9 end
    local many = plug.lookup(env, "fleetserver", "server")
    equal(many.choices[1], 5)
    equal(many.choices[2], 9)
    env.rednet.lookup = function() return nil end
    equal(plug.lookup(env, "fleetserver", "server"), nil)
  end)

  test("gps rounds a fix and ignores a miss", function()
    local fix = plug.gps({ gps = { locate = function() return 10.4, 64.6, -3.2 end } })
    equal(fix, { x = 10, y = 65, z = -3 })
    equal(plug.gps({ gps = { locate = function() return nil end } }), nil)
    equal(plug.gps({}), nil)
  end)

  test("one peripheral name is used and several are a choice", function()
    local env = {
      peripheral = {
        getNames = function() return { "left", "top", "monitor_1" } end,
        getType = function(name)
          if name == "left" or name == "top" then return "inventory" end
          if name == "monitor_1" then return "monitor" end
        end,
      },
    }
    equal(plug.names(env, "monitor"), "monitor_1")
    local chests = plug.names(env, "inventory")
    equal(chests.choices[1], "left")
    equal(chests.choices[2], "top")
  end)

  test("a prompt accepts a tap or a digit and refuses a typed secret", function()
    local io = {
      pull = function() return "mouse_click", 1, 4, 4 end,
    }
    local picked = plug.ask(io, {
      title = "Miner", question = "Fleet server", kind = "choice",
      choices = { { value = 4, label = "server 4" }, { value = 9, label = "server 9" } },
    })
    equal(picked, 9)
    assert(not table.concat(io.shown, "\n"):find("secret", 1, true), "prompt mentioned a secret")
    io.pull = function() return "char", "1" end
    equal(plug.ask(io, { kind = "choice", choices = { 4, 9 } }), 4)
    local refused, why = plug.ask(io, { kind = "secret", question = "paste the secret" })
    equal(refused, nil)
    equal(why, "secrets are not typed")
    io.read = function() return "12" end
    io.readHidden = function() return "this-is-a-private-key" end
    io.shown = nil
    equal(plug.ask(io, { kind = "hidden", question = "API key" }), "this-is-a-private-key")
    assert(not table.concat(io.shown, "\n"):find("this-is-a-private-key", 1, true), "hidden answer was shown")
  end)

  test("a coordinate prompt keeps the typed block", function()
    local answers = { "10", "64", "-20" }
    local io = { read = function() return table.remove(answers, 1) end }
    equal(plug.ask(io, { kind = "coord", title = "GPS host" }), { x = 10, y = 64, z = -20 })
  end)

  test("fill does not discover when the config already has the value", function()
    local called = false
    local value, source = plug.fill(11, nil, function()
      called = true
      return 22
    end, function() return 33 end)
    equal(value, 11)
    equal(source, "config")
    equal(called, false)
    value, source = plug.fill(nil, nil, function() return { choices = { 2, 3 } } end, function(spec)
      equal(#spec.choices, 2)
      return spec.choices[2]
    end, { title = "Panel", question = "Which host?" })
    equal(value, 3)
    equal(source, "prompt")
  end)

  test("a server secret comes from enrol and is not sent back on the wire", function()
    local store = enrol.empty()
    local issued = enrol.issue(store, 1000, 1, { role = "miner" }, function() return 7 end)
    local sent = {}
    local nonce = "0123456789abcdef"
    local rpc = function(op, fields)
      sent[#sent + 1] = { op = op, fields = fields }
      if op == "enrol-hello" then
        return enrol.hello(store, 1000, 31, fields, 1, function() return 9 end)
      end
      return enrol.claim(store, 1000, 31, fields, 1)
    end
    local claimed, err = plug.claim(enrol, rpc, issued.id .. " " .. issued.code, 31, nonce)
    assert(claimed, err)
    equal(claimed.server, 1)
    local wire = textutils and textutils.serialize(sent) or tostring(sent[1].op) .. tostring(sent[2].op)
    local function dump(value)
      if type(value) ~= "table" then return tostring(value) end
      local parts = {}
      for k, v in pairs(value) do parts[#parts + 1] = tostring(k) .. "=" .. dump(v) end
      return "{" .. table.concat(parts, ",") .. "}"
    end
    wire = dump(sent)
    assert(not wire:find(claimed.secret, 1, true), "pairing key was sent")
    assert(wire:find("enrol-hello", 1, true) and wire:find("enrol-claim", 1, true), "enrol was not used")
    local secret, source, server = plug.takeSecret(nil, nil, function() return claimed end)
    equal(secret, claimed.secret)
    equal(source, "enrol")
    equal(server, 1)
    secret, source = plug.takeSecret("already-paired-secret", claimed.secret)
    equal(secret, "already-paired-secret")
    equal(source, "config")
    local shown = plug.redact({ secret = claimed.secret, server = 1, nested = { pairingKey = claimed.secret } })
    local rendered = dump(shown)
    assert(not rendered:find(claimed.secret, 1, true), "redact left the secret in place")
    equal(shown.server, 1)
    equal(shown.secret, true)
  end)

  test("empty controller slots take the enrol key and a written secret stays", function()
    local controllers = { ["5"] = "kept-controller-secret" }
    local changed = plug.adopt(controllers, {
      ["5"] = { key = "ffffffffffffffff" },
      ["8"] = { key = "new-pairing-key!!" },
      ["9"] = { key = "short" },
    })
    equal(changed, true)
    equal(controllers["5"], "kept-controller-secret")
    equal(controllers["8"], "new-pairing-key!!")
    equal(controllers["9"], nil)
    equal(plug.adopt(controllers, { ["8"] = { key = "other-pairing-key!" } }), false)
  end)
end
