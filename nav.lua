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
local function inside(p,b)
  return p.dim==b.min.dim and p.x>=b.min.x and p.x<=b.max.x
    and p.y>=b.min.y and p.y<=b.max.y and p.z>=b.min.z and p.z<=b.max.z
end
function M.open(cfg)
  assert(S.pose(cfg.pose) and heading(cfg.pose.h),"calibrated pose required")
  local b=cfg.bounds
  assert(type(b)=="table" and S.pose(b.min) and S.pose(b.max) and b.min.dim==b.max.dim
    and b.min.x<=b.max.x and b.min.y<=b.max.y and b.min.z<=b.max.z and inside(cfg.pose,b),"navigation bounds required")
  local maxCells,maxNodes,batch=cfg.maxCells or 2048,cfg.maxNodes or 2048,cfg.batch or 32
  assert(integer(maxCells) and maxCells>=1 and maxCells<=4096 and integer(maxNodes) and maxNodes>=1
    and maxNodes<=4096 and integer(batch) and batch>=1 and batch<=64,"invalid navigation budget")
  local gpsFree=cfg.gpsFree==true
  local Pos=gpsFree and dofile("position.lua") or nil
  local function valid(v)
    if type(v)~="table" or v.version~=1 or not S.pose(v.pose) or not heading(v.pose.h)
      or type(v.cells)~="table" then return false end
    if v.pose.v~=nil and v.pose.v~=1 then return false end
    if v.pose.conf~=nil and v.pose.conf~="certain" and v.pose.conf~="suspect" and v.pose.conf~="lost" then return false end
    if v.bootSerial~=nil and (not integer(v.bootSerial) or v.bootSerial<0) then return false end
    if v.boot~=nil and (type(v.boot)~="string" or #v.boot>80) then return false end
    if v.journal~=nil then
      local j=v.journal
      if type(j)~="table" or j.v~=1 or type(j.lease)~="string" or #j.lease>80
        or not integer(j.seq) or j.seq<0 or not integer(j.committed) or j.committed<0 or j.committed>j.seq then return false end
      if j.acked~=nil and (not integer(j.acked) or j.acked<0 or j.acked>j.committed) then return false end
      if j.open~=nil and type(j.open)~="table" then return false end
      if j.probe~=nil and j.probe~=false and type(j.probe)~="table" then return false end
    end
    local n=0
    for k,name in pairs(v.cells) do
      n=n+1
      if n>maxCells or type(k)~="string" or #k>96 or type(name)~="string" or #name>128 then return false end
    end
    local j=v.action
    local c=v.control
    if c~=nil and (type(c)~="table" or not integer(c.epoch) or c.epoch<1 or not integer(c.cid) or c.cid<0
      or c.kind~=nil and c.kind~="go" and c.kind~="recall" and c.kind~="estop") then return false end
    if v.stopped~=nil and type(v.stopped)~="boolean" or v.resume~=nil and type(v.resume)~="boolean" then return false end
    if v.trail~=nil then
      if type(v.trail)~="table" or #v.trail>64 then return false end
      for i,p in pairs(v.trail) do if not integer(i) or i<1 or i>#v.trail or not S.pose(p) then return false end end
    end
    return j==nil or type(j)=="table" and (j.kind=="move" or j.kind=="turn" or j.kind=="calibrate")
      and S.pose(j.from) and S.pose(j.to) and heading(j.from.h) and heading(j.to.h)
  end
  local store=A.store(cfg.path or "nav.state",valid,400000)
  local state=store.value or {version=1,pose=A.copy(cfg.pose),cells={}}
  state.trail=state.trail or {}
  if gpsFree then
    state.journal=state.journal or {v=1,lease="local:"..os.getComputerID()..":1",seq=0,committed=0,acked=0,probe=false}
    state.bootSerial=(state.bootSerial or 0)+1
    state.boot="b:"..state.bootSerial
    if state.pose.v~=1 then
      local frame=state.pose.frame or "abs"
      local yAbs=not (frame~="abs" and state.pose.yAbs==false)
      state.pose={v=1,frame=frame,yAbs=yAbs,dim=state.pose.dim,x=state.pose.x,y=state.pose.y,z=state.pose.z,h=state.pose.h,
        conf="suspect",src="inherited",anchoredAt=0}
    end
  end
  local api,busy,stopped,ready={},false,state.stopped==true,false
  local function save() assert(store.save(state)) end
  if gpsFree then save() end
  local function checkpoint(name) if cfg.checkpoint then cfg.checkpoint(name) end end
  local function observe()
    local p=cfg.observe()
    if not S.pose(p) or p.dim~=state.pose.dim then return nil,"GPS unavailable or wrong dimension" end
    return p
  end
  local function cancelled() return stopped or cfg.cancelled and cfg.cancelled() end
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
    epoch=tonumber(epoch)
    if announced~=nil and (not integer(epoch) or epoch<1 or epoch>2147483647) then return false,"invalid server epoch" end
    if epoch and (not state.control or epoch>state.control.epoch) then
      state.control={epoch=epoch,cid=0,kind=state.control and state.control.kind}
    end
    state.action=nil remember(state.pose,"minecraft:air") save() ready=true
    return true
  end
  local function proof(v)
    if v=="none" or v=="possible" or v=="unknown" then return v end
    return "unknown"
  end
  local function faceName(ok,info)
    if ok and type(info)=="table" and type(info.name)=="string" then return info.name end
    return "minecraft:air"
  end
  local function probe()
    state.journal.probe={boot=state.boot,phase="intent"}
    save() checkpoint("probe-intent")
    local topOk,top=turtle.inspectUp()
    local botOk,bot=turtle.inspectDown()
    local side={}
    for i=1,4 do
      local ok,info=turtle.inspect()
      side[i]=faceName(ok,info)
      turtle.turnRight()
    end
    local faces={front=side[1],right=side[2],back=side[3],left=side[4],top=faceName(topOk,top),bottom=faceName(botOk,bot)}
    state.journal.probe={boot=state.boot,phase="done",localFaces=A.copy(faces)}
    save()
    return faces
  end
  local function predict(cell,origin)
    local faces={}
    for d=0,5 do
      local n=adjacent(cell,d)
      if same(n,origin) then faces[d]="minecraft:air"
      elseif state.cells[key(n)] then faces[d]=state.cells[key(n)] end
    end
    return faces
  end
  local function closeMove(succeeded,method,after)
    local open=state.journal.open
    if not open then return end
    local done=A.copy(open)
    done.phase,done.at="done",os.epoch("utc")
    done.evidence=A.copy(open.evidence)
    done.evidence.ok=succeeded and true or false
    done.evidence.fuelAfter=turtle.getFuelLevel()
    done.evidence.reason=succeeded and false or "failed"
    done.evidence.after=after or {}
    if method=="fuel" or method=="fingerprint" then done.evidence.recovery={boot=state.boot,method=method}
    else done.evidence.recovery=false end
    state.journal.last=done
    state.journal.open=nil
    state.journal.committed=done.seq
    state.action=nil
  end
  local function recoverFree()
    if busy then return false,"navigation busy" end
    ready=false
    if state.journal.probe and state.journal.probe.phase=="intent" then
      state.pose.conf,state.pose.src="lost","reckoned"
      save()
      return false,"interrupted probe"
    end
    local faces=probe()
    local decision
    if state.journal.open then
      local open=state.journal.open
      decision=Pos.resolveMove({
        fuelBefore=open.fuelBefore,fuelNow=turtle.getFuelLevel(),moveCost=open.evidence.moveCost,
        charging=open.evidence.charging,regeneration=open.evidence.regeneration,
        fromFaces=open.evidence.from,toFaces=open.evidence.to,localFaces=faces,heading=open.from.h,
      })
    else
      decision=Pos.resolveBoot({faces=state.journal.faces,localFaces=faces,heading=state.pose.h})
    end
    state.journal.probe=false
    if decision.conf=="certain" then
      if state.journal.open then
        local cell=decision.cell=="to" and state.journal.open.to or state.journal.open.from
        state.pose=A.copy(cell)
        state.pose.h=decision.heading
        state.pose.conf,state.pose.src="certain","reckoned"
        if decision.cell=="to" then remember(state.pose,"minecraft:air") end
      else
        state.pose.h=decision.heading
        state.pose.conf,state.pose.src="certain","neighbour"
      end
      state.journal.faces=Pos.rotate(faces,state.pose.h)
      closeMove(decision.cell=="to",decision.method,state.journal.faces)
      save()
      return sync()
    end
    state.pose.conf=decision.conf
    if decision.conf=="lost" then state.pose.src="reckoned" end
    save()
    return false,decision.conf
  end
  function api.recover()
    if gpsFree then return recoverFree() end
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
    if gpsFree then
      if busy then return false,"navigation busy" end
      if not heading(h) then return false,"invalid heading" end
      if state.pose.conf~="certain" then return false,"pose not certain" end
      if state.journal.open or (state.journal.probe and state.journal.probe.phase=="intent") then return false,"unresolved move" end
      state.pose.h=h save()
      return true
    end
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
  local function acceptAnchor(spec)
    if busy then return false,"navigation busy" end
    if type(spec)~="table" then return false,"invalid anchor" end
    ready=false
    local faces=probe()
    local world=Pos.rotate(faces,state.pose.h)
    local now=os.epoch("utc")
    local pos=Pos.makePos({
      frame=spec.frame or "abs",yAbs=spec.yAbs,dim=spec.dim or state.pose.dim,
      x=spec.x,y=spec.y,z=spec.z,h=spec.h or state.pose.h,
      conf="certain",src=spec.src or "typed",anchoredAt=now,
    })
    if not pos or not inside(pos,b) or pos.dim~=b.min.dim then
      state.journal.probe=false
      if pos and pos.dim~=state.pose.dim then
        state.pose.conf,state.pose.frame,state.pose.yAbs="lost","abs",true
      end
      save()
      return false,pos and "outside navigation bounds" or "invalid anchor"
    end
    if state.pose.dim and pos.dim~=state.pose.dim and spec.frame==state.pose.frame and spec.frame~="abs" then
      state.journal.probe=false
      state.pose.conf,state.pose.frame,state.pose.yAbs="lost","abs",true
      save()
      return false,"old frame"
    end
    if pos.src~="typed" and pos.src~="neighbour" and pos.src~="radio" and pos.src~="gps" then
      state.journal.probe=false save() return false,"invalid anchor"
    end
    local evidence={source=pos.src,reference=spec.reference or ("local:"..now),faces=world}
    if type(evidence.reference)~="string" or #evidence.reference>64 then
      state.journal.probe=false save() return false,"invalid anchor"
    end
    if cfg.client and cfg.client.anchor then
      local ok,why=cfg.client.anchor(pos,evidence)
      if not ok then state.journal.probe=false save() return false,why or "anchor rejected" end
    end
    local previous=A.copy(state.pose)
    state.journal.seq=state.journal.seq+1
    state.journal.last={
      v=1,seq=state.journal.seq,lease=state.journal.lease,at=now,frame=pos.frame,
      kind="anchor",phase="done",from=previous,to=A.copy(pos),
      fuelBefore=false,cell=false,name=false,count=0,
      evidence={boot=state.boot,from={},to={},after=world,localFaces=faces,recovery=false,
        fuelAfter=false,moveCost=false,charging="unknown",regeneration="unknown",
        ok=true,reason=false,item=false,anchor=evidence},
    }
    state.journal.open=nil
    state.journal.committed=state.journal.seq
    state.journal.faces=world
    state.journal.probe=false
    state.pose=pos
    state.cells,state.trail={},{}
    state.action=nil
    save()
    return sync()
  end
  function api.anchor(spec)
    if not gpsFree then return false,"offline positions are off" end
    return acceptAnchor(spec)
  end
  function api.hear(text,player)
    if not gpsFree then return false,"offline positions are off" end
    local id=Pos.parseAnchor(text)
    if id~=os.getComputerID() then return false,"not this turtle" end
    local cell=Pos.playerCell(player)
    if not cell then return false,"no player position" end
    if cell.dim~=state.pose.dim then
      state.pose.conf,state.pose.frame,state.pose.yAbs="lost","abs",true
      save()
    end
    return acceptAnchor({x=cell.x,y=cell.y,z=cell.z,dim=cell.dim,src="typed",frame="abs",yAbs=true,
      reference="player:"..id,h=state.pose.h})
  end
  function api.radio(points)
    if not gpsFree then return false,"offline positions are off" end
    if busy then return false,"navigation busy" end
    local fix=Pos.triangulate(points)
    if not fix then
      state.pose.conf,state.pose.src="suspect","radio"
      ready=false
      save()
      return false,"suspect"
    end
    return acceptAnchor({x=fix.x,y=fix.y,z=fix.z,dim=fix.dim or state.pose.dim,src="radio",frame="abs",yAbs=true,
      reference="radio",h=state.pose.h})
  end
  function api.pose() return A.copy(state.pose) end
  function api.stopped() return stopped end
  function api.stop() stopped=true state.stopped=true state.resume=nil save() end
  function api.resume()
    if busy then return false end
    stopped=false state.stopped=false state.resume=nil save() return true
  end
  function api.controlState() return A.copy(state.control or {}) end
  function api.control(kind,epoch,cid)
    if (kind~="go" and kind~="recall" and kind~="estop") or not integer(epoch) or epoch<1 or epoch>2147483647
      or not integer(cid) or cid<1 or cid>2147483647 then return false,"invalid command" end
    local c=state.control
    if c and (epoch<c.epoch or epoch==c.epoch and cid<=c.cid) then return false,"stale command" end
    state.control={kind=kind,epoch=epoch,cid=cid}
    state.resume=nil
    if kind=="estop" then stopped=true state.stopped=true
    elseif kind=="go" then
      if busy then state.resume=true else stopped=false state.stopped=false end
    end
    save()
    return true
  end
  function api.resumePending()
    if not state.resume or busy or not ready then return false end
    return api.resume()
  end
  function api.record(p,name)
    assert(not busy and S.pose(p) and inside(p,b) and type(name)=="string" and #name<=128,"invalid observation")
    remember(p,name) save()
  end
  local function turn(h)
    while state.pose.h~=h do
      if cancelled() then return false,"cancelled" end
      local from=A.copy(state.pose)
      local delta=(h-from.h)%4==3 and 3 or 1
      local to=A.copy(from) to.h=(from.h+delta)%4
      state.action={kind="turn",from=from,to=to} save() checkpoint("turn-prepared")
      if cancelled() then state.action=nil save() return false,"cancelled" end
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
  local function step(d,policy)
    if gpsFree then
      if state.pose.conf~="certain" then return false,"pose not certain" end
      if state.journal.open or (state.journal.probe and state.journal.probe.phase=="intent") then return false,"unresolved move" end
    else
      local observed,err=observe()
      if not observed or not same(observed,state.pose) then ready=false return false,err or "relocated turtle; calibrate pose" end
    end
    local to=adjacent(state.pose,d)
    if not inside(to,b) then return false,"outside navigation bounds" end
    if policy=="walk" and state.cells[key(to)]~="minecraft:air" then return false,"unknown route" end
    if d<4 then local ok,why=turn(d) if not ok then return false,why end end
    if cancelled() then return false,"cancelled" end
    local from=A.copy(state.pose) to.h=from.h
    if gpsFree then
      to.v,to.frame,to.yAbs,to.conf,to.src,to.anchoredAt=from.v,from.frame,from.yAbs,from.conf,from.src,from.anchoredAt
    end
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
    if gpsFree then
      local fromFaces=probe()
      state.journal.probe=false
      local worldFrom=Pos.rotate(fromFaces,state.pose.h)
      state.journal.faces=worldFrom
      state.journal.seq=state.journal.seq+1
      state.journal.open={
        v=1,seq=state.journal.seq,lease=state.journal.lease,at=os.epoch("utc"),frame=state.pose.frame,
        kind="move",phase="intent",from=A.copy(from),to=A.copy(to),
        fuelBefore=turtle.getFuelLevel(),cell=false,name=false,count=0,
        evidence={
          boot=state.boot,from=worldFrom,to=predict(to,from),after={},localFaces={},
          recovery=false,fuelAfter=false,moveCost=cfg.moveCost or false,
          charging=proof(cfg.charging),regeneration=proof(cfg.regeneration),
          ok=false,reason=false,item=false,anchor=false,
        },
      }
    end
    state.action={kind="move",from=from,to=to} save() checkpoint("move-prepared")
    local moved=false
    local ok,why=cfg.client.move(from,to,function()
      if gpsFree and state.pose.conf~="certain" then return false,"pose not certain" end
      if cancelled() then return false,"cancelled" end
      local allowed,found=permitted()
      if not allowed then return false,found end
      if found then
        local dug,err=dig()
        if not dug then return false,err end
        if cancelled() then return false,"cancelled" end
        if inspect() then return false,"falling block" end
      end
      checkpoint("move-started")
      if cancelled() then return false,"cancelled" end
      local movedNow,err=move()
      checkpoint("move-physical")
      if movedNow then
        moved=true
        if not gpsFree then
          local observed=observe()
          assert(observed and same(observed,to),"physical pose needs GPS reconciliation")
        end
        if cfg.traffic then
          if #state.trail>0 and same(state.trail[#state.trail],to) then table.remove(state.trail)
          else state.trail[#state.trail+1]=A.copy(from) end
          while #state.trail>64 do table.remove(state.trail,1) end
        end
        state.pose=A.copy(to) remember(to,"minecraft:air")
        if gpsFree then state.pose.conf,state.pose.src="certain","reckoned" end
      end
      save() checkpoint("move-observed")
      return movedNow,err
    end)
    if gpsFree and state.journal.open then
      local after=state.journal.faces
      if ok and moved then
        local seen=probe()
        state.journal.probe=false
        after=Pos.rotate(seen,state.pose.h)
        state.journal.faces=after
        if cfg.check then
          local checked,fix=pcall(cfg.check)
          if checked and type(fix)=="table" and type(fix.x)=="number" and type(fix.y)=="number" and type(fix.z)=="number"
            and (fix.x~=state.pose.x or fix.y~=state.pose.y or fix.z~=state.pose.z or type(fix.dim)=="string" and fix.dim~=state.pose.dim) then
            state.pose.conf,state.pose.src="suspect","gps"
            ready=false
          end
        end
      end
      closeMove(ok and moved,nil,after)
    end
    state.action=nil save() checkpoint("move-saved")
    return ok,why
  end
  function api.step(d,policy)
    if not integer(d) or not vectors[d] or policy~="walk" and policy~="explore" and policy~="excavate" then return false,"invalid movement policy" end
    return owned(step,d,policy)
  end
  local function search(goal,policy,avoid,from)
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
    if not S.pose(goal) or not inside(goal,b) or from~=nil and (not S.pose(from) or not inside(from,b)) then return false,"invalid route" end
    return owned(function()
      local route,why=search(goal,"walk",{},from)
      if not route then return false,why end
      return #route
    end)
  end
  local function traffic(target)
    local r,why=cfg.client.call("traffic",{to=target})
    if not r or not r.ok then return false,why or "traffic server unavailable" end
    if not r.peer then (cfg.yield or sleep)(.25) return true end
    if not r.yield then (cfg.yield or sleep)(.25) return true end
    if not r.pose then return false,"traffic pose unavailable" end
    local origin,peer=A.copy(state.pose),r.peer
    local axis={x=target.x-origin.x,y=target.y-origin.y,z=target.z-origin.z}
    local found=false
    for _=1,65 do
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
    for _=1,cfg.trafficWaits or 80 do
      if cancelled() then return false,"cancelled" end
      local p,err=cfg.client.call("traffic",{peer=peer})
      if not p or not p.ok or not p.pose then return false,err or "traffic peer unavailable" end
      if p.pose.dim==origin.dim and distance(p.pose,origin)>1 and distance(p.pose,state.pose)>2 then return true end
      (cfg.yield or sleep)(.25)
    end
    return false,"traffic wait budget"
  end
  function api.go(goal,policy)
    if not S.pose(goal) or not inside(goal,b) or policy~="walk" and policy~="explore" and policy~="excavate" then return false,"invalid route" end
    return owned(function()
      local avoid={}
      for _=1,cfg.traffic and 80 or 5 do
        local route,why=search(goal,policy,avoid)
        if not route then return false,why end
        local complete=true
        for _,d in ipairs(route) do
          local target=adjacent(state.pose,d)
          local ok,err=step(d,policy)
          if not ok then
            if not ready then return false,err end
            if err=="cancelled" or err=="out of fuel" then return false,err end
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
