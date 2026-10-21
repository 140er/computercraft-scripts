return function(test, equal)
  local Host = dofile("storage-host.lua")
  local Dep = dofile("lib/stubs/h4c_dep.lua")
  local Buffer = dofile("storage-buffer.lua")

  local function hash(n)
    return string.format("%064x", n)
  end
  local function section(key, rev, at, bytes)
    return { v = 2, key = key, rev = rev, hash = hash(rev), bytes = bytes or 1200, observedAt = at }
  end
  local function disk(total, used)
    local box = { total = total, used = used }
    local fs = {
      getCapacity = function() return box.total end,
      getFreeSpace = function() return box.total - box.used end,
    }
    return box, fs
  end
  local function host(total, used, enabled, now, policy)
    local box, fs = disk(total, used)
    local created, err = Host.create({ enabled = enabled, fs = fs, now = now or 0, policy = policy })
    assert(created, err)
    return created, box
  end

  local A = "abs|minecraft:overworld|1|4|-2"
  local B = "abs|minecraft:overworld|2|4|-2"
  local C = "abs|minecraft:overworld|3|4|-2"
  local D = "abs|minecraft:overworld|4|4|-2"
  local E = "abs|minecraft:overworld|0|4|-2"

  test("an omitted storage flag starts the ledger", function()
    local _, fs = disk(1000000, 0)
    local created, err = Host.create({ fs = fs })
    assert(created, err)
    assert(created.enabled == true)
    assert(Host.lines(created)[1] ~= "Storage ledger is off.")
  end)

  test("storage ledger stays off until enabled", function()
    local full = host(1000000, 1000000, false, 1)
    equal(Host.admit(full, "scan"), { ok = true })
    equal(Host.admit(full, "observe"), { ok = true })
    equal(Host.ledger(full).state, "ok")
    equal(Host.ledger(full).localTotal, 1000000)
    equal(Host.ledger(full).localUsed, 1000000)
    equal(Host.ledger(full).peerTotal, 0)
    equal(Host.ledger(full).peerUsed, 0)
    equal(Host.prompt(full).choices, {})
    equal(Host.prompt(full).chat, false)
    equal(Host.lines(full), { "Storage ledger is off." })
    local result, err = Host.commitForget(full, { v = 1, items = {} })
    equal(result, nil)
    equal(err, "storage ledger is off")
  end)

  test("map writes return capacity at 80 percent of 1000000 bytes and control writes continue", function()
    local server = host(1000000, 799999, true, 1000000)
    equal(Host.ledger(server).state, "ok")
    equal(Host.admit(server, "scan"), { ok = true })
    server, _ = host(1000000, 800000, true, 1000000)
    equal(Host.ledger(server).state, "warn")
    equal(Host.admit(server, "scan"), { ok = false, error = "capacity" })
    equal(Host.admit(server, "section-put"), { ok = false, error = "capacity" })
    equal(Host.admit(server, "observe"), { ok = false, error = "capacity" })
    equal(Host.admit(server, "sync"), { ok = true })
    equal(Host.admit(server, "reserve"), { ok = true })
    equal(Host.admit(server, "start"), { ok = true })
    equal(Host.admit(server, "commit"), { ok = true })
    equal(Host.admit(server, "mine-dig"), { ok = true })
    equal(Host.admit(server, "wh-put"), { ok = true })
    equal(Host.admit(server, "snapshot"), { ok = true })
    local prompt = Host.prompt(server)
    equal(prompt.choices, {
      { id = "forget", label = "Forget old" },
      { id = "expand", label = "Needs storage turtles" },
      { id = "decline", label = "Keep everything" },
    })
    equal(prompt.chat, "Storage is at the limit. Forget old map data, add storage turtles, or keep everything. Nothing is dropped.")
    equal(prompt.glasses, { "Storage at the limit", "Forget, turtles, or keep" })
    for i = 1, #prompt.glasses do assert(#prompt.glasses[i] <= 40, prompt.glasses[i]) end
  end)

  test("control reserve blocks map growth while a move can still commit", function()
    local policy = { v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = false, controlReserve = 950000 }
    local server = host(1000000, 100000, true, 50, policy)
    equal(Host.ledger(server).state, "warn")
    equal(Host.admit(server, "observe"), { ok = false, error = "capacity" })
    equal(Host.admit(server, "commit"), { ok = true })
  end)

  test("decline then preview and commit keep a section that changed and drop only the matching set", function()
    local server = host(1000000, 800000, true, 1000000)
    server.pinned = { { key = E, untilAt = false } }
    equal(Host.decline(server).state, "paused")
    equal(Host.admit(server, "scan"), { ok = false, error = "capacity" })
    equal(Host.admit(server, "sync"), { ok = true })
    equal(Host.prompt(server).choices, {})
    local lines = table.concat(Host.lines(server), "\n")
    assert(lines:find("Expand needs storage turtles.", 1, true), lines)
    assert(lines:find("Map writes are paused.", 1, true), lines)

    assert(Host.putSection(server, section(A, 1, 900000, 1200)))
    assert(Host.putSection(server, section(B, 2, 900000, 800)))
    assert(Host.putSection(server, section(C, 4, 900000, 400)))
    assert(Host.putSection(server, section(D, 3, 900001, 100)))
    assert(Host.putSection(server, section(E, 5, 900000, 50)))
    local preview, err = Host.previewForget(server, 100000)
    assert(preview, err)
    equal(preview.v, 1)
    equal(preview.id, "p:5:1")
    equal(preview.createdAt, 1000000)
    equal(preview.untilAt, 1600000)
    equal(preview.olderThanMs, 100000)
    equal(preview.rev, 5)
    equal(preview.bytes, 2400)
    equal(preview.items, {
      { key = A, rev = 1, hash = hash(1), bytes = 1200 },
      { key = B, rev = 2, hash = hash(2), bytes = 800 },
      { key = C, rev = 4, hash = hash(4), bytes = 400 },
    })

    local changed = section(C, 9, 900000, 400)
    changed.hash = hash(99)
    assert(Host.putSection(server, changed))
    local committed, why = Host.commitForget(server, preview)
    assert(committed, why)
    equal(committed.deleted, { A, B })
    equal(committed.skipped, { { key = C, reason = "mismatch" } })
    equal(Host.readSection(server, A).confidence, "unknown")
    equal(Host.readSection(server, B).confidence, "unknown")
    equal(Host.readSection(server, C), {
      confidence = "observed", key = C, rev = 9, hash = hash(99), bytes = 400, observedAt = 900000,
    })
    equal(Host.readSection(server, D).confidence, "observed")
    equal(Host.readSection(server, E).rev, 5)
    equal(Host.ledger(server).state, "paused")

    local again = Host.commitForget(server, preview)
    equal(again.deleted, {})
    equal(again.skipped, {
      { key = A, reason = "missing" },
      { key = B, reason = "missing" },
      { key = C, reason = "mismatch" },
    })
    equal(Host.readSection(server, C).rev, 9)
  end)

  test("a section pinned after the preview is skipped and an expired preview deletes nothing", function()
    local server = host(1000000, 800000, true, 1000000)
    assert(Host.putSection(server, section(A, 1, 1, 10)))
    local preview = assert(Host.previewForget(server, 1))
    equal(preview.items[1].key, A)
    server.pinned = { { key = A, untilAt = 1000001 } }
    local committed = assert(Host.commitForget(server, preview))
    equal(committed.deleted, {})
    equal(committed.skipped, { { key = A, reason = "pinned" } })
    equal(Host.readSection(server, A).confidence, "observed")

    server.pinned = {}
    server.now = preview.untilAt
    local expired = assert(Host.commitForget(server, preview))
    equal(expired.deleted, {})
    equal(expired.skipped, { { key = A, reason = "expired" } })
    equal(Host.readSection(server, A).rev, 1)
  end)

  test("forget preview rejects an unknown version and a corrupt item deletes nothing", function()
    local server = host(1000000, 800000, true, 1000)
    assert(Host.putSection(server, section(A, 1, 1, 10)))
    local preview = assert(Host.previewForget(server, 1))
    preview.items[1].hash = "not-a-hash"
    local committed, err = Host.commitForget(server, preview)
    equal(committed, nil)
    equal(err, "bad preview item")
    equal(Host.readSection(server, A).confidence, "observed")
    preview.v = 2
    preview.items[1].hash = hash(1)
    committed, err = Host.commitForget(server, preview)
    equal(committed, nil)
    equal(err, "unknown preview v")
    equal(Host.readSection(server, A).rev, 1)
    local bad, why = Host.putSection(server, { v = 1, key = A, rev = 1, hash = hash(1), bytes = 1, observedAt = 1 })
    equal(bad, nil)
    equal(why, "unknown section v")
  end)

  test("storage policy rejects an unknown version and refuses to forget without an age", function()
    local created, err = Host.create({ policy = { v = 2, mode = "ask", warnAt = 0.8, forgetOlderThanMs = false, controlReserve = 1 } })
    equal(created, nil)
    equal(err, "unknown policy v")
    for _, policy in ipairs({
      { v = 1, mode = "auto", warnAt = 0.8, forgetOlderThanMs = false, controlReserve = 1 },
      { v = 1, mode = "ask", warnAt = 0, forgetOlderThanMs = false, controlReserve = 1 },
      { v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = 0, controlReserve = 1 },
      { v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = false, controlReserve = -1 },
      { v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = true, controlReserve = 1 },
    }) do
      created, err = Host.create({ policy = policy })
      equal(created, nil)
      equal(err, "invalid storage policy")
    end
    local server = host(1000000, 800000, true, 10)
    local preview, why = Host.previewForget(server)
    equal(preview, nil)
    equal(why, "age required")
    server = host(1000000, 800000, true, 1000000, { v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = 100000, controlReserve = 65536 })
    assert(Host.putSection(server, section(A, 1, 900000, 10)))
    assert(Host.putSection(server, section(D, 2, 900001, 10)))
    preview = assert(Host.previewForget(server))
    equal(preview.items, { { key = A, rev = 1, hash = hash(1), bytes = 10 } })
  end)

  test("ledger growth uses the sample window and ignores a drop", function()
    local server, box = host(1000000, 100000, true, 0)
    equal(Host.note(server).growthPerHour, 0)
    server.now = 3600000
    box.used = 500000
    equal(Host.note(server).growthPerHour, 400000)
    equal(Host.ledger(server).state, "ok")
    server.samples = {}
    server.now = 0
    box.used = 500000
    Host.note(server)
    server.now = 3600000
    box.used = 100000
    equal(Host.note(server).growthPerHour, 0)
    equal(Host.ledger(server).state, "ok")
  end)

  test("the turtle buffer keeps every observation and stops new mining when it is full", function()
    local server, box = host(1000000, 800000, true, 5)
    local buf = assert(Host.openBuffer(server))
    equal(buf.budget, 200000 - 65536)
    local kept = { id = 1, bytes = 100, name = "minecraft:stone" }
    local accepted, effects = Host.pushObs(server, kept)
    equal(accepted, true)
    equal(effects, {})
    equal(kept.name, "minecraft:stone")
    box.used = 1000000
    local still = { id = 2, bytes = 50, name = "minecraft:dirt" }
    accepted, effects = Host.pushObs(server, still)
    equal(accepted, true)
    equal(effects, {})
    equal(still.name, "minecraft:dirt")
    equal(#server.buffer.items, 2)
    local extra = { id = 3, bytes = server.buffer.budget, name = "minecraft:sand" }
    accepted, effects = Host.pushObs(server, extra)
    equal(accepted, false)
    equal(extra.name, "minecraft:sand")
    equal(effects, {
      { op = "stop_mining" },
      { op = "head_home" },
      { op = "notify", panel = true, glasses = true, chat = true,
        text = "Disk is full. This turtle stopped new mining and is heading home. Nothing was dropped." },
    })
    local repeatObs = { id = 4, bytes = server.buffer.budget, name = "minecraft:gravel" }
    accepted, effects = Host.pushObs(server, repeatObs)
    equal(accepted, false)
    equal(effects, {})
    equal(#server.buffer.items, 2)
    equal(server.buffer.items[1].name, "minecraft:stone")
    equal(Host.openBuffer(server).items[1].id, 1)
  end)

  test("a later observation that fits is kept after the stop notice", function()
    local buf = assert(Buffer.open(20, 10))
    equal(buf.budget, 10)
    local accepted, effects = Buffer.push(buf, { id = 1, bytes = 6, name = "minecraft:stone" })
    equal(accepted, true)
    equal(effects, {})
    accepted, effects = Buffer.push(buf, { id = 2, bytes = 6, name = "minecraft:dirt" })
    equal(accepted, false)
    equal(effects[1].op, "stop_mining")
    equal(effects[2].op, "head_home")
    equal(effects[3].panel, true)
    equal(effects[3].glasses, true)
    equal(effects[3].chat, true)
    accepted, effects = Buffer.push(buf, { id = 3, bytes = 4, name = "minecraft:sand" })
    equal(accepted, true)
    equal(effects, {})
    equal(buf.bytes, 10)
    equal(buf.items[1].name, "minecraft:stone")
    equal(buf.items[2].name, "minecraft:sand")
  end)

  test("loading a buffer rejects an unknown version and does not drop saved observations", function()
    local server = host(1000000, 1000000, true, 1)
    local loaded, err = Host.loadBuffer(server, { v = 2, items = {}, bytes = 0, budget = 0, full = false })
    equal(loaded, nil)
    equal(err, "unknown buffer v")
    loaded = assert(Host.loadBuffer(server, {
      v = 1, bytes = 10, budget = 10, full = false,
      items = { { id = 7, bytes = 10, name = "minecraft:stone" } },
    }))
    equal(#loaded.items, 1)
    equal(loaded.items[1].name, "minecraft:stone")
    equal(loaded.bytes, 10)
    local accepted = Host.pushObs(server, { id = 8, bytes = 1, name = "minecraft:dirt" })
    equal(accepted, false)
    equal(#server.buffer.items, 1)
    equal(server.buffer.items[1].name, "minecraft:stone")
  end)

  test("panel and glasses remind while the choice is still open", function()
    equal(Host.due(false, 10), true)
    equal(Host.due(0, 299999), false)
    equal(Host.due(0, 300000), true)
    local server = host(1000000, 800000, true, 1)
    equal(Host.expand(server).state, "paused")
    local lines = table.concat(Host.lines(server), "\n")
    assert(lines:find("Expand needs storage turtles.", 1, true), lines)
    assert(lines:find("Peers 0 of 0", 1, true), lines)
  end)

  test("H4a H4b1 and H5 stubs classify writes, forget once, and pin unexpired keys", function()
    equal(Dep.h4a.kind("scan"), "map")
    equal(Dep.h4a.kind("observe"), "map")
    equal(Dep.h4a.kind("sync"), "control")
    equal(Dep.h4a.kind("mine-dig"), "control")
    equal(Dep.h4a.kind("wh-put"), "control")
    equal(Dep.h4a.kind(""), nil)
    local pins = Dep.h5.pinnedKeys({
      { key = "live", untilAt = 50 },
      { key = "done", untilAt = 10 },
      { key = "held", untilAt = false },
    }, 10)
    equal(pins.live, true)
    equal(pins.done, nil)
    equal(pins.held, true)
    local store = Dep.h4b1.new()
    Dep.h4b1.put(store, section(A, 1, 1, 10))
    equal(Dep.h4b1.forget(store, A, 1, hash(1)), "deleted")
    equal(Dep.h4b1.forget(store, A, 1, hash(1)), "skipped")
    equal(Dep.h4b1.read(store, A), { confidence = "unknown" })
    local usage = Dep.h4a.usage({
      getCapacity = function() return "unlimited" end,
      getFreeSpace = function() return "unlimited" end,
    })
    equal(usage.unlimited, true)
    equal(usage.peerUsed, 0)
  end)

  test("malformed storage messages do not throw or delete a section", function()
    local server = host(1000000, 800000, true, 10)
    assert(Host.putSection(server, section(A, 1, 1, 10)))
    for n = 1, 20 do
      local junk = ({ "nope", n, true, {}, { v = n } })[(n % 5) + 1]
      assert(pcall(function()
        Host.create({ policy = junk, enabled = true })
        Host.putSection(server, junk)
        Host.commitForget(server, junk)
        Host.previewForget(server, junk)
        Host.pushObs(server, junk)
      end))
    end
    equal(Host.readSection(server, A).confidence, "observed")
    equal(Host.readSection(server, A).rev, 1)
  end)
end
