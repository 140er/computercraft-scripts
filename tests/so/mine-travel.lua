local M = dofile("so-mine-plan.lua")
local P = dofile("so-plan.lua")
local S = {}
function S.run(test, equal)
  for facing = 0, 3 do
    test("mine supply follows shaft and spine facing " .. facing, function()
      local job = {dim="minecraft:overworld",home={x=0,y=12,z=0,facing=facing},bottom=-8,
        mode="thorough",length=16,turtles={{branch=1}}}
      local route = M.route(job, 1)
      local row = {pose=route[#route],route=route,index=#route+1,branch=1}
      local stand = {dim=job.dim,x=-5,y=12,z=3}
      local point = {x=-6,y=12,z=3}
      local dug = {}
      local cursor = {dim=job.dim,x=0,y=12,z=0,facing=facing}
      for _, target in ipairs(route) do
        for _, p in ipairs(P.path(cursor,target,{order="yxz"}).cells) do dug[M.key(p)]=true end
        cursor=target
      end
      local path = assert(M.supplyRoute(job,row,stand,point,function(p) if dug[M.key(p)] then return false end end))
      row.trip={back=row.pose,stand=stand,point=point,stage="out",path=path}
      row.goal=stand
      local surfaced = false
      for i=2,#path do
        local cell=path[i]
        if cell.y==job.home.y then surfaced=true end
        if not surfaced then assert(dug[M.key(cell)],"supply trip cut a new underground cell") end
        assert(not M.same(cell,point),"supply trip enters chest")
        row.pose=path[i-1]
        local remaining=assert(M.travel(row.pose,stand,point,job,row))
        equal(#remaining,#path-i+1)
        assert(M.same(remaining[1],cell),"route changed during travel")
      end
      row.pose=path[1]
      local moves=0
      for _=1,#path*4 do
        local action=M.next(job,row,function() return false end,{},4000)
        if action.kind=="arrived" then break end
        for _,a in ipairs(action.actions or {action}) do
          assert(a.kind=="move" or a.kind=="turn","supply movement left the open route")
          if a.kind=="move" then moves=moves+1 end
        end
        row.pose=action.pose
      end
      assert(M.same(row.pose,stand),"supply planner failed to reach chest stand")
      equal(moves,#path-1)
      row.pose=path[1]
      local pass=M.lanePass(job,row)
      local inPass={}
      for _,p in ipairs(pass) do inPass[M.key(p)]=true end
      for _,p in ipairs(path) do if M.inLane(job,p) then assert(inPass[M.key(p)],"trip lane pass omits a lane cell") end end
      row.trip.stage="back" row.goal=row.trip.back
      for i=#path,2,-1 do
        row.pose=path[i]
        local remaining=assert(M.travel(row.pose,row.goal,point,job,row))
        equal(#remaining,i-1)
        assert(M.same(remaining[1],path[i-1]),"return does not reverse route")
      end
      equal(M.supplyDistance(job,{pose=path[1]},stand),#path-1)
    end)
  end
  test("mine supply retraces dug vein cells before entering the branch",function()
    local job={dim="minecraft:overworld",home={x=0,y=12,z=0,facing=0},bottom=-8,
      mode="thorough",length=8,turtles={{branch=0}}}
    local route=M.route(job,0)
    local anchor=route[#route]
    local back={dim=job.dim,x=anchor.x,y=anchor.y+2,z=anchor.z+1}
    local elbow={dim=job.dim,x=anchor.x,y=anchor.y+1,z=anchor.z+1}
    local neck={dim=job.dim,x=anchor.x,y=anchor.y,z=anchor.z+1}
    local dug={[M.key(anchor)]=true,[M.key(elbow)]=true,[M.key(neck)]=true}
    local row={pose=back,route=route,index=#route+1}
    local path=assert(M.supplyRoute(job,row,job.home,nil,function(p) if dug[M.key(p)] then return false end end))
    assert(M.same(path[2],elbow) and M.same(path[3],neck) and M.same(path[4],anchor),"vein exit digs a shortcut")
    equal(M.supplyRoute(job,row,job.home,nil,function() return nil end),nil)
  end)
  test("mine supply leaves an unfinished shaft upward and refuses a chest in the corridor",function()
    local job={dim="minecraft:overworld",home={x=0,y=12,z=0,facing=0},bottom=-8,
      mode="thorough",length=8,turtles={{branch=0}}}
    local row={pose={dim=job.dim,x=0,y=3,z=-1,facing=0}}
    local path=assert(M.supplyRoute(job,row,job.home,nil))
    equal(path[2].y,4)
    for _,p in ipairs(path) do assert(p.y>=3,"trip deepened unfinished shaft") end
    row.pose={dim=job.dim,x=8,y=-8,z=-5,facing=0}
    equal(M.supplyRoute(job,row,job.home,{x=0,y=-4,z=-1}),nil)
  end)

  test("mine supply bounds an unknown vein search and reuses known access",function()
    local job={dim="minecraft:overworld",home={x=0,y=12,z=0,facing=0},bottom=-8,
      mode="thorough",length=8,turtles={{branch=0}}}
    local row={pose={dim=job.dim,x=1,y=-8,z=-5},
      route={{dim=job.dim,x=1000,y=-8,z=-5}},index=2}
    local looked=0
    equal(M.supplyRoute(job,row,job.home,nil,function() looked=looked+1 return false end),nil)
    assert(looked<=512*6,"vein search exceeded its lookup budget: "..looked)
    row.route={{dim=job.dim,x=0,y=-8,z=-5}}
    local path,access=M.supplyRoute(job,row,job.home,nil,function(p)
      if p.y==-8 and p.z==-5 and p.x==0 then return false end
    end)
    assert(path and access and #access==2,"known vein access was not retained")
    local size=#access
    local cached={pose=row.pose,route=row.route,index=row.index,access=access}
    local second=assert(M.supplyRoute(job,cached,{x=-4,y=12,z=0},nil,function()
      error("cached access triggered another search")
    end))
    equal(#access,size,"route assembly mutated cached access")
    assert(M.same(second[2],access[2]))
    equal(M.supplyRoute(job,cached,job.home,access[2]),nil)
  end)

  test("mine long supply passes reserve the shared corridor without yielding",function()
    local job={dim="minecraft:overworld",home={x=0,y=64,z=0,facing=0},bottom=60,
      mode="thorough",length=48,turtles={{branch=1}}}
    local route=M.route(job,1)
    local row={pose=route[#route],route=route,index=#route+1}
    local stand={dim=job.dim,x=-2,y=64,z=0}
    local path=assert(M.supplyRoute(job,row,stand,{x=-3,y=64,z=0}))
    row.trip={path=path,back=row.pose,stand=stand,stage="out"}
    local env=setmetatable({
      SO={now=function() return 0 end,store={store=function() return {value={},save=function() return true end} end}},
      fs={makeDir=function() end,list=function() return {} end},
      os={epoch=function() return 0 end},
      sleep=function() error("supply lane reservation yielded") end,
    },{__index=_G})
    local file=assert(io.open("so-mod-cells.lua"))
    local code=file:read("*a") file:close()
    local cells=assert(load(code,"@so-mod-cells.lua","t",env))()
    local pass=M.lanePass(job,row)
    assert(cells.reserveMany("mine:2",pass))
    local entered=false
    for _,cell in ipairs(path) do
      entered=entered or M.inLane(job,cell)
      if entered then equal(cells.owner(cell.x,cell.y,cell.z,cell.dim),"mine:2") end
    end
    equal(cells.owner(row.pose.x,row.pose.y,row.pose.z,job.dim),nil)
  end)

end
return S
