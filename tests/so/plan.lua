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
  test("ordinary operation failures confirm the acknowledged pose boundary",function()
    for _,op in ipairs({"drop","suck","refuel","place","dig"}) do
      assert(P.confirm(from,{{op=op}},{{ok=false}},from),op)
      local actual=P.apply(from,"forward")
      assert(P.confirm(from,{{op=op},{op="forward"}},{{ok=false},{ok=true}},actual),op)
      equal(P.confirm(from,{{op=op},{op="forward"}},{{ok=false},{ok=false}},from),false)
    end
  end)
  test("range clipping retains boundary metadata and trims nested part poses",function()
    local part=P.path(from,{dim=from.dim,x=3,y=0,z=0,facing=1})
    part.first=1
    local action={kind="batch",from=from,boundary=true,steps={{op="forward"}},
      cells=part.cells,pose=part.pose,actions={part}}
    local out=assert(P.rangeBatch({inRange=function(_,p) return p.x<=1 end},2,action))
    equal(out.boundary,true) equal(out.from,from)
    equal(#out.steps,1) equal(#out.actions[1].steps,1)
    equal(out.pose,P.apply(from,"forward")) equal(out.actions[1].pose,out.pose)
    for _,p in ipairs(out.cells) do assert(p.x<=1) end
    equal(#part.steps,3) equal(part.pose.x,3)
    local boundary=P.boundary({from=from,steps=part.steps,actions={part}})
    equal(boundary.actions[1].pose,boundary.pose)
  end)

end
