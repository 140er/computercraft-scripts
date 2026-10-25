local P = dofile("so-plan.lua")

return function(test, equal)
  for _, wood in ipairs({ "oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry" }) do
    for _, variant in ipairs({ wood .. "_log", wood .. "_wood", "stripped_" .. wood .. "_log", "stripped_" .. wood .. "_wood" }) do
      local name = "minecraft:" .. variant
      test("B4-E burnValue gives 15 moves for " .. name, function()
        equal(P.burnValue(name), 15)
        equal(P.fuelValue(name), 0)
      end)
    end
  end
  test("B4-E burnValue rejects Nether stems and hyphae", function()
    for _, wood in ipairs({ "crimson", "warped" }) do
      for _, variant in ipairs({ "stem", "hyphae" }) do
        equal(P.burnValue("minecraft:" .. wood .. "_" .. variant), nil)
        equal(P.burnValue("minecraft:stripped_" .. wood .. "_" .. variant), nil)
      end
    end
  end)
  test("B4-E burnValue rejects planks and other wood products", function()
    for _, wood in ipairs({ "oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry", "crimson", "warped", "bamboo" }) do
      equal(P.burnValue("minecraft:" .. wood .. "_planks"), nil)
    end
    for _, name in ipairs({ "stick", "bamboo_block", "stripped_bamboo_block", "mangrove_roots", "oak_sapling", "oak_slab" }) do
      equal(P.burnValue("minecraft:" .. name), nil)
    end
  end)
  test("B4-E burnValue rejects modded and unknown IDs", function()
    for _, name in ipairs({ "mod:oak_log", "mod:stripped_oak_wood", "minecraft:unknown_log", "minecraft:unknown_wood",
      "minecraft:pale_oak_log", "minecraft:oak_log_extra", "oak_log", "Minecraft:oak_log", "minecraft:dirt", "" }) do
      equal(P.burnValue(name), nil)
    end
    equal(P.burnValue(nil), nil)
  end)
  test("B4-E fuelValue keeps ordinary fuel classification unchanged", function()
    for name, value in pairs({ ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
      ["minecraft:lava_bucket"] = 1000, ["minecraft:blaze_rod"] = 120 }) do
      equal(P.fuelValue(name), value)
      equal(P.burnValue(name), nil)
    end
    for _, name in ipairs({ "minecraft:oak_planks", "minecraft:crimson_stem", "minecraft:warped_hyphae", "minecraft:dirt",
      "mod:coal", "mod:oak_log", "minecraft:unknown_log", "" }) do
      equal(P.fuelValue(name), 0)
    end
    equal(P.fuelValue(nil), 0)
  end)
  test('P.chestCheck returns "not scanned" for an unscanned chest', function()
    local point = {id="ore", kind="ore", dim=0, x=1, y=2, z=3}
    local near = {dim=0, x=0, y=2, z=3}
    equal(P.chestCheck({point}, "ore", near),
      {ok=true, text="ore #ore not scanned at 1,2,3"})

    point.verified = true
    equal(P.chestCheck({point}, "ore", near),
      {ok=true, text="ore #ore verified by visit at 1,2,3"})

    point.broken = true
    equal(P.chestCheck({point}, "ore", near),
      {ok=false, text="ore #ore broken at 1,2,3"})
    equal(P.chestCheck({}, "ore", near),
      {ok=false, text="no ore chest set"})
  end)
end
