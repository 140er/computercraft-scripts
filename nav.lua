local M = {}
local A, S = dofile("atomic.lua"), dofile("ssot.lua")
local vectors = { [0]={0,0,-1}, {1,0,0}, {0,0,1}, {-1,0,0}, {0,1,0}, {0,-1,0} }
local function key(p) return p.x .. "," .. p.y .. "," .. p.z end
local function same(a,b) return a.dim==b.dim and key(a)==key(b) end
local function adjacent(p,d)
  local v=vectors[d]
  return {dim=p.dim,x=p.x+v[1],y=p.y+v[2],z=p.z+v[3]}
end
local function distance(a,b) return math.abs(a.x-b.x)+math.abs(a.y-b.y)+math.abs(a.z-b.z) end
local function integer(n) return type(n)=="number" and n==n and n%1==0 end
local function heading(h) return integer(h) and h>=0 and h<4 end
local sources={gps=true,neighbour=true,radio=true,typed=true,reckoned=true,inherited=true}
local function legacyPose(p)
  return S.pose(p) and p.v==nil and p.frame==nil and p.yAbs==nil
    and p.conf==nil and p.src==nil and p.anchoredAt==nil
end
local function serverEpoch(value)
  if type(value)=="string" and value:match("^%d+$") then value=tonumber(value) end
  if integer(value) and value>=0 and value<=2147483647 then return value end
end
local function inside(p,b)
  return p.dim==b.min.dim and p.x>=b.min.x and p.x<=b.max.x
    and p.y>=b.min.y and p.y<=b.max.y and p.z>=b.min.z and p.z<=b.max.z
end
function M.open(cfg)
  assert(legacyPose(cfg.pose) and heading(cfg.pose.h),"calibrated pose required")
  local b=cfg.bounds
  assert(type(b)=="table" and legacyPose(b.min) and legacyPose(b.max) and b.min.dim==b.max.dim
    and b.min.x<=b.max.x and b.min.y<=b.max.y and b.min.z<=b.max.z and inside(cfg.pose,b),"navigation bounds required")
  local maxCells,maxNodes,batch=cfg.maxCells or 2048,cfg.maxNodes or 2048,cfg.batch or 32
  assert(integer(maxCells) and maxCells>=1 and maxCells<=4096 and integer(maxNodes) and maxNodes>=1
    and maxNodes<=4096 and integer(batch) and batch>=1 and batch<=64,"invalid navigation budget")
  local function valid(v)
    if type(v)~="table" or v.version~=1 or not legacyPose(v.pose) or not heading(v.pose.h)
      or type(v.cells)~="table" then return false end
    local n=0
    for k,name in pairs(v.cells) do
      n=n+1
      if n>(cfg.beforeAction and 4096 or maxCells) or type(k)~="string" or #k>96 or type(name)~="string" or #name>128 then return false end
    end
    local j=v.action
    local c=v.control
    if c~=nil and (type(c)~="table" or not integer(c.epoch) or c.epoch<0 or c.epoch>2147483647 or not integer(c.cid) or c.cid<0 or c.cid>2147483647
      or c.kind~=nil and c.kind~="go" and c.kind~="recall" and c.kind~="estop" and c.kind~="recharge" and c.kind~="view_move"
      or c.complete~=nil and type(c.complete)~="boolean"
      or c.rechargeId~=nil and (type(c.rechargeId)~="string" or #c.rechargeId>80)) then return false end
    if v.rechargeId~=nil and (type(v.rechargeId)~="string" or #v.rechargeId>80) then return false end
    if v.stopped~=nil and type(v.stopped)~="boolean" or v.resume~=nil and type(v.resume)~="boolean" then return false end
    if v.trail~=nil then
      if type(v.trail)~="table" or #v.trail>64 then return false end
      for i,p in pairs(v.trail) do if not integer(i) or i<1 or i>#v.trail or not legacyPose(p) then return false end end
    end
    return j==nil or type(j)=="table" and (j.kind=="move" or j.kind=="turn" or j.kind=="calibrate")
      and legacyPose(j.from) and legacyPose(j.to) and heading(j.from.h) and heading(j.to.h)
  end
  local store=A.store(cfg.path or "nav.state",valid,400000)
  local state=store.value or {version=1,pose=A.copy(cfg.pose),cells={}}
  state.trail=state.trail or {}
  local api,busy,stopped,ready={},false,state.stopped==true,false
  local anchoredAt=0
  local function save() assert(store.save(state)) end
  local function checkpoint(name) if cfg.checkpoint then cfg.checkpoint(name) end end
  local function observe()
    local p=cfg.observe()
    if not legacyPose(p) or p.dim~=state.pose.dim then return nil,"GPS unavailable or wrong dimension" end
    anchoredAt=os.epoch("utc")
    return p
  end
  local function cancelled() return stopped or cfg.cancelled and cfg.cancelled() end
  local function boundary(policy,to)
    if cancelled() then return false,"cancelled" end
    if cfg.beforeAction then
      local ok,why=cfg.beforeAction(policy,to)
      if not ok then return false,why end
    end
    if cancelled() then return false,"cancelled" end
    return true
  end
  local function actionReady()
    if cancelled() then return false,"cancelled" end
    if cfg.actionReady then return cfg.actionReady() end
    return true
  end
  function api.configure(v)
    assert(integer(v.navMaxCells) and v.navMaxCells>=1 and v.navMaxCells<=4096
      and integer(v.navMaxSearch) and v.navMaxSearch>=1 and v.navMaxSearch<=4096
      and integer(v.navBatch) and v.navBatch>=1 and v.navBatch<=64,"invalid navigation budget")
    maxCells,maxNodes,batch=v.navMaxCells,v.navMaxSearch,v.navBatch
    cfg.traffic=v.traffic
    cfg.trafficWaits,cfg.trafficWaitMs=v.trafficWaits,v.trafficWaitMs
    cfg.routeRetries,cfg.trafficRouteRetries=v.routeRetries,v.trafficRouteRetries
    cfg.trailLength=v.trailLength
  end
  local function remember(p,name)
    local k=key(p)
    if not state.cells[k] then
      local n=0 for _ in pairs(state.cells) do n=n+1 end
      assert(n<maxCells,"navigation map full; export or recalibrate")
    end
    state.cells[k]=name
  end
  local function sync(previous)
    local ok,why,epoch
    if previous then ok,why,epoch=cfg.client.calibrate(state.pose,previous)
    else ok,why,epoch=cfg.client.resync(state.pose) end
    if not ok then return false,why end
    local announced=epoch
    epoch=serverEpoch(epoch)
    if announced~=nil and epoch==nil then return false,"invalid server epoch" end
    if epoch and (not state.control or epoch>state.control.epoch) then
      state.control={epoch=epoch,cid=0,kind=state.control and state.control.kind,complete=state.control and state.control.complete,
        rechargeId=state.control and state.control.rechargeId}
    end
    state.action=nil remember(state.pose,"minecraft:air") save() ready=true
    return true
  end
  function api.recover()
    if busy then return false,"navigation busy" end
    ready=false
    local p,why=observe()
    if not p then return false,why end
    local j=state.action
    if j and j.kind=="turn" then return false,"ambiguous turn; calibrate heading" end
    if j and j.kind=="calibrate" then
      if not same(p,j.to) then return false,"relocated during calibration" end
      state.pose=A.copy(j.to)
      return sync(j.from)
    end
    if j then
      if same(p,j.to) then state.pose=A.copy(j.to)
      elseif same(p,j.from) then state.pose=A.copy(j.from)
      else return false,"relocated during move; calibrate pose" end
    elseif not same(p,state.pose) then return false,"relocated turtle; calibrate pose" end
    return sync()
  end
  function api.calibrate(h)
    if busy then return false,"navigation busy" end
    if not heading(h) then return false,"invalid heading" end
    ready=false
    local p,why=observe()
    if not p then return false,why end
    if not inside(p,b) then return false,"outside navigation bounds" end
    local previous=A.copy(state.action and state.action.from or state.pose)
    if not same(p,state.pose) then state.cells={} state.trail={} end
    p.h=h state.pose=A.copy(p) state.action={kind="calibrate",from=previous,to=A.copy(p)} save()
    return sync(previous)
  end
  function api.pose() return A.copy(state.pose) end
  function api.confirmed() return ready and state.action==nil end
  function api.fleetPose(p)
    if not api.confirmed() or anchoredAt<=0 then return false end
    p=p or state.pose
    if not legacyPose(p) or not heading(p.h) or not inside(p,b) then return false end
    -- GPS and the legacy journal establish this observation, not framed SSOT authority.
    return {v=1,frame="abs",yAbs=true,dim=p.dim,x=p.x,y=p.y,z=p.z,h=p.h,
      conf="certain",src=same(p,state.pose) and "gps" or "inherited",anchoredAt=anchoredAt}
  end
  function api.legacyTarget(p)
    if type(p)~="table" or p.v~=1 or p.frame~="abs" or p.yAbs~=true or p.conf~="certain"
      or not integer(p.anchoredAt) or p.anchoredAt<=0 or p.anchoredAt>9007199254740991
      or not sources[p.src] or not heading(p.h) or not S.pose(p)
      or not inside(p,b) then return nil,"anchored absolute service pose required" end
    return {dim=p.dim,x=p.x,y=p.y,z=p.z,h=p.h}
  end
  function api.stopped() return stopped end
  function api.stop() stopped=true state.stopped=true state.resume=nil save() end
  function api.resume()
    if busy then return false end
    stopped=false state.stopped=false state.resume=nil save() return true
  end
  function api.controlState() return A.copy(state.control or {}) end
  function api.rechargeReceipt() return state.rechargeId end
  function api.control(kind,epoch,cid,rechargeId)
    if (kind~="go" and kind~="recall" and kind~="estop" and kind~="recharge" and kind~="view_move") or not integer(epoch) or epoch<0 or epoch>2147483647
      or not integer(cid) or cid<1 or cid>2147483647 then return false,"invalid command" end
    if kind=="recharge" and (type(rechargeId)~="string" or #rechargeId<1 or #rechargeId>80) then return false,"invalid command" end
    if kind=="recharge" and state.rechargeId==rechargeId then return false,"duplicate recharge" end
    local c=state.control
    if c and (epoch<c.epoch or epoch==c.epoch and cid<=c.cid) then return false,"stale command" end
    state.control={kind=kind,epoch=epoch,cid=cid,rechargeId=kind=="recharge" and rechargeId or nil}
    if kind=="recharge" then state.rechargeId=rechargeId end
    state.resume=nil
    if kind=="estop" then stopped=true state.stopped=true
    elseif kind=="go" then
      if busy then state.resume=true else stopped=false state.stopped=false end
    end
    save()
    return true
  end
  function api.completeControl(epoch,cid,rechargeId)
    local current=state.control
    if not current or (rechargeId and (current.kind~="recharge" or current.rechargeId~=rechargeId))
      or not rechargeId and (current.epoch~=epoch or current.cid~=cid) then return false end
    current.complete=true
    save()
    return true
  end
  function api.resumePending()
    if not state.resume or busy or not ready then return false end
    return api.resume()
  end
  function api.record(p,name)
    assert(not busy and legacyPose(p) and inside(p,b) and type(name)=="string" and #name<=128,"invalid observation")
    remember(p,name) save()
  end
  function api.import(cells,dim)
    assert(not busy and type(cells)=="table" and #cells<=1024 and dim==b.min.dim,"invalid map import")
    local merged=A.copy(state.cells)
    for _,cell in ipairs(cells) do
      local p={dim=dim,x=cell.x,y=cell.y,z=cell.z}
      assert(S.pose(p) and (cell.name==false or type(cell.name)=="string" and #cell.name<=128),"invalid map cell")
      if inside(p,b) then merged[key(p)]=cell.name==false and "minecraft:air" or cell.name end
    end
    local count=0 for _ in pairs(merged) do count=count+1 end
    assert(count<=maxCells,"navigation map full; export or recalibrate")
    state.cells=merged save()
  end
  local function turn(h,policy)
    while state.pose.h~=h do
      local allowed,reason=boundary(policy or "walk")
      if not allowed then return false,reason end
      local from=A.copy(state.pose)
      local delta=(h-from.h)%4==3 and 3 or 1
      local to=A.copy(from) to.h=(from.h+delta)%4
      state.action={kind="turn",from=from,to=to} save() checkpoint("turn-prepared")
      local allowed,reason=actionReady()
      if not allowed then state.action=nil save() return false,reason end
      local ok,why=(delta==3 and turtle.turnLeft or turtle.turnRight)()
      checkpoint("turn-physical")
      state.pose=ok and to or from state.action=nil save() checkpoint("turn-saved")
      if not ok then return false,why end
    end
    return true
  end
  local function owned(fn,...)
    if busy then return false,"navigation busy" end
    if not ready then return false,"navigation needs recovery" end
    if cancelled() then return false,"cancelled" end
    busy=true
    local ok,a,c=pcall(fn,...)
    busy=false
    if not ok then ready=false error(a,0) end
    return a,c
  end
  function api.face(h)
    if not heading(h) then return false,"invalid heading" end
    return owned(turn,h)
  end
  local search
  local function fuelSafe()
    if cfg.fuelReserve and turtle.getFuelLevel()~="unlimited" then
      local home,reserve=cfg.fuelReserve()
      if home then
        local route,why=search(home,"walk",{})
        if not route then return false,"no home route: "..tostring(why) end
        if turtle.getFuelLevel()<#route+2+reserve then return false,"low fuel" end
      end
    end
    return true
  end
  local function step(d,policy)
    local allowed,reason=boundary(policy,adjacent(state.pose,d))
    if not allowed then return false,reason end
    allowed,reason=fuelSafe() if not allowed then return false,reason end
    local observed,err=observe()
    if not observed or not same(observed,state.pose) then ready=false return false,err or "relocated turtle; calibrate pose" end
    local to=adjacent(state.pose,d)
    if not inside(to,b) then return false,"outside navigation bounds" end
    if policy=="walk" and state.cells[key(to)]~="minecraft:air" then return false,"unknown route" end
    if d<4 then local ok,why=turn(d,policy) if not ok then return false,why end end
    if cancelled() then return false,"cancelled" end
    local from=A.copy(state.pose) to.h=from.h
    local inspect=d==4 and turtle.inspectUp or d==5 and turtle.inspectDown or turtle.inspect
    local dig=d==4 and turtle.digUp or d==5 and turtle.digDown or turtle.dig
    local move=d==4 and turtle.up or d==5 and turtle.down or turtle.forward
    local function permitted()
      local found,info=inspect()
      local name=found and info.name or "minecraft:air"
      if name:find("turtle",1,true) then return false,"occupied" end
      remember(to,name)
      if found and (name=="minecraft:water" or name=="minecraft:lava" or policy~="excavate"
        or not cfg.canExcavate or not cfg.canExcavate(info,to)) then return false,"blocked" end
      return true,found
    end
    local allowed,reason=permitted()
    if not allowed then save() return false,reason end
    if turtle.getFuelLevel()==0 then save() return false,"out of fuel" end
    state.action={kind="move",from=from,to=to} save() checkpoint("move-prepared")
    local ok,why=cfg.client.move(from,to,function()
      if cancelled() then return false,"cancelled" end
      local allowed,found=permitted()
      if not allowed then return false,found end
      if found then
        local allowed,why=boundary(policy,to) if not allowed then return false,why end
        allowed,why=fuelSafe() if not allowed then return false,why end
        allowed,found=permitted() if not allowed then return false,found end
        if found then
          local allowed,why=actionReady() if not allowed then return false,why end
          local dug,err=dig()
          if not dug then return false,err end
        end
        if cancelled() then return false,"cancelled" end
        if inspect() then return false,"falling block" end
      end
      checkpoint("move-started")
      local allowed,why=boundary(policy,to) if not allowed then return false,why end
      allowed,why=fuelSafe() if not allowed then return false,why end
      allowed,why=actionReady() if not allowed then return false,why end
      local moved,err=move()
      checkpoint("move-physical")
      if moved then
        local observed=observe()
        assert(observed and same(observed,to),"physical pose needs GPS reconciliation")
        if cfg.traffic then
          if #state.trail>0 and same(state.trail[#state.trail],to) then table.remove(state.trail)
          else state.trail[#state.trail+1]=A.copy(from) end
          while #state.trail>(cfg.trailLength or 64) do table.remove(state.trail,1) end
        end
        state.pose=A.copy(to) remember(to,"minecraft:air")
      end
      save() checkpoint("move-observed")
      return moved,err
    end)
    state.action=nil save() checkpoint("move-saved")
    return ok,why
  end
  function api.step(d,policy)
    if not integer(d) or not vectors[d] or policy~="walk" and policy~="explore" and policy~="excavate" then return false,"invalid movement policy" end
    return owned(step,d,policy)
  end
  search=function(goal,policy,avoid,from)
    local start=A.copy(from or state.pose)
    local open,cost,parent,nodes={{p=start,g=0,f=distance(start,goal)}},{},{},1
    cost[key(start)]=0
    local expanded=0
    while #open>0 do
      if cancelled() then return nil,"cancelled" end
      local best=1
      for i=2,#open do if open[i].f<open[best].f then best=i end end
      local current=table.remove(open,best)
      local p,k=current.p,key(current.p)
      if same(p,goal) then
        local route={}
        while parent[k] do table.insert(route,1,parent[k].d) k=parent[k].previous end
        return route
      end
      if current.g==cost[k] then
        expanded=expanded+1
        if expanded%batch==0 then (cfg.yield or sleep)(0) end
        if cancelled() then return nil,"cancelled" end
        for d=0,5 do
          local q=adjacent(p,d) local qk=key(q)
          local name=state.cells[qk]
          local pass=name=="minecraft:air" or policy=="explore" and name==nil
            or policy=="excavate" and (name==nil or cfg.canExcavate and cfg.canExcavate({name=name},q))
          if inside(q,b) and not avoid[qk] and pass then
            local g=current.g+(name=="minecraft:air" and 1 or 3)
            if not cost[qk] or g<cost[qk] then
              if not cost[qk] then nodes=nodes+1 end
              if nodes>maxNodes then return nil,"search budget" end
              cost[qk]=g parent[qk]={previous=k,d=d}
              open[#open+1]={p=q,g=g,f=g+distance(q,goal)}
            end
          end
        end
      end
    end
    return nil,"no route"
  end
  function api.homeCost(goal,from)
    if not legacyPose(goal) or not inside(goal,b) or from~=nil and (not legacyPose(from) or not inside(from,b)) then return false,"invalid route" end
    return owned(function()
      local route,why=search(goal,"walk",{},from)
      if not route then return false,why end
      return #route
    end)
  end
  local function traffic(target)
    local r,why=cfg.client.call("traffic",{to=target})
    if not r or not r.ok then return false,why or "traffic server unavailable" end
    if not r.peer then (cfg.yield or sleep)((cfg.trafficWaitMs or 250)/1000) return true end
    if not r.yield then (cfg.yield or sleep)((cfg.trafficWaitMs or 250)/1000) return true end
    if not r.pose then return false,"traffic pose unavailable" end
    local origin,peer=A.copy(state.pose),r.peer
    local axis={x=target.x-origin.x,y=target.y-origin.y,z=target.z-origin.z}
    local found=false
    local retreats=0
    while retreats<(cfg.trailLength or 64)+1 do
      local allowed,why=boundary("walk") if not allowed then return false,why end
      if not cfg.traffic then return false,"traffic disabled" end
      retreats=retreats+1
      for d=0,5 do
        local v=vectors[d]
        if v[1]*axis.x+v[2]*axis.y+v[3]*axis.z==0 then
          local q=adjacent(state.pose,d)
          if inside(q,b) and state.cells[key(q)]=="minecraft:air" then
            local ok=step(d,"walk")
            if ok then found=true break end
          end
        end
      end
      if found then break end
      local back=state.trail[#state.trail]
      for d=0,5 do
        local v=vectors[d]
        local q=adjacent(state.pose,d)
        if v[1]*axis.x+v[2]*axis.y+v[3]*axis.z<0 and inside(q,b) and state.cells[key(q)]=="minecraft:air" then back=q break end
      end
      if not back then return false,"traffic dead end" end
      local moved=false
      for d=0,5 do
        if same(adjacent(state.pose,d),back) then
          local ok,err=step(d,"walk") if not ok then return false,err end
          moved=true break
        end
      end
      if not moved then return false,"traffic trail needs reconciliation" end
    end
    if not found then return false,"traffic retreat budget" end
    checkpoint("traffic-yielded")
    local waits=0
    while waits<(cfg.trafficWaits or 80) do
      local allowed,why=boundary("walk") if not allowed then return false,why end
      if not cfg.traffic then return false,"traffic disabled" end
      waits=waits+1
      local p,err=cfg.client.call("traffic",{peer=peer})
      if not p or not p.ok or not p.pose then return false,err or "traffic peer unavailable" end
      if p.pose.dim==origin.dim and distance(p.pose,origin)>1 and distance(p.pose,state.pose)>2 then return true end
      (cfg.yield or sleep)((cfg.trafficWaitMs or 250)/1000)
    end
    return false,"traffic wait budget"
  end
  function api.go(goal,policy)
    if not legacyPose(goal) or not inside(goal,b) or policy~="walk" and policy~="explore" and policy~="excavate" then return false,"invalid route" end
    return owned(function()
      local avoid={}
      local attempts=0
      while attempts<(cfg.traffic and (cfg.trafficRouteRetries or 80) or (cfg.routeRetries or 5)) do
        attempts=attempts+1
        local route,why=search(goal,policy,avoid)
        if not route then return false,why end
        local complete=true
        for _,d in ipairs(route) do
          local target=adjacent(state.pose,d)
          local ok,err=step(d,policy)
          if not ok then
            if cfg.beforeAction then
              local allowed,why=boundary(policy) if not allowed then return false,why end
            end
            if not ready then return false,err end
            if err=="cancelled" or err=="out of fuel" or err=="low fuel" or err=="fresh fleet settings required" then return false,err end
            if err=="occupied" or err=="already reserved" then
              if not cfg.traffic then return false,err end
              local detour=A.copy(avoid) detour[key(target)]=true
              if search(goal,policy,detour) then avoid=detour
              else local ok,why=traffic(target) if not ok then return false,why end end
            else avoid[key(target)]=true end
            complete=false break
          end
        end
        if complete then return true end
      end
      return false,"replan budget"
    end)
  end
  return api
end
return M
