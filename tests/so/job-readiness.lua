local P=dofile("so-plan.lua")
local function fixture(kind)
  local job=kind=="mine" and {homeSet=false,home={x=0,y=0,z=0,facing=0},bottom=-2,length=3,
    mode="fast",ores={},progress={done=0,nextBranch=0},turtles={},dim="minecraft:overworld",running=false}
    or {spots={},fuel=0,inv={},dim="minecraft:overworld",running=false}
  local events,points,paired,status={},{},{},{}
  local input,render
  local env=setmetatable({SO={now=function() return 0 end,pair={key=function(id) return paired[id] end},
    store={copy=function(v) return v end,store=function() return {value=job,save=function() return true end} end},mods={
      display={screen=function(_,r,i) render,input=r,i end},
      state={canStart=function() return true end,emit=function(name,data) events[#events+1]={name=name,data=data} end},
      lease={status=function(id) return status[id] or {} end,onReport=function() end},
      drops={list=function() return points end},
    }}},{__index=_G})
  local module=assert(loadfile(kind=="mine" and "so-mod-mine.lua" or "so-mod-lumber.lua","t",env))()
  module.tick(0)
  return {job=job,events=events,points=points,paired=paired,status=status,
    input=function(text) input({text=text}) end,tap=function(button) input({id=button.id,x=button.x,y=button.y}) end,render=function(w,h) return render(w,h) end,mods=env.SO.mods}
end
return function(test,equal)
  test("mining start lists exact missing items and accepts a complete paired job",function()
    local s=fixture("mine")
    s.input("start")
    equal(s.events[#s.events].data.missing,{"home not set","no ore chest set","no fuel chest set","paired turtle missing","fuel missing"})
    assert(not s.job.running)
    s.input("home 0 0 0 n")
    s.points[1]={id="ore",dim=0,x=1,y=0,z=0,kind="ore",broken=true}
    s.points[2]={id="fuel",dim=0,x=2,y=0,z=0,kind="fuel"}
    s.job.turtles["2"]={fuel=0,pose={x=0,y=0,z=0,facing=0}}
    s.input("start")
    equal(s.events[#s.events].data.missing,{"ore #ore broken at 1,0,0","paired turtle missing","fuel missing #2"})
    s.points[1].broken=false s.paired[2]="paired" s.job.turtles["2"].fuel=1000
    s.status[2]={uncertain=true} s.input("start")
    equal(s.events[#s.events].data.missing,{"paired turtle missing"})
    s.status[2]={}
    local home=s.job.home s.job.home=nil s.input("start")
    equal(s.events[#s.events].data.missing,{"home not set"})
    s.job.home=home s.input("start") assert(s.job.running)
    s.input("stop") assert(not s.job.running)
    s.mods.state.canStart=function() return false,"disk >=80%; free space" end
    s.input("start") assert(not s.job.running)
    equal(s.events[#s.events].data.text,"disk >=80%; free space")
  end)
  test("lumber start lists exact missing items and accepts a complete paired job",function()
    local s=fixture("lumber") s.input("start")
    equal(s.job.alert,"area not set; ground not set; no wood chest set; no fuel chest set; no saplings chest set; paired turtle missing; fuel missing")
    assert(not s.job.running)
    s.job.area={x1=0,x2=2,z1=0,z2=2} s.job.ground=0
    s.points[1]={id="wood",dim=0,x=-1,y=0,z=0,kind="wood"}
    s.points[2]={id="fuel",dim=0,x=-2,y=0,z=0,kind="fuel"}
    s.job.saplings={x=-3,y=0,z=0,side="down"}
    s.points[3]={id="saplings",dim=0,x=-3,y=0,z=0,side="down",kind="storage",broken=true}
    s.job.turtle={id=2,pose={x=0,y=2,z=0,facing=0}}
    s.paired[2]="paired" s.job.fuel=1000 s.input("start")
    equal(s.job.alert,"saplings #saplings broken at -3,0,0")
    s.points[3].broken=false s.input("start") assert(s.job.running) equal(s.job.alert,nil)
    s.input("stop") s.paired[2]=nil s.input("start")
    equal(s.job.alert,"paired turtle missing") assert(not s.job.running)
  end)
  test("readiness ignores broken chests when a usable fallback exists in the same dimension",function()
    local points={{id="bad",dim=0,x=0,y=0,z=0,kind="ore",broken=true},
      {id="other-world",dim=-1,x=1,y=0,z=0,kind="ore"}}
    local near={dim=0,x=0,y=0,z=0}
    equal(P.chestCheck(points,"ore",near).ok,false)
    points[3]={id="fallback",dim=0,x=2,y=0,z=0,kind="any"}
    equal(P.chestCheck(points,"ore",near).ok,true)
  end)
  for _,kind in ipairs({"mine","lumber"}) do for _,size in ipairs({{26,20},{29,12}}) do
    test(kind.." setup shows compact missing rows at "..size[1].."x"..size[2],function()
      local s=fixture(kind) s.input("start")
      local main=s.render(unpack(size))
      local button
      for _,b in ipairs(main.buttons) do if b.id=="setup" then button=b end end
      assert(button)
      s.tap(button)
      local frame=s.render(unpack(size))
      local all={}
      for _,row in ipairs(frame.rows) do all[#all+1]=row.text end
      local text=table.concat(all,"\n")
      for _,missing in ipairs(kind=="mine" and {"home not set","no ore chest set","no fuel chest set","paired turtle missing","fuel missing"}
          or {"area not set","ground not set","no wood chest set","no fuel chest set","no saplings chest set","paired turtle missing","fuel missing"}) do
        assert(text:find(missing,1,true),missing)
      end
      assert(not text:find("home 0,0,0",1,true))
      for _,b in ipairs(frame.buttons) do if b.id=="mine-back" or b.id=="lumber-back" then s.tap(b) return end end
      error("missing setup BACK")
    end)
  end end
end
