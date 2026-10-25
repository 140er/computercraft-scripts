local P = dofile("so-plan.lua")
local from = {dim="minecraft:overworld",x=0,y=0,z=0,facing=1}
return function(test,equal)
  test("route assessment reports the first refusal in execution order with range facts",function()
    local steps={{op="turnRight"},{op="forward"},{op="dig"},{op="forward"}}
    local seen={}
    local check=P.assess(from,steps,{limit=24,admit=function(at,op,to)
      seen[#seen+1]={op,to.x,to.z}
      if op=="dig" then return false,"protected" end
      return true
    end})
    equal(check.first,3) equal(check.reason,"protected") equal(check.cell.z,2) equal(check.limit,24)
    equal(#seen,2)
    check=P.assess(from,{{op="forward"}},{limit=24,range=function() return false,25,24 end})
    equal({check.reason,check.distance,check.limit},{"range",25,24})
    check=P.assess(from,{{op="forward"}},{admit=function() return false,"held","mine:3" end})
    equal(check.holder,"mine:3")
    equal(P.assess({},steps).reason,"pose unknown")
  end)
  test("acknowledged boundary ends at the first move or turn and rebuilds its pose",function()
    for _,op in ipairs({"forward","back","up","down","turnLeft","turnRight"}) do
      local action={from=from,steps={{op="inspect"},{op=op},{op="dig"},{op="forward"}}}
      local prefix=P.boundary(action)
      equal(#prefix.steps,2) equal(#prefix.rest,2) equal(prefix.pose,P.apply(from,op))
      equal(#action.steps,4)
      local actual=P.apply(from,op)
      assert(P.confirm(from,prefix.steps,{{ok=false},{ok=true}},actual))
      equal(P.confirm(from,prefix.steps,{{ok=false},{ok=false}},from),false)
      actual.facing=(actual.facing+1)%4
      equal(P.confirm(from,prefix.steps,{{ok=false},{ok=true}},actual),false)
    end
  end)
end
