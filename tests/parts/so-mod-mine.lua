local function fixture()
  local job = { homeSet=true, home={x=0,y=0,z=0,facing=0}, bottom=-2, length=4,
    dim="minecraft:overworld", mode="fast", ores={}, turtles={}, running=false,
    progress={nextBranch=0,done=0} }
  local calls, status, reservations, callback, input = {}, {}, {}, nil, nil
  local function copy(v)
    if type(v) ~= "table" then return v end
    local out={} for k,x in pairs(v) do out[k]=copy(x) end return out
  end
  local function key(x,y,z) return x..","..y..","..z end
  local s = { job=job, calls=calls, status=status, range=true, saves=0, saveOK=true }
  local env = setmetatable({os={epoch=function() return 1000 end}, SO={mods={},
    breathe=function() end, store={copy=copy,store=function()
      return {value=job,save=function() s.saves=s.saves+1 return s.saveOK,"scratch disk full" end}
    end}}}, {__index=_G})
  local mods=env.SO.mods
  mods.state={canStart=function() return true end, emit=function() end}
  mods.display={screen=function(_,_,fn) input=fn end}
  mods.lease={onReport=function(_,fn) callback=fn end,
    status=function(id) return status[id] or {} end,
    inRange=function() return s.range end,
    send=function(id,steps,opts) calls[#calls+1]={id=id,steps=copy(steps),opts=copy(opts)} return #calls end}
  mods.cells={owner=function(x,y,z) return reservations[key(x,y,z)] end,
    reserve=function(who,x,y,z) reservations[key(x,y,z)]=who return true end,
    reserveMany=function() return true end, releaseOwner=function() return true end}
  local mine=assert(loadfile("so-mod-mine.lua","t",env))()
  mine.tick()
  s.mine,s.mods=mine,mods
  s.input=function(text) input({text=text}) end
  s.report=function(id,results,facts) callback("test",id,results,{report=facts}) end
  s.row=function()
    local pose={dim=job.dim,x=10,y=-2,z=-5,facing=0}
    local row={pose=pose,anchor=copy(pose),frame={dim=job.dim,ox=0,oy=0,oz=0,rot=0},
      inv={},fuel=-1,state="mining",branch=3,route={copy(pose)},index=2}
    job.turtles["2"]=row
    return row
  end
  return s
end
return function(test,equal)
  test("mining refuses start without its disk guard or configured home",function()
    local s=fixture()
    s.mods.state=nil s.input("start") assert(not s.job.running)
    s.mods.state={canStart=function() return true end}
    s.job.homeSet=false s.input("start") assert(not s.job.running)
    s.job.homeSet=true s.input("start") assert(s.job.running)
  end)
  test("uncertain workers cannot receive a mining batch",function()
    local s=fixture() local row=s.row() s.job.running=true
    s.status[2]={uncertain=true} s.mine.tick()
    equal(#s.calls,0) equal(row.state,"hold")
    assert(row.error:find("pose uncertain",1,true))
  end)
  test("radio range refusal sends only a stationary park",function()
    local s=fixture() local row=s.row() s.job.running=true s.range=false
    s.mine.tick() equal(row.state,"range")
    equal(#s.calls,1) equal(s.calls[1].steps,{{op="inspectDown"}})
    equal(s.calls[1].opts.owner,"mine")
  end)
  test("a completed branch is counted once when recovery revisits it",function()
    local s=fixture() local row=s.row() s.job.running=true
    s.mine.tick() equal(s.job.progress.done,1) equal(row.counted,3)
    row.state="mining" row.parkUntil=nil s.mine.tick()
    equal(s.job.progress.done,1) equal(row.state,"done")
  end)
  test("disk failure stops a mining job",function()
    local s=fixture() s.saveOK=false s.input("start")
    assert(not s.job.running) assert(s.saves>0)
  end)
  test("retirement refuses recovery and protects a confirmed worker pose",function()
    local s=fixture() local row=s.row() local calls=0
    row.recover=true
    equal(s.mine.dugProtection(function() error("must refuse") end),false)
    row.recover=false
    equal(s.mine.dugProtection(function(dim,record,padding)
      equal(dim,s.job.dim) assert(record==row) equal(padding,48) calls=calls+1
    end),true)
    equal(calls,1)
  end)
  test("expired reports keep the worker in recovery",function()
    local s=fixture() local row=s.row()
    s.report(2,nil,nil) equal(row.state,"lost") equal(row.recover,true)
    s.mine.tick() assert(s.calls[1].opts.recover)
  end)
end
