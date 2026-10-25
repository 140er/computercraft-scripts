local P = dofile("so-plan.lua")

return function(test, equal)
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
