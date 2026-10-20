-- H4b2 strata tests. Behavior through the public module API.

return function(test, equal)
  local S = dofile("strata.lua")
  local DIM = "minecraft:overworld"

  local function P(x, y, z, frame, yAbs)
    return { frame = frame or "abs", yAbs = yAbs ~= false, dim = DIM, x = x, y = y, z = z }
  end

  local function samplesFor(rx, rz)
    local out, x0, z0 = {}, rx * 64, rz * 64
    for dx = 0, 7 do
      for dz = 0, 7 do
        local x, z = x0 + dx * 2, z0 + dz * 2
        local function add(y, name)
          local s = P(x, y, z)
          s.name = name
          out[#out + 1] = s
        end
        add(65, "minecraft:air")
        add(64, "minecraft:dirt")
        add(63, "minecraft:dirt")
        add(62, "minecraft:dirt")
        add(61, "minecraft:dirt")
        add(20, "minecraft:stone")
        add(-5, "minecraft:deepslate")
      end
    end
    local stone, deep = P(x0, 0, z0), P(x0, 8, z0)
    stone.name, deep.name = "minecraft:stone", "minecraft:deepslate"
    out[#out + 1] = stone
    out[#out + 1] = deep
    return out
  end

  test("strata flag defaults off and ignores lookalike values", function()
    equal(S.DEFAULT_ON, false)
    equal(S.new({}).enabled, false)
    equal(S.new({ strata = false }).enabled, false)
    equal(S.new({ strata = 1 }).enabled, false)
    equal(S.new({ strata = "true" }).enabled, false)
    equal(S.new({ strata = true }).enabled, true)
  end)

  test("relative frames without world y and other dimensions do not calibrate", function()
    local store = S.new({ strata = true })
    local rel = samplesFor(0, 0)
    for _, s in ipairs(rel) do s.frame, s.yAbs = "f:9:100", false end
    local base, err = S.calibrate(store, "f:9:100|" .. DIM .. "|0|0", rel, 10)
    equal(base, nil)
    equal(err, "sample")
    local nether = samplesFor(0, 0)
    for _, s in ipairs(nether) do s.dim = "minecraft:the_nether" end
    base, err = S.calibrate(store, "abs|minecraft:the_nether|0|0", nether, 10)
    equal(base, nil)
    equal(err, "sample")
    equal(S.new({}).enabled, false)
    base, err = S.calibrate(S.new({}), "abs|" .. DIM .. "|0|0", samplesFor(0, 0), 10)
    equal(base, nil)
    equal(err, "disabled")
  end)

  test("abs and yAbs frames publish a frozen overworld baseline", function()
    local store = S.new({ strata = true })
    local base = assert(S.calibrate(store, "abs|" .. DIM .. "|0|0", samplesFor(0, 0), 50))
    equal(base.frozen, true)
    equal(base.ver, 1)
    equal(base.fillerTo.dirt, 3)
    equal(base.blendLo, 0)
    equal(base.blendHi, 8)
    equal(S.predictName(base, 0, 65, 0), "minecraft:air")
    equal(S.predictName(base, 0, 64, 0), "minecraft:dirt")
    equal(S.predictName(base, 0, 61, 0), "minecraft:dirt")
    equal(S.predictName(base, 0, 20, 0), "minecraft:stone")
    equal(S.predictName(base, 0, -5, 0), "minecraft:deepslate")
    equal(S.predictName(base, 0, 2, 0), "minecraft:deepslate")
    equal(S.predictName(base, 0, 4, 0), "minecraft:stone")
    local yAbs = samplesFor(0, 0)
    for _, s in ipairs(yAbs) do s.frame = "f:4:200" end
    local keyed = "f:4:200|" .. DIM .. "|0|0"
    local other = assert(S.calibrate(S.new({ strata = true }), keyed, yAbs, 60))
    equal(other.frame, "f:4:200")
    equal(other.frozen, true)
  end)

  test("predicted air is an estimate only and never a walk", function()
    local store = S.new({ strata = true })
    assert(S.calibrate(store, "abs|" .. DIM .. "|0|0", samplesFor(0, 0), 1))
    local above = P(2, 70, 2)
    equal(S.lookup(store, above), "predicted")
    equal(select(2, S.lookup(store, above)), "minecraft:air")
    equal(S.allowsWalk(store, above), false)
    equal(S.estimateCost(store, above), 4)
    local off = S.new({})
    assert(S.calibrate(S.new({ strata = true }), "abs|" .. DIM .. "|0|0", samplesFor(0, 0), 1))
    -- A disabled store has no baseline, so the same cell is unknown.
    equal(S.lookup(off, above), "unknown")
    equal(S.allowsWalk(off, above), false)
    equal(S.estimateCost(off, above), nil)
  end)

  test("flag off keeps observed names and hides prediction", function()
    local store = S.new({})
    assert(S.observe(store, P(3, 10, 3), "minecraft:diamond_ore", { at = 5, rev = 2 }))
    equal(S.lookup(store, P(3, 10, 3)), "observed")
    equal(select(2, S.lookup(store, P(3, 10, 3))), "minecraft:diamond_ore")
    equal(S.lookup(store, P(4, 10, 3)), "unknown")
    equal(S.sectionCodec(store), "rle/1")
    local back = assert(S.decode(S.encode(store)))
    equal(back.enabled, false)
    equal(select(2, S.lookup(back, P(3, 10, 3))), "minecraft:diamond_ore")
  end)

  test("sparse and rle codecs round trip and reject bad input", function()
    local palette = { "=", "minecraft:air", "minecraft:diamond_ore" }
    local cells = { [1] = "minecraft:air", [4096] = "minecraft:diamond_ore" }
    local raw = assert(S.encodeCells("sparse/1", palette, cells))
    equal(raw, string.char(0, 1, 2, 16, 0, 3))
    equal(S.decodeCells("sparse/1", palette, raw), cells)
    local full = {}
    for i = 1, 4096 do full[i] = "minecraft:air" end
    full[10] = "minecraft:diamond_ore"
    local rle = assert(S.encodeCells("rle/1", palette, full))
    equal(S.decodeCells("rle/1", palette, rle), full)
    assert(not S.decodeCells("sparse/1", palette, string.char(0, 1, 0)))
    local unknown = assert(S.decodeCells("rle/1", {}, string.char(0x10, 0, 0)))
    equal(next(unknown), nil)
    assert(not S.decodeCells("rle/1", palette, string.char(0, 1, 0)))
    assert(not S.decode("nope"))
  end)

  test("mining progress stays a proposal until the air is observed", function()
    local store = S.new({ strata = true })
    local task = {
      frame = "abs", yAbs = true, progress = 4,
      min = { dim = DIM, x = 1, y = -58, z = 0 },
      max = { dim = DIM, x = 1, y = -58, z = 8 },
      by = 17, lease = "7:mine:12", seq = 3, rev = 9, at = 100,
    }
    local proposal = assert(S.ingestMining(store, task, nil))
    equal(proposal.installed, false)
    equal(#store.regions, 0)
    local obs = {}
    for z = 0, 3 do obs[#obs + 1] = { x = 1, y = -58, z = z, name = "minecraft:air" } end
    local installed = assert(S.ingestMining(store, task, obs))
    equal(installed.installed, true)
    equal(S.allowsWalk(store, P(1, -58, 2)), true)
    equal(S.lookup(store, P(1, -58, 4)), "unknown")
  end)

  test("committed moves and done journal entries coalesce on a straight line", function()
    local store = S.new({ strata = true })
    local function mv(x, x2, phase)
      return {
        phase = phase, by = 4, lease = "online:1", seq = x + 1, rev = 2, at = 8,
        from = P(x, 5, 5), to = P(x2, 5, 5),
      }
    end
    assert(S.ingestMove(store, mv(0, 1, "commit")))
    assert(S.ingestMove(store, mv(1, 2, "commit")))
    assert(S.ingestMove(store, mv(2, 3, "done")))
    local n = 0
    for _, region in pairs(store.regions) do n = n + #region.segments end
    equal(n, 1)
    equal(S.allowsWalk(store, P(0, 5, 5)), true)
    equal(S.allowsWalk(store, P(3, 5, 5)), true)
    assert(not S.ingestMove(store, mv(0, 1, "intent")))
    local pending = assert(S.ingestJournal(store, {
      v = 1, kind = "move", phase = "intent", seq = 1, lease = "online:1", at = 1,
      frame = "abs", from = P(9, 5, 5), to = P(10, 5, 5),
    }))
    equal(pending, true)
    assert(S.ingestJournal(store, {
      v = 1, kind = "dig", phase = "done", seq = 2, lease = "online:1", at = 2, rev = 3, by = 4,
      from = P(8, 5, 5), to = P(9, 5, 5),
    }))
    equal(S.allowsWalk(store, P(9, 5, 5)), true)
    assert(S.ingestJournal(store, {
      v = 1, kind = "observe", phase = "done", seq = 3, lease = "online:1", at = 3,
      cell = P(8, 6, 5), name = "minecraft:diamond_ore",
    }))
    equal(select(2, S.lookup(store, P(8, 6, 5))), "minecraft:diamond_ore")
  end)

  test("a segment splits on a region boundary and an inspected face is observed", function()
    local store = S.new({ strata = true })
    assert(S.calibrate(store, "abs|" .. DIM .. "|0|0", samplesFor(0, 0), 1))
    assert(S.calibrate(store, "abs|" .. DIM .. "|1|0", samplesFor(1, 0), 1))
    local parts = assert(S.addSegment(store, {
      frame = "abs", dim = DIM, yAbs = true, x = 60, y = -20, z = 2, d = 1, n = 8,
      inspected = false, by = 1, lease = "7:mine:1", seq = 1, rev = 1, at = 1,
    }))
    equal(#parts, 2)
    -- One-cell tunnel with explicit wall observations, then mark inspected.
    local cell = P(4, -20, 4)
    assert(S.addSegment(store, {
      frame = "abs", dim = DIM, yAbs = true, x = 4, y = -20, z = 4, d = 1, n = 1,
      inspected = true, by = 1, lease = "7:mine:1", seq = 2, rev = 1, at = 1, base = 1,
    }))
    local face = P(4, -19, 4)
    equal(S.lookup(store, face), "observed")
    equal(select(2, S.lookup(store, face)), "minecraft:deepslate")
    equal(S.lookup(store, P(4, -18, 4)), "predicted")
    equal(S.allowsWalk(store, face), false)
    equal(S.allowsWalk(store, cell), true)
    -- A diagonal is not a face.
    equal(S.lookup(store, P(6, -18, 6)), "predicted")
    assert(S.noteConflict(store, cell, 9))
    equal(S.lookup(store, cell), "unknown")
    equal(S.allowsWalk(store, cell), false)
  end)

  test("recalibration freezes the old baseline and keeps observed names", function()
    local store = S.new({ strata = true })
    local key = "abs|" .. DIM .. "|0|0"
    local first = assert(S.calibrate(store, key, samplesFor(0, 0), 10))
    assert(S.observe(store, P(6, 10, 6), "minecraft:stone", { rev = 1, at = 10 }))
    equal(S.wireMark(store, P(6, 10, 6)), "=")
    local shifted = samplesFor(0, 0)
    for _, s in ipairs(shifted) do
      if s.name == "minecraft:stone" and s.y == 0 then s.y = 30 end
    end
    local second, old = assert(S.recalibrate(store, key, shifted, 20))
    equal(second.ver, 2)
    equal(old.hash, first.hash)
    equal(store.baselines[first.hash].frozen, true)
    equal(store.baselines[first.hash].ver, 1)
    equal(select(2, S.lookup(store, P(6, 10, 6))), "minecraft:stone")
    -- The collapsed band predicts deepslate here, so the stored stone is no longer "=".
    equal(S.wireMark(store, P(6, 10, 6)) ~= "=", true)
  end)

  test("filler match is not an error and gravel never joins the class", function()
    equal(S.filler("minecraft:gravel"), false)
    equal(S.filler("minecraft:tuff"), true)
    equal(S.misprediction("minecraft:stone", "minecraft:tuff"), false)
    equal(S.misprediction("minecraft:stone", "minecraft:gravel"), true)
    equal(S.misprediction("minecraft:stone", "minecraft:diamond_ore"), true)
    equal(S.misprediction("minecraft:air", "minecraft:stone"), true)
    equal(S.misprediction(nil, "minecraft:stone"), true)
    local decision = S.evaluateDefault({
      h4b1Bytes = 1000, h4b2Bytes = 100, misprediction = 0.01,
      heldOut = 4096, sections = 16, predictedWalks = 0,
    })
    equal(decision.enable, false)
    equal(decision.eligible, true)
    local refused = S.evaluateDefault({
      h4b1Bytes = 100, h4b2Bytes = 100, misprediction = 0.01,
      heldOut = 4096, sections = 16, predictedWalks = 0,
    })
    equal(refused.enable, false)
    equal(refused.eligible, false)
  end)

  test("prototype workload round trips observed air and stays near 9460 bytes", function()
    local store = S.new({ strata = true })
    assert(S.calibrate(store, "abs|" .. DIM .. "|0|0", samplesFor(0, 0), 1000))
    assert(S.calibrate(store, "abs|" .. DIM .. "|1|0", samplesFor(1, 0), 1000))
    local evidence = { by = 17, lease = "7:mine:12", seq = 1, rev = 812, at = 1792500000000 }
    for level = 0, 3 do
      local y = -58 + level * 3
      for b = 0, 31 do
        local x = b * 4
        local obs = {}
        for z = 0, 63 do obs[#obs + 1] = { x = x, y = y, z = z, name = "minecraft:air" } end
        local task = {
          frame = "abs", yAbs = true, progress = 64,
          min = { dim = DIM, x = x, y = y, z = 0 },
          max = { dim = DIM, x = x, y = y, z = 63 },
          by = evidence.by, lease = evidence.lease, seq = evidence.seq, rev = evidence.rev, at = evidence.at,
        }
        local done = assert(S.ingestMining(store, task, obs))
        equal(done.installed, true)
      end
      assert(S.addSegment(store, {
        frame = "abs", dim = DIM, yAbs = true, x = 0, y = 63, z = 0, d = 5,
        n = 63 - y + 1, inspected = false,
        by = evidence.by, lease = evidence.lease, seq = evidence.seq, rev = evidence.rev, at = evidence.at,
      }))
    end
    assert(S.addBox(store, {
      frame = "abs", dim = DIM, kind = "air",
      min = { x = 0, y = 4, z = 0 }, max = { x = 47, y = 64, z = 15 },
      inspected = false, by = evidence.by, lease = evidence.lease, seq = evidence.seq,
      rev = evidence.rev, at = evidence.at,
    }))
    assert(S.observe(store, P(70, -54, 8), "minecraft:diamond_ore", { rev = 900, at = evidence.at }))
    local before = S.observedList(store)
    local bytes = S.bytes(store)
    local back = assert(S.decode(S.encode(store)))
    equal(back.enabled, true)
    equal(S.observedList(back), before)
    equal(select(2, S.lookup(back, P(70, -54, 8))), "minecraft:diamond_ore")
    equal(S.allowsWalk(back, P(8, -58, 10)), true)
    equal(S.allowsWalk(back, P(8, 80, 10)), false)
    local low = math.floor(S.PROTOTYPE_BYTES * 0.8)
    local high = math.ceil(S.PROTOTYPE_BYTES * 1.2)
    assert(bytes >= low and bytes <= high, "bytes " .. bytes .. " outside " .. low .. ".." .. high)
    -- Four miners, 32 branches of 64, and the quarry are all present.
    assert(#before > 50000, "observed cells " .. #before)
  end)

  test("h4b1 slot and h1 digest stubs stay out of the live codecs", function()
    equal(S.slot("abs|" .. DIM .. "|0|0|-1"), "map/sections/h4b1-stub/abs|" .. DIM .. "|0|0|-1")
    local Hash = dofile("lib/stubs/h4b2_h1.lua")
    equal(#assert(Hash.digest("cc-h4/region/2")), 32)
    local Journal = dofile("lib/stubs/h4b2_b1.lua")
    equal(Journal.isDone({ v = 1, kind = "move", phase = "intent" }), false)
    equal(Journal.isDone({ v = 1, kind = "move", phase = "done" }), true)
  end)
end
