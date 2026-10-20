return function(test, equal, mocks)
  local Pos = dofile("position.lua")
  local fixture = dofile("tests/nav-fixture.lua")(nil, mocks)
  local dim = "minecraft:overworld"

  local function face(name)
    return { front = name, right = name, back = name, left = name, top = name, bottom = name }
  end

  test("position and frame shapes reject an unknown version and a relative absolute mix", function()
    local pos = { v = 1, frame = "abs", yAbs = true, dim = dim, x = 10, y = 65, z = 20, h = 0,
      conf = "certain", src = "neighbour", anchoredAt = 1792500000000 }
    assert(Pos.pos(pos))
    pos.v = 2
    assert(not Pos.pos(pos))
    pos.v = 1
    pos.yAbs = false
    assert(not Pos.pos(pos))
    local frame = { v = 1, id = "f:17:1792500000000", owner = 17, yAbs = true, toAbs = false }
    assert(Pos.frame(frame))
    frame.v = 2
    assert(not Pos.frame(frame))
    frame.v = 1
    frame.toAbs = { dx = 100, dy = 0, dz = 200, rot = 1 }
    assert(Pos.frame(frame))
    frame.toAbs.dy = 1
    assert(not Pos.frame(frame))
    local x, y, z, h = Pos.transform(1, 65, 2, 0, true, { dx = 100, dy = 0, dz = 200, rot = 1 })
    equal({ x, y, z, h }, { 98, 65, 201, 1 })
    x, y, z = Pos.transform(1, 5, 2, nil, false, { dx = 0, dy = 10, dz = 0, rot = 0 })
    equal({ x, y, z }, { 1, 15, 2 })
  end)

  test("fuel and six-face resolvers follow the confidence rules", function()
    local air = face("minecraft:air")
    local stone = { front = "minecraft:stone", right = "minecraft:air", back = "minecraft:air",
      left = "minecraft:air", top = "minecraft:air", bottom = "minecraft:air" }
    local fromFaces = Pos.rotate(air, 1)
    local toFaces = Pos.rotate(stone, 1)
    local moved = Pos.resolveMove({
      fuelBefore = 1800, fuelNow = 1799, moveCost = 1, charging = "none", regeneration = "none",
      fromFaces = fromFaces, toFaces = toFaces, localFaces = stone, heading = 1,
    })
    equal({ moved.conf, moved.cell, moved.heading }, { "certain", "to", 1 })
    local stayed = Pos.resolveMove({
      fuelBefore = 1800, fuelNow = 1800, moveCost = 1, charging = "none", regeneration = "none",
      fromFaces = fromFaces, toFaces = toFaces, localFaces = air, heading = 1,
    })
    equal({ stayed.conf, stayed.cell, stayed.heading }, { "certain", "from", 1 })
    local charged = Pos.resolveMove({
      fuelBefore = 1800, fuelNow = 1799, moveCost = 1, charging = "possible", regeneration = "none",
      fromFaces = fromFaces, toFaces = toFaces, localFaces = stone, heading = 1,
    })
    assert(charged.conf == "certain" and charged.method == "fingerprint")
    local blind = Pos.resolveMove({
      fuelBefore = 1800, fuelNow = 1799, moveCost = 1, charging = "unknown", regeneration = "unknown",
      fromFaces = {}, toFaces = {}, localFaces = air, heading = 1,
    })
    assert(blind.conf == "lost")
    local clash = Pos.resolveMove({
      fuelBefore = 1800, fuelNow = 1800, moveCost = 1, charging = "none", regeneration = "none",
      fromFaces = fromFaces, toFaces = toFaces, localFaces = stone, heading = 1,
    })
    assert(clash.conf == "lost")
    local same = Pos.resolveMove({
      fuelBefore = "unlimited", fuelNow = "unlimited", moveCost = false, charging = "unknown", regeneration = "unknown",
      fromFaces = fromFaces, toFaces = fromFaces, localFaces = air, heading = 1,
    })
    assert(same.conf == "lost")
    local boot = Pos.resolveBoot({ faces = toFaces, localFaces = stone })
    equal({ boot.conf, boot.heading }, { "certain", 1 })
    local ambiguous = Pos.resolveBoot({ faces = fromFaces, localFaces = air })
    assert(ambiguous.conf == "suspect")
    local unmatched = Pos.resolveBoot({ faces = toFaces, localFaces = air })
    assert(unmatched.conf == "suspect")
  end)

  test("player anchor floors the standing cell and radio needs four non-coplanar fixes", function()
    equal(Pos.parseAnchor("$anchor 17"), 17)
    assert(not Pos.parseAnchor("$anchor"))
    assert(not Pos.parseAnchor("anchor 17"))
    local cell = Pos.playerCell({ x = -2.2, y = 66, z = 0.8, dim = dim })
    equal(cell, { x = -3, y = 65, z = 0, dim = dim })
    local function ref(x, y, z, target)
      local dx, dy, dz = x - target.x, y - target.y, z - target.z
      return { x = x, y = y, z = z, dist = math.sqrt(dx * dx + dy * dy + dz * dz), loaded = true, frame = "abs", conf = "certain" }
    end
    local target = { x = -2, y = 65, z = 0 }
    local fix = Pos.triangulate({
      ref(-2, 65, -10, target), ref(-12, 65, 0, target), ref(-2, 75, 0, target), ref(8, 65, 0, target),
    })
    equal({ fix.x, fix.y, fix.z }, { target.x, target.y, target.z })
    assert(not Pos.triangulate({
      ref(-2, 65, -10, target), ref(-12, 65, 0, target), ref(-2, 75, 0, target),
    }))
    assert(not Pos.triangulate({
      ref(-2, 65, -10, target), ref(-12, 65, 0, target), ref(8, 65, 0, target), ref(18, 65, 0, target),
    }))
    local unloaded = {
      ref(-2, 65, -10, target), ref(-12, 65, 0, target), ref(-2, 75, 0, target), ref(8, 65, 0, target),
    }
    unloaded[4].loaded = false
    assert(not Pos.triangulate(unloaded))
    local bent = {
      ref(-2, 65, -10, target), ref(-12, 65, 0, target), ref(-2, 75, 0, target), ref(8, 65, 0, target),
    }
    bent[1].dist = bent[1].dist + 5
    assert(not Pos.triangulate(bent))
  end)

  local function anchor(f)
    local ok, why = f.nav.anchor({ x = -2, y = 65, z = 0, dim = dim, src = "typed", reference = "pad", h = 1 })
    assert(ok, why)
  end

  test("no-GPS crashes at every move checkpoint recover certain or stay lost without digging", function()
    local points = { "move-prepared", "move-started", "move-physical", "move-observed", "move-saved" }
    local certain, fingerprintOnly, lost, suspect, digs = 0, 0, 0, 0, 0
    for _, point in ipairs(points) do
      local f = fixture({ gpsFree = true, trapGps = true, moveCost = 1, charging = "none", regeneration = "none",
        crash = point, observe = function() error("N1 called observe") end })
      anchor(f)
      f.block(-1, 65, -1, "minecraft:stone")
      f.nav.record({ dim = dim, x = -1, y = 65, z = -1 }, "minecraft:stone")
      assert(not pcall(function() f.nav.step(1, "explore") end), point)
      local nav = f.reopen()
      local ok, why = nav.recover()
      assert(ok, point .. " " .. tostring(why))
      local q = nav.pose()
      local src = point == "move-saved" and "neighbour" or "reckoned"
      assert(q.conf == "certain" and q.v == 1 and q.frame == "abs" and q.yAbs == true and q.src == src,
        point .. " " .. tostring(q.conf) .. " " .. tostring(q.src) .. " v=" .. tostring(q.v))
      f.equalPose()
      certain = certain + 1
    end
    for _, point in ipairs(points) do
      local f = fixture({ gpsFree = true, trapGps = true, crash = point, fuel = "unlimited",
        observe = function() error("N1 called observe") end })
      f.fuel("unlimited")
      anchor(f)
      f.block(-1, 65, -1, "minecraft:stone")
      f.nav.record({ dim = dim, x = -1, y = 65, z = -1 }, "minecraft:stone")
      assert(not pcall(function() f.nav.step(1, "explore") end), point)
      local nav = f.reopen()
      assert(nav.recover(), point)
      assert(nav.pose().conf == "certain")
      f.equalPose()
      fingerprintOnly = fingerprintOnly + 1
    end
    for _, point in ipairs(points) do
      local f = fixture({ gpsFree = true, trapGps = true, crash = point,
        observe = function() error("N1 called observe") end })
      anchor(f)
      assert(not pcall(function() f.nav.step(1, "explore") end), point)
      local nav = f.reopen()
      local ok = nav.recover()
      local q = nav.pose()
      f.block(q.x + 1, q.y, q.z, "minecraft:stone")
      assert(not nav.step(1, "excavate"))
      digs = digs + f.digs()
      if q.conf == "lost" then
        assert(not ok)
        lost = lost + 1
      else
        assert(point == "move-saved" and q.conf == "suspect" and not ok)
        suspect = suspect + 1
      end
    end
    print("N1 gate A counts: certain=" .. certain .. " fingerprint=" .. fingerprintOnly
      .. " lost=" .. lost .. " suspect=" .. suspect .. " lost-or-suspect digs=" .. digs)
    assert(certain == 5 and fingerprintOnly == 5 and lost == 4 and suspect == 1 and digs == 0)
  end)

  test("a lost or suspect pose and a disagreed GPS check dig nothing", function()
    local checks = 0
    local f = fixture({ gpsFree = true, trapGps = true, moveCost = 1, charging = "none", regeneration = "none",
      observe = function() error("N1 called observe") end,
      check = function() checks = checks + 1 return { x = 0, y = 65, z = 0, dim = dim } end })
    anchor(f)
    f.nav.record({ dim = dim, x = -1, y = 65, z = -1 }, "minecraft:stone")
    assert(f.nav.step(1, "explore"))
    assert(checks == 1 and f.nav.pose().conf == "suspect")
    f.block(0, 65, 0, "minecraft:stone")
    assert(not f.nav.step(1, "excavate") and f.digs() == 0)
    f = fixture({ gpsFree = true, trapGps = true, crash = "probe-intent" })
    assert(not pcall(function() anchor(f) end))
    local nav = f.reopen()
    assert(not nav.recover() and nav.pose().conf == "lost")
    f.block(-1, 65, 0, "minecraft:stone")
    assert(not nav.step(1, "excavate") and f.digs() == 0)
  end)

  test("player chat and radio anchor the turtle without reading GPS", function()
    local f = fixture({ gpsFree = true, trapGps = true, observe = function() error("N1 called observe") end })
    assert(not f.nav.hear("$anchor 17", { x = -2, y = 66, z = 0, dim = dim }))
    assert(f.nav.pose().conf == "suspect")
    assert(f.nav.hear("$anchor 99", { x = -2.2, y = 66, z = 0.8, dim = dim }))
    local q = f.nav.pose()
    equal({ q.x, q.y, q.z, q.h, q.conf, q.src, q.frame, q.yAbs, q.v },
      { -3, 65, 0, 1, "certain", "typed", "abs", true, 1 })
    local function ref(x, y, z)
      local dx, dy, dz = x + 2, y - 65, z
      return { x = x, y = y, z = z, dist = math.sqrt(dx * dx + dy * dy + dz * dz), loaded = true }
    end
    f = fixture({ gpsFree = true, trapGps = true })
    assert(not f.nav.radio({ ref(-2, 65, -10), ref(-12, 65, 0), ref(-2, 75, 0) }))
    assert(f.nav.pose().conf == "suspect" and f.nav.pose().src == "radio")
    assert(f.nav.radio({ ref(-2, 65, -10), ref(-12, 65, 0), ref(-2, 75, 0), ref(8, 65, 0) }))
    q = f.nav.pose()
    assert(q.conf == "certain" and q.src == "radio" and q.x == -2 and q.y == 65 and q.z == 0)
    assert(f.nav.step(1, "explore") and f.digs() == 0)
    q = f.nav.pose()
    assert(q.v == 1 and q.frame == "abs" and q.conf == "certain" and q.src == "reckoned")
    f = fixture({ gpsFree = true, trapGps = true })
    assert(f.nav.anchor({ x = -2, y = 65, z = 0, dim = dim, src = "typed", reference = "pad",
      frame = "f:99:1000", yAbs = true, h = 1 }))
    assert(not f.nav.hear("$anchor 99", { x = -2, y = 66, z = 0, dim = "minecraft:the_nether" }))
    q = f.nav.pose()
    assert(q.conf == "lost" and q.frame == "abs" and q.yAbs == true)
  end)

  test("server anchor and frame-merge keep relative cells out of abs until one idempotent merge", function()
    local m = mocks.new(false)
    m.env.dofile = function(path) return assert(loadfile(path, "t", m.env))() end
    local S = m.env.dofile("ssot.lua")
    local secret = "test-secret-123456"
    local function request(api, n, op, fields)
      local msg = { v = 1, type = "ssot", expect = "ssot_reply", op = op, boot = "turtle-1",
        rid = "r" .. n, counter = n, secret = secret }
      for k, v in pairs(fields) do msg[k] = v end
      return api.handle(1, msg)
    end
    local function cellAt(s, x, y, z)
      local key = dim .. "|" .. math.floor(x / 16) .. "|" .. math.floor(y / 16) .. "|" .. math.floor(z / 16)
      local ch = s.chunks[key]
      if not ch then return nil end
      local index = x % 16 + 16 * (z % 16) + 256 * (y % 16) + 1
      local n = ch.cells[index]
      if n == nil then return nil end
      if n == 0 then return false end
      return s.names[n]
    end
    local frame = "f:1:1000"
    local p = { v = 1, frame = frame, yAbs = true, dim = dim, x = 0, y = 64, z = 0, h = 1,
      conf = "certain", src = "typed", anchoredAt = 1000 }
    local ev = { source = "typed", reference = "pad", faces = { [0] = "minecraft:air" } }
    local api = S.open({ controllers = { ["1"] = secret }, compactSections = false })
    assert(request(api, 1, "anchor", { pose = p, evidence = ev }).ok)
    local bad = {}
    for k, v in pairs(p) do bad[k] = v end
    bad.v = 2
    assert(not request(api, 2, "anchor", { pose = bad, evidence = ev }).ok)
    local before = api.state()
    assert(request(api, 3, "scan", { pose = p, revision = 0, cells = {
      { dim = dim, x = 1, y = 64, z = 0, name = "minecraft:stone" } } }).ok)
    assert(cellAt(api.state(), 1, 64, 0) == nil)
    assert(cellAt(api.state(), 101, 64, 0) == nil)
    local transform = { dx = 100, dy = 0, dz = 0, rot = 0 }
    local merged = request(api, 4, "frame-merge", { id = frame, toAbs = transform })
    assert(merged.ok and merged.idempotent == false and merged.state == "committed")
    local rev = api.state().rev
    assert(cellAt(api.state(), 1, 64, 0) == nil)
    assert(cellAt(api.state(), 101, 64, 0) == "minecraft:stone")
    assert(api.state().poses[1].frame == "abs" and api.state().poses[1].x == 100 and api.state().poses[1].src == "inherited")
    local again = request(api, 5, "frame-merge", { id = frame, toAbs = transform })
    assert(again.ok and again.idempotent == true and api.state().rev == rev)
    assert(not request(api, 6, "frame-merge", { id = frame, toAbs = { dx = 101, dy = 0, dz = 0, rot = 0 } }).ok)
    assert(not request(api, 7, "frame-merge", { id = frame, toAbs = { dx = 100, dy = 1, dz = 0, rot = 0 } }).ok)
    assert(before.chunks and next(before.chunks) == nil)
    S.open({ controllers = { ["1"] = secret }, compactSections = false })
  end)
end
