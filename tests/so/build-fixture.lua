local P = dofile("so-plan.lua")
local function copy(v)
  if type(v) ~= "table" then return v end
  local out={} for k,x in pairs(v) do out[k]=copy(x) end return out
end
local function key(p) return p.x .. "," .. p.y .. "," .. p.z end
local function fixture(config)
  config=config or {}
  local f={world={},held={},saved=nil,now=1000,serial=0,placed={},calls={},fuel=10000,saveOK=true,range=function() return true end}
  f.journal="builder-journal"
  local pose={dim="minecraft:overworld",x=-2,y=4,z=0,facing=1}
  local inv,selected={},1
  local input,render,callback,queued,mod
  local function inventory()
    local out={} for slot,item in pairs(inv) do if item.count>0 then out[#out+1]={slot=slot,name=item.name,count=item.count} end end
    return out
  end
  local env=setmetatable({SO={now=function() return f.now end,breathe=function() end,
    pair={key=function() return "paired" end},store={copy=copy,read=function() return config end,store=function()
      return {value=copy(f.saved),save=function(j)
        if not f.saveOK then return false,"disk full" end
        f.saved=copy(j) f.saves=(f.saves or 0)+1 return true
      end}
    end},mods={}}},{__index=_G})
  local mods=env.SO.mods
  mods.state={canStart=function() return true end,emit=function(kind,data) f.alert=type(data)=="table" and data.text or false f.event=kind end,
    get=function() return {pose=copy(pose)} end}
  mods.display={screen=function(_,r,i) render,input=r,i end}
  mods.lease={peek=function() return {uncertain=f.uncertain,lost=f.lost} end,status=function() return {open=queued and queued.id,uncertain=f.uncertain,lost=f.lost,parkBatch=f.parkBatch~=false,setupFence=f.setupFence~=false,journal=f.journal,
      pose={x=pose.x,y=pose.y,z=pose.z,f=pose.facing}} end,
    boundaries=function() return config.protectedAreas == true end,
    assess=function(_,from,steps)
      f.assessments=(f.assessments or 0)+1
      return P.assess(from,steps,{admit=function(_,_,to)
        local protected=f.protected and f.protected[key(to)]
        return not (f.assessmentError or protected),protected and "protected" or f.assessmentError
      end})
    end,
    locate=function(id,dim,done)
      f.located={id=id,dim=dim}
      if f.deferLocate then f.locateDone=done else done(f.locateError and nil or copy(pose),f.locateError) end
    end,
    inRange=function(_,p) return f.range(p) end,onReport=function(_,fn) callback=fn end,
    send=function(id,steps,opts)
      if f.sendError then return nil,f.sendError end
      f.serial=f.serial+1
      queued={id=f.serial,turtleId=id,steps=copy(steps),opts=opts}
      f.calls[#f.calls+1]=queued
      return queued.id
    end}
  mods.cells={owner=function(x,y,z) return f.held[x..","..y..","..z] end,
    reserveMany=function(who,cells)
      for _,p in ipairs(cells) do if f.held[key(p)] and f.held[key(p)]~=who then return false,"held" end end
      for _,p in ipairs(cells) do f.held[key(p)]=who end
      return true
    end,list=function(who)
      local out={}
      for k,v in pairs(f.held) do
        if v==who then local x,y,z=k:match("^(-?%d+),(-?%d+),(-?%d+)$") out[#out+1]={dim=pose.dim,x=tonumber(x),y=tonumber(y),z=tonumber(z)} end
      end
      return out
    end,release=function(who,x,y,z)
      local k=x..","..y..","..z if f.held[k]==who then f.held[k]=nil end return true
    end}
  local chest={id="supply",dim=0,x=-3,y=0,z=0,side="down",kind="storage"}
  mods.drops={choose=function(kind)
      f.choices=(f.choices or 0)+1
      local point=kind=="fuel" and f.fuelChest or kind=="storage" and f.chest or nil
      return {point=point and copy(point),alert=not point and ("no "..kind.." chest set") or nil}
    end,pick=function() error("builder must use read-only selection") end,note=function() end}
  f.chest=chest
  f.world[key(chest)]={name="minecraft:chest",stock=128}
  local function boot(quiet)
    mod=assert(loadfile("so-mod-build.lua","t",env))()
    mod.handlers.hello({from=2,body={capabilities={parkBatch=f.parkBatch~=false,setupFence=f.setupFence~=false}}})
    local onReport=mods.lease.onReport
    if quiet then mods.lease.onReport=nil end
    mod.tick()
    mods.lease.onReport=onReport
  end
  boot()
  f.mods,f.env=mods,env
  f.input=function(text) input({text=text}) end
  f.render=function(w,h,session) return render(w,h,session) end
  f.press=function(id,session) input({id=id,session=session}) end
  f.job=function() return copy(f.saved) end
  f.feedback=function(text)
    local rows={}
    for _,row in ipairs(render(150,30).rows) do rows[#rows+1]=row.text end
    assert(table.concat(rows,"\n"):find(text,1,true),"missing build feedback: "..text)
  end
  f.queued=function() return queued end
  f.setPose=function(value) pose=copy(value) end
  f.mod=function() return mod end
  f.tick=function() f.now=f.now+100 mod.tick() end
  f.report=function(drop,reportedFuel)
    local q=assert(queued,"no queued lease") queued=nil
    local results={}
    for i,step in ipairs(q.steps) do
      assert(not step.op:match("^dig"),"builder dug a block")
      local result={ok=true}
      if step.op=="select" then selected=step.slot
      elseif step.op=="inspectDown" or step.op=="inspect" then
        local x,y,z=P.ahead(pose,step.op=="inspectDown" and "down" or "forward")
        local block=f.world[x..","..y..","..z]
        result.ok=block~=nil
        if block then result.data={name=type(block)=="table" and block.name or block} else result.err="No block to inspect" end
      elseif step.op=="placeDown" then
        local at={x=pose.x,y=pose.y-1,z=pose.z}
        assert(f.held[key(at)]=="build:"..q.turtleId,"placement was not reserved")
        local block=inv[selected]
        result.ok=not f.placeError and not f.world[key(at)] and block and block.count>0 or false
        if result.ok then
          f.world[key(at)]=block.name block.count=block.count-1
          f.placed[key(at)]=(f.placed[key(at)] or 0)+1
        else result.err="Cannot place block here" end
      elseif step.op=="refuel" then
        local block=inv[selected]
        local value=block and P.fuelValue(block.name) or 0
        result.ok=value>0 and not f.refuelError
        if result.ok then
          local n=math.min(block.count,step.n or block.count)
          if f.fuel~="unlimited" then f.fuel=f.fuel+n*value end
          block.count=block.count-n
        end
      elseif step.op=="suckDown" or step.op=="suck" then
        local x,y,z=P.ahead(pose,step.op=="suckDown" and "down" or "forward")
        local supply=f.world[x..","..y..","..z]
        local n=supply and math.min(64,supply.stock or 0) or 0
        result.ok=n>0
        if result.ok then inv[selected]={name=supply.item or "minecraft:stone",count=n} supply.stock=supply.stock-n end
      else
        local nextPose=P.apply(pose,step.op)
        local move=step.op=="forward" or step.op=="up" or step.op=="down"
        if P.turns[step.op] and f.turnError then result.ok=false result.err=f.turnError
        elseif move and (f.fuel==0 or f.moveError) then result.ok=false result.err=f.moveError or "Out of fuel"
        elseif f.world[key(nextPose)] and move then result.ok=false result.err="Movement obstructed"
        else pose=nextPose if move and f.consumeFuel and f.fuel~="unlimited" then f.fuel=f.fuel-1 end end
      end
      results[i]=result
    end
    if f.journal then f.journal=f.journal.."-next" end
    if reportedFuel~=nil then f.fuel=reportedFuel end
    if not drop then
      local facts={pose={x=pose.x,y=pose.y,z=pose.z,f=pose.facing},inv=inventory(),fuel=f.fuel,journal=f.journal}
      if f.reportChange then f.reportChange(results,facts,q) end
      callback(q.id,q.turtleId,results,{report=facts})
    end
    return q
  end
  f.deliver=function(id,results,facts) callback(id,2,results,{report=facts}) end
  f.expire=function()
    local q=assert(queued,"no queued lease") queued=nil
    f.lost=true
    callback(q.id,q.turtleId,nil,{status="expired"})
  end
  f.restart=function(quiet) queued=nil boot(quiet) end
  f.configure=function(shape,x,y,z)
    f.input("area 0 0 0 " .. (x-1) .. " " .. (y-1) .. " " .. (z-1))
    f.input("shape " .. shape) f.input("material stone") f.input("add 2")
  end
  f.run=function(max)
    for _=1,max or 3000 do
      f.tick() if queued then f.report() end
      local j=f.job()
      if j and not j.running and not j.blocked then return end
      local retry=j and j.retryAt and f.now>=j.retryAt and j.service
        and (j.blocked=="material" and j.service.kind=="storage" or j.blocked=="fuel" and j.service.kind=="fuel")
      if j and j.blocked and not retry then error(j.alert) end
    end
    error("builder did not finish")
  end
  f.count=function() local n=0 for _ in pairs(f.placed) do n=n+1 end return n end
  f.inventory=inv
  return f
end

return fixture
