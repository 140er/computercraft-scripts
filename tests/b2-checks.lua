return function(test, equal)
  local P = dofile("problems.lua")
  local B1 = dofile("lib/stubs/b2_dep.lua")

  local function pose(conf, dim)
    return {
      v = 1, frame = "abs", yAbs = true, dim = dim or "minecraft:overworld",
      x = 10, y = 64, z = 20, h = 0, conf = conf or "certain", src = "reckoned", anchoredAt = 1,
    }
  end

  local function lease(untilAt, reserve)
    return {
      v = 2, id = "7:mine:1234", turtle = 17, boot = "boot", epoch = "7",
      issuedAt = 0, untilAt = untilAt or 50000, issuedRev = 8, frame = "abs",
      home = pose("certain"), fuelReserve = reserve or 120,
    }
  end

  local function journal(bytes, budget)
    return {
      v = 1, lease = "7:mine:1234", committed = 3, acked = 3,
      bytes = bytes or 100, budget = budget or 90000,
    }
  end

  local function ctx(problem, settings, patch)
    local value = {
      now = 1000, settings = settings or {}, pose = pose(), lease = lease(),
      journal = journal(), turtle = 17, problem = problem,
    }
    for key, item in pairs(patch or {}) do value[key] = item end
    return value
  end

  local function decide(problem, settings, patch)
    local result, err = P.decide(ctx(problem, settings, patch))
    assert(result, err)
    return result
  end

  local function occupied(lastName, lastCount)
    local slots = {}
    for index = 1, 15 do slots[index] = { name = "minecraft:stone", count = 64 } end
    slots[16] = { name = lastName or "minecraft:cobblestone", count = lastCount or 64 }
    return slots
  end

  local function fields(result, expect)
    equal(result.state, expect.state, expect.label or result.code)
    equal(result.decision, expect.decision, "decision")
    equal(result.dig, expect.dig == true, "dig")
    equal(result.move, expect.move == true, "move")
    equal(result.enter, false, "enter")
    equal(result.action, expect.action or false, "action")
    equal(result.conf, expect.conf or false, "conf")
    if expect.mark == nil then equal(result.mark, false, "mark")
    else equal(result.mark, expect.mark, "mark") end
  end

  test("registry bounds stay off the safety invariants", function()
    local keys = {}
    for _, spec in ipairs(P.registry()) do keys[spec.key] = spec.default end
    equal(keys.compactInventory, false)
    equal(keys.filteredTrash, false)
    equal(keys.fuelReturnMargin, 120)
    equal(keys.unbreakableDetour, false)
    equal(keys.avoidFluids, false)
    equal(keys.containFluids, false)
    equal(keys.fallingRetry, false)
    equal(keys.blockedRetry, false)
    equal(keys.rerouteBlocked, false)
    equal(keys.reanchor, false)
    equal(keys.stuckBackoff, false)
    equal(keys.stuckSkip, false)
    for _, name in ipairs({ "digRequiresCertain", "corridorClear", "leaseExpiry", "journalBudget", "pathThroughFluid" }) do
      equal(keys[name], nil, name)
    end
    local settings = assert(P.parse({}))
    equal(settings.fallingMaxRetries, 8)
    equal(settings.maxFluidBlocks, 16)
    equal(settings.navMaxCells, 2048)
    assert(not P.parse({ fuelReturnMargin = -1 }))
    assert(not P.parse({ fuelReturnMargin = 100001 }))
    assert(not P.parse({ fallingMaxRetries = 0 }))
    assert(not P.parse({ fallingMaxRetries = 33 }))
    assert(not P.parse({ detourMaxCells = 0 }))
    assert(not P.parse({ navMaxCells = 10, detourMaxCells = 64 }))
    assert(not P.parse({ mystery = true }))
    local names = {}
    for index = 1, 65 do names[index] = "minecraft:item_" .. index end
    assert(not P.parse({ trashItems = names }))
    assert(not P.parse({ trashItems = { "dirt" } }))
    assert(P.parse({ fuelReturnMargin = 0, trashItems = { "minecraft:dirt" } }))
  end)

  test("full inventory returns to drop off when compact and trash are off", function()
    local result = decide({ code = "full_inventory", slots = occupied() }, {})
    fields(result, { state = "return", decision = "return", move = true })
    equal(result.entry.kind, "problem")
    equal(result.entry.decision, "return")
    equal(result.entry.phase, "intent")
  end)

  test("full inventory compacts two partial stacks when compact is on", function()
    local slots = occupied("minecraft:cobblestone", 10)
    slots[15] = { name = "minecraft:cobblestone", count = 10 }
    local result = decide({ code = "full_inventory", slots = slots }, { compactInventory = true })
    fields(result, { state = "compact", decision = "retry", action = "compact" })
    equal(result.dig, false)
  end)

  test("full inventory trashes a filtered item when compact cannot", function()
    local result = decide({ code = "full_inventory", slots = occupied("minecraft:dirt", 64) }, {
      filteredTrash = true, trashItems = { "minecraft:dirt" },
    })
    fields(result, { state = "trash", decision = "retry", action = "trash" })
  end)

  test("a leg stays when fuel covers the way home and the reserve", function()
    local result = decide({ code = "fuel", fuel = 135, leg = 5, home = 10 }, { fuelReturnMargin = 120 })
    fields(result, { state = "clear", decision = false })
    equal(result.need, 135)
    equal(result.entry, false)
  end)

  test("a leg returns when fuel is short of the reserve", function()
    local result = decide({ code = "fuel", fuel = 134, leg = 5, home = 10 }, { fuelReturnMargin = 120 })
    fields(result, { state = "return", decision = "return", move = true })
    equal(result.need, 135)
  end)

  test("unlimited fuel does not send the turtle home", function()
    local result = decide({ code = "fuel", fuel = "unlimited", leg = 5, home = 10 }, {})
    fields(result, { state = "clear", decision = false })
  end)

  test("the reserve keeps the larger of the setting and the lease", function()
    local result = decide({ code = "fuel", fuel = 214, leg = 5, home = 10 }, { fuelReturnMargin = 120 },
      { lease = lease(50000, 200) })
    fields(result, { state = "return", decision = "return", move = true })
    equal(result.need, 215)
  end)

  test("bedrock marks the cell and reroutes inside the detour bound", function()
    local result = decide({
      code = "bedrock", name = "minecraft:bedrock", detour = 4,
      cell = { x = 11, y = 64, z = 20 },
    }, { unbreakableDetour = true, detourMaxCells = 64 })
    fields(result, {
      state = "reroute", decision = "reroute", move = true,
      mark = { v = 1, x = 11, y = 64, z = 20, kind = "unbreakable" },
    })
    equal(result.dig, false)
    equal(result.entry.decision, "reroute")
  end)

  test("bedrock returns without a mark when detour is off", function()
    local result = decide({
      code = "bedrock", name = "minecraft:bedrock", cell = { x = 11, y = 64, z = 20 },
    }, {})
    fields(result, { state = "return", decision = "return", move = true })
  end)

  test("bedrock returns when the detour is longer than the bound", function()
    local result = decide({
      code = "bedrock", detour = 65, cell = { x = 1, y = 2, z = 3 },
    }, { unbreakableDetour = true, detourMaxCells = 64 })
    fields(result, { state = "return", decision = "return", move = true })
  end)

  test("lava is contained without entering the source", function()
    local result = decide({
      code = "fluid", name = "minecraft:lava", placed = 0, hasBlock = true,
      cell = { x = 12, y = 64, z = 20 },
    }, { containFluids = true, maxFluidBlocks = 16 })
    fields(result, {
      state = "contain", decision = "retry", action = "contain",
      mark = { v = 1, x = 12, y = 64, z = 20, kind = "fluid" },
    })
    equal(result.blocksPath, true)
    equal(result.dig, false)
    equal(result.enter, false)
  end)

  test("water and lava return and do not enter when fluid handling is off", function()
    for _, name in ipairs({ "minecraft:lava", "minecraft:water" }) do
      local result = decide({
        code = "fluid", name = name, placed = 0, hasBlock = true, cell = { x = 1, y = 2, z = 3 },
      }, {})
      fields(result, { state = "return", decision = "return", move = true, label = name })
      equal(result.blocksPath, true, name)
      equal(result.enter, false, name)
    end
  end)

  test("flowing water is not plugged", function()
    local result = decide({
      code = "fluid", name = "minecraft:flowing_water", placed = 0, hasBlock = true,
      cell = { x = 1, y = 2, z = 3 },
    }, { containFluids = true, avoidFluids = true })
    fields(result, {
      state = "reroute", decision = "reroute", move = true,
      mark = { v = 1, x = 1, y = 2, z = 3, kind = "fluid" },
    })
    equal(result.action, false)
    equal(result.blocksPath, true)
  end)

  test("contain stops at the fluid block bound", function()
    local result = decide({
      code = "fluid", name = "minecraft:lava", placed = 16, hasBlock = true,
      cell = { x = 1, y = 2, z = 3 },
    }, { containFluids = true, maxFluidBlocks = 16, avoidFluids = false })
    fields(result, { state = "return", decision = "return", move = true })
    equal(result.blocksPath, true)
  end)

  test("gravel retries under the bound and returns at the bound", function()
    local under = decide({ code = "gravel", name = "minecraft:gravel", attempts = 7 },
      { fallingRetry = true, fallingMaxRetries = 8 })
    fields(under, { state = "retry", decision = "retry", dig = true })
    equal(under.attempts, 8)
    local done = decide({ code = "gravel", name = "minecraft:sand", attempts = 8 },
      { fallingRetry = true, fallingMaxRetries = 8 })
    fields(done, { state = "return", decision = "return", move = true })
    equal(done.dig, false)
  end)

  test("gravel returns immediately when falling retry is off", function()
    local result = decide({ code = "gravel", name = "minecraft:gravel", attempts = 0 }, {})
    fields(result, { state = "return", decision = "return", move = true })
  end)

  test("a mob retries under the bound and then reroutes", function()
    local under = decide({ code = "mob", attempts = 0, detour = 4 },
      { blockedRetry = true, blockedMaxRetries = 3, rerouteBlocked = true, rerouteMaxCells = 128 })
    fields(under, { state = "retry", decision = "retry", action = "attack" })
    equal(under.dig, false)
    local around = decide({ code = "mob", attempts = 3, detour = 4 },
      { blockedRetry = true, blockedMaxRetries = 3, rerouteBlocked = true })
    fields(around, { state = "reroute", decision = "reroute", move = true })
  end)

  test("a mob returns when retry and reroute are off", function()
    local result = decide({ code = "mob", attempts = 0 }, {})
    fields(result, { state = "return", decision = "return", move = true })
    equal(result.action, false)
  end)

  test("a dimension change is lost and does not dig", function()
    local result = decide({ code = "dimension", dim = "minecraft:the_nether", attempts = 0 }, {})
    fields(result, { state = "lost", decision = "wait", conf = "lost" })
    equal(result.dig, false)
    equal(result.move, false)
  end)

  test("reanchor leaves a dimension change lost", function()
    local result = decide({ code = "dimension", dim = "minecraft:the_nether", attempts = 0 },
      { reanchor = true, reanchorMaxAttempts = 3 })
    fields(result, { state = "lost", decision = "retry", action = "reanchor", conf = "lost" })
    equal(result.dig, false)
    equal(result.move, false)
  end)

  test("pickup with a matching fingerprint and a resolved move is suspect", function()
    local result = decide({
      code = "pickup", fingerprint = "match", unresolved = false, attempts = 0,
    }, {})
    fields(result, { state = "suspect", decision = "wait", conf = "suspect" })
    equal(result.dig, false)
  end)

  test("pickup with a mismatch or an unresolved move is lost", function()
    local mismatch = decide({
      code = "pickup", fingerprint = "mismatch", unresolved = false, attempts = 0,
    }, {})
    fields(mismatch, { state = "lost", decision = "wait", conf = "lost" })
    local unresolved = decide({
      code = "pickup", fingerprint = "match", unresolved = true, attempts = 0,
    }, {})
    fields(unresolved, { state = "lost", decision = "wait", conf = "lost" })
  end)

  test("stuck backs off and then marks and skips the cell", function()
    local cell = { x = 4, y = 5, z = 6 }
    local back = decide({ code = "stuck", attempts = 0, cell = cell },
      { stuckBackoff = true, stuckMaxAttempts = 3, stuckSkip = true })
    fields(back, { state = "backoff", decision = "retry", action = "backoff", move = true })
    local skip = decide({ code = "stuck", attempts = 3, cell = cell },
      { stuckBackoff = true, stuckMaxAttempts = 3, stuckSkip = true })
    fields(skip, {
      state = "skip", decision = "skip",
      mark = { v = 1, x = 4, y = 5, z = 6, kind = "stuck" },
    })
    equal(skip.dig, false)
  end)

  test("stuck returns when backoff and skip are off", function()
    local result = decide({ code = "stuck", attempts = 0, cell = { x = 1, y = 1, z = 1 } }, {})
    fields(result, { state = "return", decision = "return", move = true })
  end)

  test("a corridor cell is not skipped", function()
    local result = decide({
      code = "stuck", attempts = 3, corridor = true, cell = { x = 4, y = 5, z = 6 },
    }, { stuckSkip = true, stuckBackoff = true, stuckMaxAttempts = 3 })
    fields(result, { state = "corridor", decision = "return", move = true })
    equal(result.mark, false)
  end)

  test("an expired lease waits instead of digging or going home", function()
    local digging = decide({ code = "gravel", name = "minecraft:gravel", attempts = 0 },
      { fallingRetry = true }, { lease = lease(1000) })
    fields(digging, { state = "expired", decision = "wait" })
    local going = decide({ code = "fuel", fuel = 1, leg = 5, home = 10 }, {}, { lease = lease(1000) })
    fields(going, { state = "expired", decision = "wait" })
    equal(going.move, false)
  end)

  test("a return-only grant sends digging home", function()
    local granted = lease(1000)
    granted.returnOnly = true
    local result = decide({ code = "gravel", name = "minecraft:gravel", attempts = 0 },
      { fallingRetry = true }, { lease = granted })
    fields(result, { state = "return_only", decision = "return", move = true })
    equal(result.dig, false)
  end)

  test("the journal at 80 percent sends new work home", function()
    local result = decide({ code = "gravel", name = "minecraft:gravel", attempts = 0 },
      { fallingRetry = true }, { journal = journal(800, 1000) })
    fields(result, { state = "journal_home", decision = "return", move = true })
    equal(result.dig, false)
    equal(result.entry.decision, "return")
  end)

  test("a full journal waits and writes nothing", function()
    local result = decide({ code = "gravel", name = "minecraft:gravel", attempts = 0 },
      { fallingRetry = true }, { journal = journal(100, 100) })
    fields(result, { state = "journal_full", decision = "wait" })
    equal(result.entry, false)
    equal(result.journal, false)
  end)

  test("expired lease wins over the journal home rule", function()
    local result = decide({ code = "gravel", name = "minecraft:gravel", attempts = 0 },
      { fallingRetry = true }, { lease = lease(1000), journal = journal(800, 1000) })
    fields(result, { state = "expired", decision = "wait" })
  end)

  test("a suspect pose does not dig gravel", function()
    local result = decide({ code = "gravel", name = "minecraft:gravel", attempts = 0 },
      { fallingRetry = true }, { pose = pose("suspect") })
    fields(result, { state = "suspect", decision = "wait", conf = "suspect" })
    equal(result.dig, false)
  end)

  test("a lost pose does not start the trip home", function()
    local result = decide({ code = "fuel", fuel = 1, leg = 5, home = 10 }, {}, { pose = pose("lost") })
    fields(result, { state = "lost", decision = "wait", conf = "lost" })
    equal(result.move, false)
  end)

  test("the same problem seq does not grow the journal", function()
    local first = decide({ code = "mob", attempts = 9 }, {})
    local again = decide({ code = "mob", attempts = 9 }, {}, {
      journal = first.journal, seq = first.entry.seq,
    })
    equal(again.journal.committed, first.journal.committed)
    equal(again.journal.bytes, first.journal.bytes)
    equal(again.entry.decision, first.entry.decision)
    local head, entry = B1.commit(first.journal, first.entry.seq)
    equal(entry.phase, "done")
    local _, second = B1.commit(head, first.entry.seq)
    equal(second.phase, "done")
    equal(head.committed, first.journal.committed)
  end)
end
