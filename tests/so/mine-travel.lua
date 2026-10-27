local M = dofile("so-mine-plan.lua")
local P = dofile("so-plan.lua")
local S = {}
local function setupFixture(oldSave)
  local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {} for k, value in pairs(v) do out[k] = copy(value) end return out
  end
  local s = {now=0,saved={},screens={},orders={}}
  s.job = {homeSet=true,home={x=0,y=64,z=0,facing=0},dim="minecraft:overworld",bottom=-58,
    length=64,branches=8,continuous=false,mode="thorough",ores={},turtles={},
    progress={nextBranch=0,done=0},running=false}
  if oldSave then s.job.ores = nil end
  local mods = {}
  local env = setmetatable({SO={mods=mods,now=function() return s.now end,store={copy=copy,read=function() return {storageDeliveries=false,shopSaved=false} end,
    store=function(path, valid)
      local value = path == "so-data/mine/job" and s.job or copy(s.saved[path])
      if value and valid then assert(valid(value)) end
      return {value=value,save=function(nextValue)
        if s.failSave then return false,"disk full" end
        if valid then assert(valid(nextValue)) end
        s.saved[path] = copy(nextValue) return true
      end}
    end}},os={epoch=function() return 0 end},
    rednet={broadcast=function() end,send=function(_,body)
      if body.cmd == "order" then s.orders[#s.orders+1] = copy(body) end
      return true
    end}}, {__index=_G})
  mods.display = {screen=function(name,render,input) s.screens[name]={render=render,input=input} end}
  mods.state = {emit=function() end}
  mods.drops = {list=function() return {} end}
  mods.cells = {owner=function() return "mine:2" end,reserve=function() return true end,
    reserveMany=function() return true end}
  mods.lease = {status=function() return {} end,inRange=function() return true end,
    onReport=function(_,fn) s.report=fn end,send=function(_,steps) s.steps=steps return "lease" end}
  s.restartShop = function()
    mods.shop = assert(loadfile("so-mod-shop.lua","t",env))()
    s.shop = mods.shop
    s.shop.tick(s.now)
  end
  s.restartShop()
  s.mods=mods
  s.mine = assert(loadfile("so-mod-mine.lua","t",env))()
  s.mine.tick()
  s.stock = function() s.shop.listen.roomsorter_stock(9,{totals={["minecraft:charcoal"]=128}}) end
  s.stock()
  s.session = {id=7}
  s.tap = function(id) s.screens.mining.input({id=id,session=s.session}) end
  s.tap("tab:setup")
  s.frame = function(w,h)
    local frame = s.screens.mining.render(w,h,s.session)
    local text, buttons = {}, {}
    for _,row in ipairs(frame.rows) do assert(#row.text<=w) text[#text+1]=row.text end
    for _,b in ipairs(frame.buttons) do
      assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,b.id)
      assert(frame.rows[b.y].text:sub(b.x,b.x+b.w-1):find(b.label,1,true),b.id.." label clipped")
      for _,other in pairs(buttons) do
        assert(b.x+b.w<=other.x or other.x+other.w<=b.x or b.y~=other.y,b.id.." overlaps "..other.id)
      end
      buttons[b.id]=b
    end
    return table.concat(text,"\n"),buttons
  end
  return s
end
function S.run(test, equal)
  for _,kind in ipairs({"ore","fuel"}) do
    test("mining handles a "..(kind=="ore" and "full unload" or "empty fuel").." chest with protection enabled",function()
      local s=dofile("tests/so/protected.lua").setup()
      s.m.install({"so-mod-mine.lua","so-mine-plan.lua"})
      local SO=s.m.env.SO
      local pose=SO.store.copy(s.pose)
      local inv=kind=="ore" and {{slot=1,name="minecraft:diamond",count=64}} or {}
      local row={pose=pose,anchor=SO.store.copy(pose),frame={dim=pose.dim,ox=0,oy=0,oz=0,rot=0},
        inv=inv,fuel=100,state="mining",branch=0,index=2}
      local point={id=kind,dim=0,x=0,y=-1,z=0,side="down"}
      row.trip={kind=kind,stage="out",stand=pose,back=SO.store.copy(pose),shared=true,
        path={pose},reserve=2000,point=point}
      local job={homeSet=true,home={x=0,y=0,z=0,facing=0},dim=pose.dim,bottom=-2,length=4,
        branches=1,mode="fast",ores={},turtles={["2"]=row},progress={nextBranch=1,done=0},running=true}
      row.route=M.route(job,0)
      assert(SO.store.store("so-data/mine/job",function() return true end).save(job))
      SO.mods.state={emit=function() return true end,canStart=function() return true end}
      SO.mods.display={screen=function() end}
      SO.mods.drops={list=function() return {} end,steps=function()
        return {{op="inspectDown"},{op="dropDown"}}
      end}
      local empty=0
      SO.mods.shop={fuelEmpty=function() empty=empty+1 return true end}
      s.reportInv=inv
      local mine=s.m.env.dofile("so-mod-mine.lua") SO.mods.mine=mine
      mine.tick() s.report({{ok=false,err="No block to inspect"}})
      local op=kind=="ore" and "dropDown" or "suckDown"
      for attempt=1,3 do
        mine.tick()
        local q=s.sent[#s.sent].body
        equal(q.steps[#q.steps].op,op)
        local results={}
        for i,step in ipairs(q.steps) do
          results[i]=step.op==op and {ok=false,err=kind=="ore" and "No space for items" or "No items to take"}
            or step.op=="inspectDown" and {ok=true,data={name="minecraft:chest"}} or {ok=true}
        end
        s.report(results)
        local saved=SO.store.read("so-data/mine/job").value.turtles["2"]
        equal(saved.recover,false)
        equal(saved.dropRetry.tries,attempt)
        equal(s.lease.status(2).boundaryHold,nil)
        if kind=="fuel" or attempt==3 then
          equal(saved.state,"hold") equal(saved.dropRetry.after,60000)
          if kind=="fuel" then equal(empty,1) else equal(saved.dropRetry.alerted,true) end
          return
        end
      end
    end)
  end
  for _, supply in ipairs({false,true}) do
    for _, failure in ipairs({"move","turn"}) do
      test("mining "..(supply and "supply trip" or "work route").." holds after a failed "..failure.." boundary",function()
        local s=dofile("tests/so/protected.lua").setup()
        s.pose.facing=failure=="turn" and 1 or 0
        s.hello()
        s.m.install({"so-mod-mine.lua","so-mine-plan.lua"})
        local SO=s.m.env.SO
        local pose=SO.store.copy(s.pose)
        local row={pose=pose,anchor=SO.store.copy(pose),frame={dim=pose.dim,ox=0,oy=0,oz=0,rot=0},
          inv={},fuel=4000,state="mining",branch=0,index=2}
        local job={homeSet=true,home={x=0,y=0,z=0,facing=0},dim=pose.dim,bottom=-2,length=4,
          branches=1,mode="fast",ores={},turtles={["2"]=row},progress={nextBranch=1,done=0},running=true}
        row.route=M.route(job,0)
        if supply then
          local stand={dim=pose.dim,x=0,y=0,z=-3,facing=0}
          row.trip={kind="fuel",stage="out",stand=stand,back=SO.store.copy(pose),shared=false,
            path={pose,stand},reserve=20,point={id="fuel",dim=0,x=0,y=-1,z=-3,side="down"}}
        end
        assert(SO.store.store("so-data/mine/job",function() return true end).save(job))
        SO.mods.state={emit=function() return true end,canStart=function() return true end}
        SO.mods.display={screen=function() end}
        SO.mods.drops={list=function() return {} end}
        local mine=s.m.env.dofile("so-mod-mine.lua") SO.mods.mine=mine
        local failed=false
        for _=1,20 do
          mine.tick()
          local q=s.sent[#s.sent]
          assert(q and q.kind=="lease.batch","mining did not dispatch a prefix")
          local step=q.body.steps[#q.body.steps]
          if failure=="move" and P.moves[step.op] or failure=="turn" and P.turns[step.op] then
            equal(#q.body.steps,#P.boundary({steps=q.body.steps}).steps)
            local before=#s.sent
            local beforePose=SO.store.copy(s.pose)
            s.report({{ok=false,err="blocked"}})
            equal(#s.sent,before,"failed boundary dispatched a remainder")
            local saved=SO.store.read("so-data/mine/job").value.turtles["2"]
            equal(saved.pose,beforePose)
            equal(saved.recover,true)
            mine.tick()
            local recovery=s.sent[#s.sent].body.steps
            equal(recovery[1].op,"inspectDown") equal(#recovery,1)
            failed=true break
          end
          local results={}
          for i,v in ipairs(q.body.steps) do results[i]={ok=not v.op:match("^inspect")} end
          s.report(results)
        end
        assert(failed,"did not reach the injected boundary")
      end)
    end
  end
  test("mining loads an old save without ores and keeps setup and filter taps usable",function()
    local s=setupFixture(true)
    equal(s.job.ores,{})
    local text=s.frame(29,12)
    assert(text:find("fuel ~902",1,true))
    s.tap("ores-edit")
    local _,buttons=s.frame(29,12)
    assert(buttons["ore-coal"] and buttons["ore-ancient_debris"])
    s.tap("ore-coal") equal(#s.job.ores,9)
    s.tap("ore-ancient_debris") equal(#s.job.ores,8)
    equal(s.saved["so-data/mine/job"].ores,s.job.ores)
  end)
  test("mining fuel estimate sums branch routes and the shaft round trip",function()
    local s=setupFixture()
    equal(M.fuelEstimate(s.job),902)
    local routes=2*(1+math.abs(s.job.home.y-s.job.bottom))
    for branch=0,s.job.branches-1 do routes=routes+#M.route(s.job,branch)-2 end
    equal(M.fuelEstimate(s.job),routes)
    s.job.mode="fast" equal(M.fuelEstimate(s.job),830)
    s.job.branches,s.job.length=4096,4096
    equal(M.fuelEstimate(s.job),33558774)
  end)
  for _,size in ipairs({{26,20},{29,12},{36,16},{52,22}}) do
    test("mining SETUP mode and branch controls fit "..size[1].."x"..size[2],function()
      local s=setupFixture()
      local text,b=s.frame(size[1],size[2])
      assert(text:find("fuel ~902",1,true),text)
      assert(b.single and b.continuous and not b["set-branches+"])
      s.tap("continuous") equal(s.job.continuous,true)
      text,b=s.frame(size[1],size[2])
      assert(text:find("fuel ~902",1,true),text)
      assert(b["set-branches-"] and b["set-branches+"])
      s.tap("set-branches+") equal(s.job.branches,9)
      s.tap("set-branches-") equal(s.job.branches,8)
      s.job.branches=1 s.tap("set-branches-") equal(s.job.branches,1)
      s.job.branches=4096 s.tap("set-branches+") equal(s.job.branches,4096)
      s.tap("single") equal(s.job.continuous,false)
      _,b=s.frame(size[1],size[2]) assert(not b["set-branches+"])
    end)
  end
  for _,size in ipairs({{36,16},{52,22}}) do
    test("all ten mining ore chips fit and preserve Nether filters at "..size[1].."x"..size[2],function()
      local s=setupFixture() s.tap("ores-edit")
      local _,b=s.frame(size[1],size[2])
      for name in pairs(M.ores) do assert(b["ore-"..name],name) end
      s.job.ores={"ancient_debris","quartz","nether_gold"}
      s.tap("ore-coal") equal(s.job.ores,{"coal","quartz","nether_gold","ancient_debris"})
      s.tap("ore-nether_gold") equal(s.job.ores,{"coal","quartz","ancient_debris"})
      s.tap("ore-ancient_debris") equal(s.job.ores,{"coal","quartz"})
      s.job.ores={} s.tap("ore-coal") equal(#s.job.ores,9)
      s.tap("ore-coal") equal(#s.job.ores,10)
    end)
  end
  test("mining retries a lost fuel order after its durable timeout and chest cooldown",function()
    local s=setupFixture()
    local point={id="fuel",dim=0,x=10,y=63,z=0,side="down",kind="fuel"}
    local pose={dim=s.job.dim,x=10,y=64,z=0,facing=0}
    local row={pose=pose,anchor=pose,frame={dim=pose.dim,ox=0,oy=0,oz=0,rot=0},inv={},fuel=1,state="fuel",
      trip={kind="fuel",point=point,stand=pose,back=pose,stage="out",path={pose},reserve=2000,shared=true}}
    s.job.turtles["2"],s.job.running=row,true
    s.mods.drops.list=function() return {point} end
    assert(s.shop.fuelConfig(nil,point.id)) assert(s.shop.fuelConfig(true))
    local function empty(at)
      s.now=at s.stock() s.mine.tick()
      equal(s.steps[#s.steps].op,"suckDown")
      s.report("lease",2,{{ok=true,data={name="minecraft:chest"}},{ok=true},{ok=false,err="No items to take"}},
        {report={pose={x=pose.x,y=pose.y,z=pose.z,f=0},inv={},fuel=1}})
      equal(row.dropRetry.after,at+60000)
    end
    empty(0) equal(#s.orders,1)
    local first=s.shop.fuelConfig().waiting.rid
    s.now=59999 s.mine.tick() equal(s.steps[1].op,"inspectDown")
    s.report("lease",2,{{ok=true}},{report={pose={x=pose.x,y=pose.y,z=pose.z,f=0},inv={},fuel=1}})
    empty(60000) equal(#s.orders,1)
    s.now=120000 s.failSave=true s.shop.tick(s.now)
    equal(s.shop.fuelConfig().waiting.rid,first)
    s.failSave=false s.shop.tick(s.now)
    equal(s.shop.fuelConfig().waiting,nil)
    equal(s.shop.fuelAlerts()[1].reason,"fuel order timed out")
    s.restartShop() s.stock()
    equal(s.shop.fuelConfig().waiting,nil)
    equal(s.shop.fuelAlerts()[1].reason,"fuel order timed out")
    s.shop.listen.roomsorter(9,{rid=first,"Delivered 64 minecraft:charcoal"})
    equal(s.shop.fuelAlerts()[1].reason,"fuel order timed out")
    for at=120000,540000,60000 do empty(at) equal(#s.orders,1) end
    empty(600000) equal(#s.orders,2)
    local second=s.shop.fuelConfig().waiting.rid
    assert(second~=first)
    s.shop.listen.roomsorter(9,{rid=first,"Delivered 64 minecraft:charcoal"})
    equal(s.shop.fuelConfig().waiting.rid,second)
    empty(660000) equal(#s.orders,2)
    assert(s.shop.fuelClear()) equal(s.shop.fuelConfig().waiting,nil)
    empty(720000) equal(#s.orders,2)
    empty(1200000) equal(#s.orders,3)
  end)

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
