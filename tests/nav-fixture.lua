return function(Nav,mocks)
  return function(options)
    options=options or {}
    local m=mocks.new(false)
    local p={dim="minecraft:overworld",x=-2,y=65,z=0,h=1}
    local blocks,faults,nav={},{}
    local fuel,gps,dug,reservations=1000,true,0,0
    local function key(x,y,z) return x .. "," .. y .. "," .. z end
    local function target(d)
      return p.x+({[0]=0,1,0,-1,0,0})[d],p.y+({[0]=0,0,0,0,1,-1})[d],p.z+({[0]=-1,0,1,0,0,0})[d]
    end
    local t={getFuelLevel=function() return fuel end}
    for _,v in ipairs({{"",nil},{"Up",4},{"Down",5}}) do
      local suffix,d=v[1],v[2]
      t["inspect" .. suffix]=function()
        local x,y,z=target(d or p.h) local name=blocks[key(x,y,z)]
        return name~=nil,name and {name=name} or "No block"
      end
      t["dig" .. suffix]=function()
        local x,y,z=target(d or p.h)
        blocks[key(x,y,z)]=options.falling and "minecraft:gravel" or nil
        dug=dug+1 return true
      end
    end
    for _,v in ipairs({{"forward",nil},{"up",4},{"down",5}}) do
      local method,d=v[1],v[2]
      t[method]=function()
        if faults.move then faults.move=nil return false,"entity" end
        local x,y,z=target(d or p.h)
        if blocks[key(x,y,z)] then return false,"blocked" end
        if options.duringMove then options.duringMove(nav) end
        p.x,p.y,p.z=x,y,z
        if fuel~="unlimited" then fuel=fuel-1 end
        return true
      end
    end
    for _,v in ipairs({{"turnLeft",3},{"turnRight",1}}) do
      local method,delta=v[1],v[2]
      t[method]=function()
        if faults.turn then faults.turn=nil return false,"failed turn" end
        p.h=(p.h+delta)%4 return true
      end
    end
    m.env.turtle=t
    m.env.dofile=function(path) return assert(loadfile(path,"t",m.env))() end
    local cfg={pose={dim=p.dim,x=p.x,y=p.y,z=p.z,h=p.h},bounds={min={dim=p.dim,x=-5,y=63,z=-5},max={dim=p.dim,x=5,y=68,z=5}},
      canExcavate=function(info) return info.name=="minecraft:stone" end,maxNodes=options.maxNodes,maxCells=options.maxCells,batch=options.batch,
      traffic=options.traffic,trafficWaits=3,gpsFree=options.gpsFree,moveCost=options.moveCost,
      charging=options.charging,regeneration=options.regeneration,check=options.check,
      observe=options.observe or function() if gps then return {dim=p.dim,x=p.x,y=p.y,z=p.z} end end,
      yield=function() if options.onYield then options.onYield(nav) end end,
      checkpoint=function(name) if options.crash==name then error("crash " .. name) end end,
      client={call=options.call,resync=function() return true,nil,options.epoch end,calibrate=function()
        if faults.calibration then faults.calibration=nil return false,"offline" end
        return true
      end,anchor=options.anchor,move=function(from,to,execute)
        assert(math.abs(to.x-from.x)+math.abs(to.y-from.y)+math.abs(to.z-from.z)==1)
        reservations=reservations+1 return execute()
      end}}
    if options.trapGps then
      setmetatable(m.env,{__index=function(_,k)
        if k=="gps" then error("N1 read GPS",0) end
        return _G[k]
      end})
    end
    local function open() nav=m.env.dofile("nav.lua").open(cfg) return nav end
    open()
    return {nav=nav,reopen=open,air=function(v) nav.record({dim=p.dim,x=v[1],y=v[2],z=v[3]},"minecraft:air") end,
      block=function(x,y,z,name) blocks[key(x,y,z)]=name end,
      fault=function(name) faults[name]=true end,fuel=function(v) fuel=v end,gps=function(v) gps=v end,
      relocate=function(x,y,z,h) p.x,p.y,p.z,p.h=x,y,z,h end,heading=function() return p.h end,
      digs=function() return dug end,reservations=function() return reservations end,
      equalPose=function() local q=nav.pose() assert(q.x==p.x and q.y==p.y and q.z==p.z and q.h==p.h,"pose mismatch") end}
  end
end
