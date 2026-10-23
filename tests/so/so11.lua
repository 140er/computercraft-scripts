local H = dofile("tests/so/harness.lua")
local S = {}

S.copy = function(v) return assert(load("return " .. H.encode(v), "=copy", "t", {}))() end
S.diff = function(a, b, path)
  path = path or "$"
  if type(a) ~= type(b) then return path .. " type " .. type(a) .. " ~= " .. type(b) end
  if type(a) ~= "table" then
    if a ~= b then return path .. " " .. tostring(a) .. " ~= " .. tostring(b) end
    return
  end
  local keys = {}
  for k in pairs(a) do keys[#keys + 1] = k end
  for k in pairs(b) do if a[k] == nil then keys[#keys + 1] = k end end
  table.sort(keys, function(x,y) return tostring(x) < tostring(y) end)
  for _, k in ipairs(keys) do
    local d = S.diff(a[k], b[k], path .. "." .. tostring(k))
    if d then return d end
  end
end
S.libs = function(m)
  for _, name in ipairs({"x25519","random","blake3","chacha20","config","internal/util",
    "internal/hw","internal/curve25519","internal/fp","internal/edwards25519","internal/packing"}) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path, "rb")) m.files[path] = f:read("*a") f:close()
  end
end
S.run = function(rate)
  local began=os.time()
  local g = { net = H.new({tickRate=rate}), failures = {}, workers = {}, displays = {}, digs = {}, reports = 0,
    leases = 0, recover = {}, resumed = {}, beacons = {}, stale = {}, pictures = {},
    trees = {}, frameAt = {}, expires = {} }
  local n = g.net
  local blocks, removed = {}, {}
  setmetatable(n.world, {
    __index=function(_,key)
      if removed[key] then return nil end
      if blocks[key] then return blocks[key] end
      local y=tonumber(key:match("^[^,]+,([^,]+),"))
      if y and y<63 then return "minecraft:stone" end
    end,
    __newindex=function(_,key,value) blocks[key],removed[key]=value,value==nil end,
  })
  local function record(check, ok, detail)
    if not ok then
      local key = check .. ": " .. detail
      if not g.failures[key] then g.failures[key] = (n.time - (g.start or n.time)) / 1000 end
    end
  end
  g.record = record
  local server = n.machine({id=1,modem=true,directories=true,guardServer=true})
  g.server = server
  server.install({"so-server.lua","so-proto.lua","so-pair.lua","so-store.lua","so-log.lua",
    "so-plan.lua","so-mine-plan.lua","so-lumber-plan.lua","so-mod-ar.lua","so-mod-cells.lua",
    "so-mod-display.lua","so-mod-drops.lua","so-mod-lease.lua","so-mod-lumber.lua",
    "so-mod-mine.lua","so-mod-shop.lua","so-mod-state.lua"})
  S.libs(server)
  server.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld",x=0,y=64,z=0}})
  local function checkCells()
    local cells = g.server.env.SO.mods.cells
    local seen = {}
    for _, who in ipairs({"mine:2","mine:3","lumber:4"}) do
      for _, p in ipairs(cells.list(who, 10000)) do
        local key = p.dim .. ":" .. p.x .. "," .. p.y .. "," .. p.z
        record(1, not seen[key] or seen[key] == who, "duplicate reservation " .. key)
        record(1, cells.owner(p.x,p.y,p.z,p.dim) == who, "owner disagrees " .. key)
        seen[key] = who
      end
    end
  end
  local function observeServer(m)
    local wireSend=m.env.rednet.send
    m.env.rednet.send=function(id,payload,protocol)
      if g.bootAt and protocol=="so" and payload.t=="view.frame" then g.frameAt[id]=n.time end
      return wireSend(id,payload,protocol)
    end
    local function observe(path,result)
      if path=="so-mod-lease.lua" then
        local send=result.send
        result.send=function(id,steps,opts)
          local lid,err=send(id,steps,opts)
          if lid then
            g.leases=g.leases+1
            g.expires[id]=n.time+(opts and opts.ms or 60000)
            if g.bootAt then
              if opts and opts.recover then g.recover[id]=g.recover[id] or (n.time-g.bootAt)/1000
              elseif g.recover[id] and not (#steps==1 and steps[1].op=="inspectDown") then
                g.resumed[id]=g.resumed[id] or (n.time-g.bootAt)/1000
              end
            end
          end
          return lid,err
        end
      end
      return result
    end
    local load=m.env.loadfile
    m.env.loadfile=function(path,mode,env)
      local chunk,err=load(path,mode,env)
      if not chunk then return nil,err end
      return function(...) return observe(path,chunk(...)) end
    end
  end
  observeServer(server)
  server.boot("so-server.lua")
  n.onBoot = observeServer
  local function pair(m, program)
    server.inbox[#server.inbox+1] = table.pack("key",25,false) n.flush()
    local code = assert(server.env.SO.pair.pending())
    if program == "worker.lua" then m.files["so-code"] = code end
    m.boot(program)
    if program == "display.lua" then
      for ch in code:gmatch(".") do m.inbox[#m.inbox+1] = table.pack("char",ch) end
    end
    n.flush()
    assert(server.env.SO.pair.key(m.id), "pair failed " .. m.id .. " " .. tostring(m.error))
    assert(m.alive(), tostring(m.error))
  end
  for id=2,4 do
    local opts = {id=id,modem=true,turtle=true,drops=true,physics=true,actionSeconds=0.4,capacity=1000000,
      x=id==4 and 18 or (id-2)*2,y=64,z=0,facing=id==4 and 1 or 0,fuel=10000}
    local w = n.machine(opts)
    w.install({"worker.lua","so-proto.lua","so-pair.lua","so-store.lua"}) S.libs(w)
    g.workers[id] = w
    local send = w.env.rednet.send
    w.env.rednet.send = function(dest,payload,protocol)
      if protocol == "so" and payload.t == "step.report" then g.reports=g.reports+1 checkCells() end
      if protocol == "so" and payload.t == "beacon" and g.killAt and not g.bootAt then
        g.beacons[id] = (n.time-g.killAt)/1000
      end
      return send(dest,payload,protocol)
    end
    local broadcast=w.env.rednet.broadcast
    w.env.rednet.broadcast=function(payload,protocol)
      if protocol=="so" and payload.t=="beacon" and g.killAt and not g.bootAt then
        g.beacons[id]=(n.time-g.killAt)/1000
      end
      return broadcast(payload,protocol)
    end
    for _, suffix in ipairs({"","Up","Down"}) do
      local fn = w.env.turtle["dig"..suffix]
      w.env.turtle["dig"..suffix] = function()
        local p = w.pos
        local x,y,z = p.x,p.y,p.z
        if suffix=="Up" then y=y+1 elseif suffix=="Down" then y=y-1
        else x=x+({[0]=0,1,0,-1})[w.heading] z=z+({[0]=-1,0,1,0})[w.heading] end
        local key=x..","..y..","..z
        local block=n.world[key]
        record(2, block ~= "minecraft:chest" and (type(block)~="table" or block.name~="minecraft:chest"), "dug chest "..key)
        local ok=fn()
        if ok then
          g.digs[key]=(g.digs[key] or 0)+1
          record(2,g.digs[key]<=1,"cell dug twice "..key)
        end
        return ok
      end
    end
    pair(w,"worker.lua")
  end
  for id=5,6 do
    local d=n.machine({id=id,modem=true,monitor=id==5 and {width=3,height=2} or nil,width=id==5 and 57 or 26,height=id==5 and 26 or 20})
    d.install({"display.lua","so-proto.lua","so-pair.lua","so-store.lua"}) S.libs(d)
    pair(d,"display.lua") g.displays[id]=d
  end
  local room=n.machine({id=7,modem=true})
  room.spawn([[
    rednet.open("back") rednet.host("roomsorter","storage")
    local totals={ ["minecraft:diamond"]=42,["minecraft:iron_ingot"]=128 }
    local timer=os.startTimer(30)
    while true do
      local ev,id,msg,protocol=os.pullEvent()
      if ev=="timer" and id==timer then
        rednet.broadcast({totals=totals,used=170,size=10000,chests=4,furnaces=0,state="ready",full=false},"roomsorter_stock")
        timer=os.startTimer(30)
      elseif ev=="rednet_message" and protocol=="dns" and msg.sType=="lookup" and msg.sProtocol=="roomsorter" then
        rednet.send(id,{sType="lookup response",sProtocol="roomsorter"},"dns")
      elseif ev=="rednet_message" and protocol=="roomsorter" then
        if msg.cmd=="stock" then rednet.send(id,{rid=msg.rid,version=1,totals=totals,state="ready",crafty=false,cutoff=0,recipes={},orders={}},"roomsorter")
        elseif msg.cmd=="order" then rednet.send(id,{"ordered "..msg.n.." "..msg.text,rid=msg.rid},"roomsorter") end
      end
    end
  ]])
  for _, p in ipairs({{0,60,-3},{1,60,-3},{2,60,-6},{3,60,-6}}) do
    n.world[p[1]..","..p[2]..","..p[3]]={name=p[1]%2==0 and "minecraft:iron_ore" or "minecraft:diamond_ore",tags={["c:ores"]=true}}
  end
  n.world["3,60,-7"]={name="example:rich_rock",tags={["c:ores"]=true}}
  n.world["1,60,-5"]={name="minecraft:lava",state={level=0}}
  for x=20,28 do for z=0,8 do n.world[x..",62,"..z]="minecraft:grass_block" end end
  for _, p in ipairs({{21,1},{24,4},{27,7},{21,7}}) do
    g.trees[#g.trees+1]={x=p[1],z=p[2]}
    for y=63,66 do n.world[p[1]..","..y..","..p[2]]={name="minecraft:oak_log",tags={["minecraft:logs"]=true}} end
    for x=p[1]-1,p[1]+1 do for z=p[2]-1,p[2]+1 do
      n.world[x..",67,"..z]={name="minecraft:oak_leaves",tags={["minecraft:leaves"]=true}}
    end end
  end
  g.chests={ore={x=-3,y=63,z=0,inv={}},fuel={x=-4,y=63,z=0,inv={{name="minecraft:coal",count=64}}},
    wood={x=17,y=63,z=0,inv={}},saplings={x=18,y=63,z=0,inv={{name="minecraft:oak_sapling",count=64}}}}
  for kind,c in pairs(g.chests) do
    c.name="minecraft:chest" n.world[c.x..","..c.y..","..c.z]=c
    assert(server.env.SO.mods.drops.add({id=kind,dim=0,x=c.x,y=c.y,z=c.z,side="down",kind=kind=="saplings" and "storage" or kind}))
  end
  n.advance(2)
  local inputSeq=0
  local function input(id, body)
    local d=g.displays[id]
    local proto=d.env.dofile("so-proto.lua")
    local key=server.env.SO.pair.key(id)
    inputSeq=inputSeq+1
    body.x,body.y=1,1
    d.env.rednet.send(1,assert(proto.encode(proto.build(key,"input",body,"so11-"..inputSeq))),"so") n.flush()
  end
  local function role(id,name) input(id,{id="generic"}) input(id,{id=name}) end
  local function text(id,value)
    if value=="start" then n.advance(2) end
    local d=g.displays[id]
    for ch in value:gmatch(".") do d.inbox[#d.inbox+1]=table.pack("char",ch) end
    d.inbox[#d.inbox+1]=table.pack("key",28) n.flush()
  end
  role(5,"mining")
  for _, cmd in ipairs({"home 0 64 0 n","bottom 60","length 24","add 2 0 64 0 n","add 3 2 64 0 n","start"}) do text(5,cmd) end
  role(6,"lumber")
  for _, cmd in ipairs({"area 20 0 28 8 62","saplings 18 63 0 down","add 4 18 64 0 e","start"}) do text(6,cmd) end
  role(5,"shop") role(6,"status")
  g.start=n.time
  local function snapshot()
    local mods=g.server.env.SO.mods
    local view=mods.state.view()
    local machines=S.copy(mods.state.get("machines"))
    for _, row in pairs(machines) do row.seen=nil end
    local cells={}
    for key in pairs(g.digs) do
      local x,y,z=key:match("([^,]+),([^,]+),([^,]+)")
      cells[key]=mods.cells.isDug(tonumber(x),tonumber(y),tonumber(z))
    end
    local reservations={}
    for _, who in ipairs({"mine:2","mine:3","lumber:4"}) do
      for _, p in ipairs(mods.cells.list(who,10000)) do reservations[H.encode(p)]=who end
    end
    local read=g.server.env.SO.store.read
    return S.copy({values=view.values,machines=machines,cells=cells,reservations=reservations,
      drops=mods.drops.list(),roles=read("so-display").value,mine=read("so-data/mine/job").value,
      lumber=read("so-data/lumber/job").value})
  end
  local epoch=server.env.os.epoch
  server.env.os.epoch=function(kind)
    if g.start and n.time-g.start>=360000 and not g.killAt and server.context and not g.cutting then
      g.cutting=true
      g.before=snapshot() g.killAt=n.time g.killExpires=S.copy(g.expires)
      g.killPositions,g.workLeft={},{}
      for id,w in pairs(g.workers) do
        g.killPositions[id]=S.copy(w.pos)
        local job=id==4 and g.before.lumber or g.before.mine
        local row=id~=4 and job.turtles[tostring(id)]
        g.workLeft[id]=job.running and (id==4 and job.phase~="waiting" or id~=4 and row.state~="done")
      end
      print("SO11 power cut in "..server.context.." at "..((n.time-g.start)/1000).."s")
      g.disk=S.copy(server.files)
      n.kill(server)
      error("power cut during "..server.context,0)
    end
    return epoch(kind)
  end
  n.afterResume=function(m)
    if m.id==1 and not m.killed and m.env.SO then checkCells() end
  end
  local function picture(d)
    local rows={}
    local _,height=d.env.term.getSize()
    for y=1,height do rows[y]=d.screen[y] or "" end
    return table.concat(rows,"\n")
  end
  for second=1,720 do
    n.advance(1)
    if second%60==0 then io.stderr:write("SO11 time "..second.."s\n") end
    if second==360 and not g.killAt then record(7,false,"no active server call at minute 6") end
    if g.killAt and not g.bootAt and n.time-g.killAt>=120000 then
      record(5,not S.diff(g.disk,server.files),"disk changed while powered off")
      for id,w in pairs(g.workers) do
        record(3,g.beacons[id]~=nil or g.killExpires[id] and g.killExpires[id]>n.time,"worker "..id.." lost lease without beacon during outage")
        record(3,not S.diff(g.killPositions[id],w.pos),"worker "..id.." moved during outage")
      end
      for id in pairs(g.displays) do record(4,g.stale[id],"display "..id.." never stale during outage") end
      g.bootAt=n.time g.server=n.boot(server)
      n.flush()
      local after=snapshot()
      for _, field in ipairs({"values","machines","cells","reservations","drops","roles","mine","lumber"}) do
        local diff=S.diff(g.before[field],after[field],field)
        record(5,not diff,diff or field)
      end
    end
    for id,w in pairs(g.workers) do record(7,w.alive(),"worker "..id.." error "..tostring(w.error)) end
    if not g.killAt or g.bootAt then record(7,g.server.alive(),"server error "..tostring(g.server.error)) end
    for id,d in pairs(g.displays) do
      record(7,d.alive(),"display "..id.." error "..tostring(d.error))
      local pic=picture(d)
      if g.killAt and not g.bootAt and pic:find("stale",1,true) then g.stale[id]=true end
      if g.bootAt and g.frameAt[id] and not g.pictures[id] and not pic:find("stale",1,true) and #pic>0 then
        g.pictures[id]=(n.time-g.bootAt)/1000
      end
    end
    if g.killAt and not g.bootAt then
      for id,w in pairs(g.workers) do
        record(3,g.beacons[id]~=nil or g.killExpires[id] and g.killExpires[id]>n.time,"worker "..id.." lost lease without beacon during outage")
        record(3,not S.diff(g.killPositions[id],w.pos),"worker "..id.." moved during outage")
      end
    end
    if g.bootAt and n.time-g.bootAt>=5000 then
      for id in pairs(g.workers) do
        record(3,g.recover[id]~=nil and g.recover[id]<=5,"worker "..id.." recovery park within 5s")
      end
    end
    if g.bootAt and n.time-g.bootAt>=60000 then
      for id in pairs(g.workers) do
        record(3,not g.workLeft[id] or g.resumed[id]~=nil and g.resumed[id]<=60,"worker "..id.." unfinished work resumes within 60s")
      end
    end
    if g.bootAt and n.time-g.bootAt>=30000 then
      for id in pairs(g.displays) do
        record(4,g.pictures[id]~=nil and g.pictures[id]<=30,"display "..id.." recovered within 30s")
      end
    end
    for _,line in ipairs(g.server.log) do record(7,not line:find("failed",1,true),line) end
    for _, machine in ipairs({server,g.server}) do
      for _,wait in ipairs(machine.waits or {}) do record(7,false,wait) end
    end
    checkCells()
  end
  record(7,g.killAt~=nil,"server never crashed")
  record(7,g.bootAt~=nil,"server never rebooted")
  for id in pairs(g.workers) do
    record(3,g.recover[id]~=nil and g.recover[id]<=5,"worker "..id.." recovery park within 5s")
    record(3,not g.workLeft or not g.workLeft[id] or g.resumed[id]~=nil and g.resumed[id]<=60,"worker "..id.." unfinished work resumes within 60s")
  end
  for id in pairs(g.displays) do record(4,g.pictures[id]~=nil and g.pictures[id]<=30,"display "..id.." recovered within 30s") end
  record(4,picture(g.displays[5]):find("iron_ingot",1,true)~=nil,"shop stock restored")
  local function total(chest,predicate)
    local count=0 for _,item in ipairs(chest.inv) do if predicate(item.name) then count=count+item.count end end return count
  end
  g.ores=total(g.chests.ore,function(name) return name=="minecraft:diamond" or name=="minecraft:raw_iron" or name=="example:rich_rock" end)
  g.logs=total(g.chests.wood,function(name) return name=="minecraft:oak_log" end)
  g.felled=0
  for _,p in ipairs(g.trees) do
    local ok=n.world[p.x..",63,"..p.z]=="minecraft:oak_sapling"
    for y=63,66 do ok=ok and g.digs[p.x..","..y..","..p.z]==1 end
    if ok then g.felled=g.felled+1 end
  end
  local savedMine=g.server.env.SO.store.read("so-data/mine/job")
  local mine=assert(savedMine,"missing mining job").value
  local lumber=g.server.env.SO.store.read("so-data/lumber/job").value
  for id,row in pairs(mine.turtles) do
    print("SO11 mining "..id.." state="..tostring(row.state).." pose="..H.encode(row.pose).." error="..tostring(row.error))
  end
  print("SO11 lumber phase="..tostring(lumber.phase).." cursor="..tostring(lumber.cursor).." alert="..tostring(lumber.alert).." pose="..H.encode(lumber.turtle.pose))
  record(6,(mine.progress.done or 0)>=1,"mining completed at least one branch")
  record(6,g.digs["0,60,-1"]~=nil,"mining dug shaft to bottom")
  record(6,g.ores>0,"ore delivered to ore chest")
  record(6,g.felled>=2,"at least two trees felled and replanted")
  record(6,g.logs>0,"logs delivered to wood chest")
  local count=0 for _ in pairs(g.digs) do count=count+1 end
  print("SO11 summary dug cells="..count.." ores delivered="..g.ores.." trees felled="..g.felled.." logs="..g.logs.." leases sent="..g.leases.." reports="..g.reports)
  for id=2,4 do
    local work=g.workLeft and not g.workLeft[id] and "idle" or tostring(g.resumed[id]).."s"
    local beacon=g.beacons[id] and tostring(g.beacons[id]).."s" or "held lease"
    print("SO11 worker "..id.." recovery park="..tostring(g.recover[id]).."s work="..work.." beacon="..beacon)
  end
  for id=5,6 do print("SO11 display "..id.." recovery="..tostring(g.pictures[id]).."s") end
  local failures={}
  for message,at in pairs(g.failures) do failures[#failures+1]="check "..message.." at "..at.."s" end
  table.sort(failures)
  for _,message in ipairs(failures) do print("SO11 FAIL "..message) end
  print("SO11 elapsed "..(os.time()-began).." real seconds")
  g.failureList=failures
  return g
end

S.runBusy = function(rate)
  local began=os.time()
  local g = { net = H.new({tickRate=rate}), failures = {}, workers = {}, displays = {}, digs = {}, reports = 0,
    leases = 0, recover = {}, resumed = {}, beacons = {}, stale = {}, pictures = {},
    trees = {}, frameAt = {}, expires = {} }
  g.active, g.cutLeases, g.marks, g.interrupted, g.settled, g.batchDigs, g.outageMoves = {}, {}, {}, {}, {}, {}, {}
  local n = g.net
  local minePlan = dofile("so-mine-plan.lua")
  local plan = dofile("so-plan.lua")
  local blocks, removed = {}, {}
  setmetatable(n.world, {
    __index=function(_,key)
      if removed[key] then return nil end
      if blocks[key] then return blocks[key] end
      local y=tonumber(key:match("^[^,]+,([^,]+),"))
      if y and y<63 then return "minecraft:stone" end
    end,
    __newindex=function(_,key,value) blocks[key],removed[key]=value,value==nil end,
  })
  local function record(check, ok, detail)
    if not ok then
      local key = check .. ": " .. detail
      if not g.failures[key] then g.failures[key] = (n.time - (g.start or n.time)) / 1000 end
    end
  end
  g.record = record
  local server = n.machine({id=1,modem=true,directories=true,guardServer=true})
  g.server = server
  server.install({"so-server.lua","so-proto.lua","so-pair.lua","so-store.lua","so-log.lua",
    "so-plan.lua","so-mine-plan.lua","so-lumber-plan.lua","so-mod-ar.lua","so-mod-cells.lua",
    "so-mod-display.lua","so-mod-drops.lua","so-mod-lease.lua","so-mod-lumber.lua",
    "so-mod-mine.lua","so-mod-shop.lua","so-mod-state.lua"})
  S.libs(server)
  server.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld",x=0,y=64,z=0}})
  local function checkCells()
    local cells = g.server.env.SO.mods.cells
    local seen = {}
    for _, who in ipairs({"mine:2","mine:3","lumber:4"}) do
      for _, p in ipairs(cells.list(who, 10000)) do
        local key = p.dim .. ":" .. p.x .. "," .. p.y .. "," .. p.z
        record(1, not seen[key] or seen[key] == who, "duplicate reservation " .. key)
        record(1, cells.owner(p.x,p.y,p.z,p.dim) == who, "owner disagrees " .. key)
        seen[key] = who
      end
    end
  end
  local function observeServer(m)
    g.server=m
    local wireSend=m.env.rednet.send
    m.env.rednet.send=function(id,payload,protocol)
      if g.bootAt and protocol=="so" and payload.t=="view.frame" then g.frameAt[id]=n.time end
      return wireSend(id,payload,protocol)
    end
    local function observe(path,result)
      if path=="so-mod-cells.lua" then
        local mark=result.markDug
        result.markDug=function(x,y,z,dim)
          local key=x..","..y..","..z
          g.marks[key]=(g.marks[key] or 0)+1
          return mark(x,y,z,dim)
        end
      end
      if path=="so-mod-lease.lua" then
        local onReport=result.onReport
        result.onReport=function(owner,fn)
          return onReport(owner,function(lid,id,results,lease)
            local facts=lease.report
            if g.bootAt and facts then
              local saved=g.server.env.SO.store.read("so-data/"..owner.."/job").value
              local row=id==4 and saved.turtle or saved.turtles[tostring(id)]
              for _,cell in ipairs(facts.dug or {}) do
                local world=plan.toWorld(row.frame,{x=cell.x,y=cell.y,z=cell.z,f=0})
                local key=world.x..","..world.y..","..world.z
                if g.cutDigs and g.cutDigs[key] then g.interrupted[key]=true end
              end
            end
            return fn(lid,id,results,lease)
          end)
        end
        local send=result.send
        result.send=function(id,steps,opts)
          local lid,err=send(id,steps,opts)
          if lid then
            g.leases=g.leases+1
            g.active[id]={id=lid,steps=S.copy(steps),recover=opts and opts.recover,
              park=opts and opts.ms==600000 and #steps==1 and steps[1].op=="inspectDown"}
            g.batchDigs[id]={}

            g.expires[id]=n.time+(opts and opts.ms or 60000)
            if g.bootAt then
              if opts and opts.recover then g.recover[id]=g.recover[id] or (n.time-g.bootAt)/1000
              end
            end
          end
          if lid and g.start and not g.bootAt then m.env.os.epoch("utc") end
          return lid,err
        end
      end
      return result
    end
    local load=m.env.loadfile
    m.env.loadfile=function(path,mode,env)
      local chunk,err=load(path,mode,env)
      if not chunk then return nil,err end
      return function(...) return observe(path,chunk(...)) end
    end
  end
  observeServer(server)
  server.boot("so-server.lua")
  n.onBoot = observeServer
  local function pair(m, program)
    server.inbox[#server.inbox+1] = table.pack("key",25,false) n.flush()
    local code = assert(server.env.SO.pair.pending())
    if program == "worker.lua" then m.files["so-code"] = code end
    m.boot(program)
    if program == "display.lua" then
      for ch in code:gmatch(".") do m.inbox[#m.inbox+1] = table.pack("char",ch) end
    end
    n.flush()
    assert(server.env.SO.pair.key(m.id), "pair failed " .. m.id .. " " .. tostring(m.error))
    assert(m.alive(), tostring(m.error))
  end
  for id=2,4 do
    local opts = {id=id,modem=true,turtle=true,drops=true,physics=true,actionSeconds=0.4,capacity=1000000,
      x=id==4 and 18 or (id-2)*2,y=64,z=0,facing=id==4 and 1 or 0,fuel=10000}
    local w = n.machine(opts)
    w.install({"worker.lua","so-proto.lua","so-pair.lua","so-store.lua"}) S.libs(w)
    g.workers[id] = w
    local send = w.env.rednet.send
    w.env.rednet.send = function(dest,payload,protocol)
      if protocol == "so" and payload.t == "step.report" then
        g.reports=g.reports+1 checkCells()
        local active=g.active[id]
        if g.bootAt and active and payload.body.lease==active.id and not active.park and not active.recover then
          g.resumed[id]=g.resumed[id] or (n.time-g.bootAt)/1000
        end
        if g.killAt and not g.bootAt then
          g.settled[id]=S.copy(w.pos) g.settled[id].facing=w.heading
          g.outageMoves[id]=S.copy(w.env.dofile("so-store.lua").read("so-journal").value.moves)
        end
      end
      if protocol == "so" and payload.t == "beacon" and g.killAt and not g.bootAt then
        g.beacons[id] = (n.time-g.killAt)/1000
      end
      return send(dest,payload,protocol)
    end
    local broadcast=w.env.rednet.broadcast
    w.env.rednet.broadcast=function(payload,protocol)
      if protocol=="so" and payload.t=="beacon" and g.killAt and not g.bootAt then
        g.beacons[id]=(n.time-g.killAt)/1000
      end
      return broadcast(payload,protocol)
    end
    for _, suffix in ipairs({"","Up","Down"}) do
      local fn = w.env.turtle["dig"..suffix]
      w.env.turtle["dig"..suffix] = function()
        local p = w.pos
        local x,y,z = p.x,p.y,p.z
        if suffix=="Up" then y=y+1 elseif suffix=="Down" then y=y-1
        else x=x+({[0]=0,1,0,-1})[w.heading] z=z+({[0]=-1,0,1,0})[w.heading] end
        local key=x..","..y..","..z
        local block=n.world[key]
        record(2, block ~= "minecraft:chest" and (type(block)~="table" or block.name~="minecraft:chest"), "dug chest "..key)
        local ok=fn()
        if ok then
          g.digs[key]=(g.digs[key] or 0)+1
          if g.batchDigs[id] then g.batchDigs[id][key]=true end
          if g.killAt and not g.bootAt then g.cutDigs[key]=true end
          record(2,g.digs[key]<=1,"cell dug twice "..key)
        end
        return ok
      end
    end
    pair(w,"worker.lua")
  end
  for id=5,6 do
    local d=n.machine({id=id,modem=true,monitor=id==5 and {width=3,height=2} or nil,width=id==5 and 57 or 26,height=id==5 and 26 or 20})
    d.install({"display.lua","so-proto.lua","so-pair.lua","so-store.lua"}) S.libs(d)
    pair(d,"display.lua") g.displays[id]=d
  end
  local room=n.machine({id=7,modem=true})
  room.spawn([[
    rednet.open("back") rednet.host("roomsorter","storage")
    local totals={ ["minecraft:diamond"]=42,["minecraft:iron_ingot"]=128 }
    local timer=os.startTimer(30)
    while true do
      local ev,id,msg,protocol=os.pullEvent()
      if ev=="timer" and id==timer then
        rednet.broadcast({totals=totals,used=170,size=10000,chests=4,furnaces=0,state="ready",full=false},"roomsorter_stock")
        timer=os.startTimer(30)
      elseif ev=="rednet_message" and protocol=="dns" and msg.sType=="lookup" and msg.sProtocol=="roomsorter" then
        rednet.send(id,{sType="lookup response",sProtocol="roomsorter"},"dns")
      elseif ev=="rednet_message" and protocol=="roomsorter" then
        if msg.cmd=="stock" then rednet.send(id,{rid=msg.rid,version=1,totals=totals,state="ready",crafty=false,cutoff=0,recipes={},orders={}},"roomsorter")
        elseif msg.cmd=="order" then rednet.send(id,{"ordered "..msg.n.." "..msg.text,rid=msg.rid},"roomsorter") end
      end
    end
  ]])
  for _, p in ipairs({{0,60,-3},{1,60,-3},{2,60,-6},{3,60,-6}}) do
    n.world[p[1]..","..p[2]..","..p[3]]={name=p[1]%2==0 and "minecraft:iron_ore" or "minecraft:diamond_ore",tags={["c:ores"]=true}}
  end
  n.world["3,60,-7"]={name="example:rich_rock",tags={["c:ores"]=true}}
  n.world["1,60,-5"]={name="minecraft:lava",state={level=0}}
  for x=20,28 do for z=0,8 do n.world[x..",62,"..z]="minecraft:grass_block" end end
  for _, p in ipairs({{21,1},{24,4},{27,7},{21,7}}) do
    g.trees[#g.trees+1]={x=p[1],z=p[2]}
    for y=63,66 do n.world[p[1]..","..y..","..p[2]]={name="minecraft:oak_log",tags={["minecraft:logs"]=true}} end
    for x=p[1]-1,p[1]+1 do for z=p[2]-1,p[2]+1 do
      n.world[x..",67,"..z]={name="minecraft:oak_leaves",tags={["minecraft:leaves"]=true}}
    end end
  end
  g.chests={ore={x=-3,y=63,z=0,inv={}},fuel={x=-4,y=63,z=0,inv={{name="minecraft:coal",count=64}}},
    wood={x=17,y=63,z=0,inv={}},saplings={x=18,y=63,z=0,inv={{name="minecraft:oak_sapling",count=64}}}}
  for kind,c in pairs(g.chests) do
    c.name="minecraft:chest" n.world[c.x..","..c.y..","..c.z]=c
    assert(server.env.SO.mods.drops.add({id=kind,dim=0,x=c.x,y=c.y,z=c.z,side="down",kind=kind=="saplings" and "storage" or kind}))
  end
  n.advance(2)
  local inputSeq=0
  local function input(id, body)
    local d=g.displays[id]
    local proto=d.env.dofile("so-proto.lua")
    local key=server.env.SO.pair.key(id)
    inputSeq=inputSeq+1
    body.x,body.y=1,1
    d.env.rednet.send(1,assert(proto.encode(proto.build(key,"input",body,"so11-"..inputSeq))),"so") n.flush()
  end
  local function role(id,name) input(id,{id="generic"}) input(id,{id=name}) end
  local function text(id,value)
    if value=="start" then n.advance(2) end
    local d=g.displays[id]
    for ch in value:gmatch(".") do d.inbox[#d.inbox+1]=table.pack("char",ch) end
    d.inbox[#d.inbox+1]=table.pack("key",28) n.flush()
  end
  role(5,"mining")
  for _, cmd in ipairs({"home 0 64 0 n","bottom 60","length 48","add 2 0 64 0 n","add 3 2 64 0 n","start"}) do text(5,cmd) end
  role(5,"shop") role(6,"status")
  g.start=n.time
  local function snapshot()
    local mods=g.server.env.SO.mods
    local view=mods.state.view()
    local machines=S.copy(mods.state.get("machines"))
    for _, row in pairs(machines) do row.seen=nil end
    local cells={}
    for key in pairs(g.digs) do
      local x,y,z=key:match("([^,]+),([^,]+),([^,]+)")
      cells[key]=mods.cells.isDug(tonumber(x),tonumber(y),tonumber(z))
    end
    local reservations={}
    for _, who in ipairs({"mine:2","mine:3","lumber:4"}) do
      for _, p in ipairs(mods.cells.list(who,10000)) do reservations[H.encode(p)]=who end
    end
    local read=g.server.env.SO.store.read
    return S.copy({values=view.values,machines=machines,cells=cells,reservations=reservations,
      drops=mods.drops.list(),roles=read("so-display").value,mine=read("so-data/mine/job").value,
      lumber=read("so-data/lumber/job").value})
  end
  local epoch=server.env.os.epoch
  server.env.os.epoch=function(kind)
    if g.start and n.time-g.start>240000 and not g.killAt and server.context and not g.cutting then
      local busy,digging=true,false
      for id=2,4 do
        local lease=g.active[id]
        local open=server.env.SO.mods.lease.status(id).open
        if not lease or open~=lease.id or lease.recover
          or lease.park then busy=false end
        if lease then
          for _,step in ipairs(lease.steps) do if step.op:match("^dig") then digging=true end end
        end
        if next(g.batchDigs[id] or {}) then digging=true end
      end
      if not busy or not digging then return epoch(kind) end
      g.cutting=true
      g.before=snapshot() g.killAt=n.time g.killExpires=S.copy(g.expires)
      g.killPositions,g.workLeft={},{}
      g.cutDigs={}
      for id=2,4 do
        for key in pairs(g.batchDigs[id] or {}) do g.cutDigs[key]=true end
      end
      for id,w in pairs(g.workers) do
        g.killPositions[id]=S.copy(w.pos)
        local job=id==4 and g.before.lumber or g.before.mine
        local row=id~=4 and job.turtles[tostring(id)]
        g.workLeft[id]=job.running and (id==4 and job.phase~="waiting" or id~=4 and row.state~="done")
      end
      local ready=0
      for _,tree in ipairs(g.trees) do
        local block=n.world[tree.x..",63,"..tree.z]
        if type(block)=="table" and block.name=="minecraft:oak_log" then ready=ready+1 end
      end
      record(6,ready>0,"grown trees ready to fell at cut")
      for id=2,4 do
        g.cutLeases[id]=S.copy(g.active[id])
        record(3,g.workLeft[id]==true,"worker "..id.." must have unfinished work at cut")
        print("SO11 B cut worker "..id.." lease="..H.encode(g.cutLeases[id]))
      end
      print("SO11 B power cut in "..server.context.." at "..((n.time-g.start)/1000).."s")
      g.disk=S.copy(server.files)
      n.kill(server)
      error("power cut during "..server.context,0)
    end
    return epoch(kind)
  end
  n.afterResume=function(m)
    if m.id==1 and not m.killed and m.env.SO then checkCells() end
    if g.killAt and not g.bootAt and g.settled[m.id] then
      local previous=g.settled[m.id]
      local current={x=m.pos.x,y=m.pos.y,z=m.pos.z,facing=m.heading}
      if S.diff(previous,current) then
        local moves=g.outageMoves[m.id]
        local entry=moves[#moves]
        local reverse={forward="back",back="forward",up="down",down="up",turnLeft="turnRight",turnRight="turnLeft"}
        record(3,n.time>=g.killExpires[m.id]+60000,"worker "..m.id.." moved before backup window")
        local expected=entry and plan.apply(previous,reverse[entry.op])
        record(3,expected and not S.diff(expected,current),"worker "..m.id.." only reverses journal moves during outage")
        table.remove(moves)
        g.settled[m.id]=current
      end
    end
    if g.start then
      local saved=g.killAt and not g.bootAt and g.before.mine or g.server.env.SO.store.read("so-data/mine/job").value
      local inside={}
      for id=2,3 do
        if minePlan.inLane(saved,g.workers[id].pos) then inside[#inside+1]=id end
      end
      record(1,#inside<=1,"two miners physically inside shaft lane")
    end
  end
  local function picture(d)
    local rows={}
    local _,height=d.env.term.getSize()
    for y=1,height do rows[y]=d.screen[y] or "" end
    return table.concat(rows,"\n")
  end
  for second=1,960 do
    if second==222 then
      role(6,"lumber")
      for _,cmd in ipairs({"area 20 0 28 8 62","saplings 18 63 0 down","add 4 18 64 0 e","start"}) do text(6,cmd) end
      role(6,"status")
    end
    local seconds=1
    if g.killAt and not g.bootAt then seconds=math.min(seconds,(g.killAt+120000-n.time)/1000) end
    if g.bootAt then seconds=math.min(seconds,(g.bootAt+240000-n.time)/1000) end
    n.advance(seconds)
    if second%60==0 then
      local read=g.server.env.SO.store.read
      local mine=g.killAt and not g.bootAt and g.before.mine or read("so-data/mine/job").value
      local stored=not (g.killAt and not g.bootAt) and read("so-data/lumber/job")
      local lumber=g.killAt and not g.bootAt and g.before.lumber or stored and stored.value or {}
      io.stderr:write("SO11 B time "..second.."s mine="..tostring(mine.turtles["2"].state)..","..tostring(mine.turtles["3"].state).." lumber="..tostring(lumber.phase).."\n")
    end

    if g.killAt and not g.bootAt and n.time-g.killAt>=120000 then
      record(5,not S.diff(g.disk,server.files),"disk changed while powered off")
      for id,w in pairs(g.workers) do
        record(3,g.beacons[id]~=nil or g.killExpires[id] and g.killExpires[id]>n.time,"worker "..id.." lost lease without beacon during outage")
        record(3,g.settled[id]~=nil,"worker "..id.." completed cut batch before reboot")
      end
      for id in pairs(g.displays) do record(4,g.stale[id],"display "..id.." never stale during outage") end
      g.bootAt=n.time g.server=n.boot(server)
      n.flush()
      local after=snapshot()
      for _, field in ipairs({"values","machines","cells","reservations","drops","roles","mine","lumber"}) do
        local diff=S.diff(g.before[field],after[field],field)
        record(5,not diff,diff or field)
      end
    end
    for id,w in pairs(g.workers) do record(7,w.alive(),"worker "..id.." error "..tostring(w.error)) end
    if not g.killAt or g.bootAt then record(7,g.server.alive(),"server error "..tostring(g.server.error)) end
    for id,d in pairs(g.displays) do
      record(7,d.alive(),"display "..id.." error "..tostring(d.error))
      local pic=picture(d)
      if g.killAt and not g.bootAt and pic:find("stale",1,true) then g.stale[id]=true end
      if g.bootAt and g.frameAt[id] and not g.pictures[id] and not pic:find("stale",1,true) and #pic>0 then
        g.pictures[id]=(n.time-g.bootAt)/1000
      end
    end
    if g.killAt and not g.bootAt then
      for id,w in pairs(g.workers) do
        record(3,g.beacons[id]~=nil or g.killExpires[id] and g.killExpires[id]>n.time,"worker "..id.." lost lease without beacon during outage")
      end
    end
    if g.bootAt and n.time-g.bootAt>=5000 then
      for id in pairs(g.workers) do
        record(3,g.recover[id]~=nil and g.recover[id]<=5,"worker "..id.." recovery park within 5s")
      end
    end
    if g.bootAt and n.time-g.bootAt>=60000 then
      for id in pairs(g.workers) do
        record(3,not g.workLeft[id] or g.resumed[id]~=nil and g.resumed[id]<=60,"worker "..id.." unfinished work resumes within 60s")
      end
    end
    if g.bootAt and n.time-g.bootAt>=30000 then
      for id in pairs(g.displays) do
        record(4,g.pictures[id]~=nil and g.pictures[id]<=30,"display "..id.." recovered within 30s")
      end
    end
    for _,line in ipairs(g.server.log) do record(7,not line:find("failed",1,true),line) end
    for _, machine in ipairs({server,g.server}) do
      for _,wait in ipairs(machine.waits or {}) do record(7,false,wait) end
    end
    checkCells()
    if g.bootAt and n.time-g.bootAt>=240000 then break end
  end
  record(7,g.killAt~=nil,"server never crashed")
  record(7,g.bootAt~=nil,"server never rebooted")
  for id in pairs(g.workers) do
    record(3,g.recover[id]~=nil and g.recover[id]<=5,"worker "..id.." recovery park within 5s")
    record(3,type(g.resumed[id])=="number" and g.resumed[id]<=60,"worker "..id.." unfinished work resumes within 60s")
  end
  for id in pairs(g.displays) do record(4,g.pictures[id]~=nil and g.pictures[id]<=30,"display "..id.." recovered within 30s") end
  record(4,picture(g.displays[5]):find("iron_ingot",1,true)~=nil,"shop stock restored")
  local function total(chest,predicate)
    local count=0 for _,item in ipairs(chest.inv) do if predicate(item.name) then count=count+item.count end end return count
  end
  g.ores=total(g.chests.ore,function(name) return name=="minecraft:diamond" or name=="minecraft:raw_iron" or name=="example:rich_rock" end)
  g.logs=total(g.chests.wood,function(name) return name=="minecraft:oak_log" end)
  g.felled=0
  for _,p in ipairs(g.trees) do
    local ok=n.world[p.x..",63,"..p.z]=="minecraft:oak_sapling"
    for y=63,66 do ok=ok and g.digs[p.x..","..y..","..p.z]==1 end
    if ok then g.felled=g.felled+1 end
  end
  local savedMine=g.server.env.SO.store.read("so-data/mine/job")
  local mine=assert(savedMine,"missing mining job").value
  local lumber=g.server.env.SO.store.read("so-data/lumber/job").value
  for id,row in pairs(mine.turtles) do
    print("SO11 B mining "..id.." state="..tostring(row.state).." pose="..H.encode(row.pose).." error="..tostring(row.error))
  end
  print("SO11 B lumber phase="..tostring(lumber.phase).." cursor="..tostring(lumber.cursor).." alert="..tostring(lumber.alert).." pose="..H.encode(lumber.turtle.pose))
  record(6,(mine.progress.done or 0)>=1,"mining completed at least one branch")
  record(6,g.digs["0,60,-1"]~=nil,"mining dug shaft to bottom")
  record(6,g.ores>0,"ore delivered to ore chest")
  record(6,g.felled>=2,"at least two trees felled and replanted")
  record(6,g.logs>0,"logs delivered to wood chest")
  local count=0 for _ in pairs(g.digs) do count=count+1 end
  print("SO11 B summary dug cells="..count.." ores delivered="..g.ores.." trees felled="..g.felled.." logs="..g.logs.." leases sent="..g.leases.." reports="..g.reports)
  for id=2,4 do
    local work=tostring(g.resumed[id]).."s"
    local beacon=g.beacons[id] and tostring(g.beacons[id]).."s" or "held lease"
    print("SO11 B worker "..id.." recovery park="..tostring(g.recover[id]).."s work="..work.." beacon="..beacon)
  end
  for id=5,6 do print("SO11 B display "..id.." recovery="..tostring(g.pictures[id]).."s") end
  local interrupted=0
  for key in pairs(g.interrupted) do
    interrupted=interrupted+1
    record(2,g.marks[key]==1,"interrupted report cell marked exactly once "..key)
    record(2,g.digs[key]==1,"interrupted report cell never dug again "..key)
  end
  record(2,interrupted>0,"interrupted batches must report dug cells after reboot")
  print("SO11 B interrupted report cells="..interrupted)
  local failures={}
  for message,at in pairs(g.failures) do failures[#failures+1]="check "..message.." at "..at.."s" end
  table.sort(failures)
  for _,message in ipairs(failures) do print("SO11 B FAIL "..message) end
  print("SO11 B elapsed "..(os.time()-began).." real seconds")
  g.failureList=failures
  return g
end

S.defaultOres = function()
  local n=H.new()
  local m=n.machine({id=1,modem=true})
  m.install({"so-server.lua","so-proto.lua","so-pair.lua","so-store.lua","so-plan.lua",
    "so-mine-plan.lua","so-mod-mine.lua","so-mod-display.lua","so-mod-lease.lua"})
  S.libs(m)
  m.boot("so-server.lua")
  local input
  local register=m.env.SO.mods.display.screen
  m.env.SO.mods.display.screen=function(role,render,fn)
    if role=="mining" then input=fn end
    return register(role,render,fn)
  end
  n.advance(1)
  assert(input,"mining screen missing")
  input({text="home 0 64 0 n"})
  return m.env.SO.store.read("so-data/mine/job").value.ores
end

S.recoveryRetry = function()
  local n=H.new()
  local m=n.machine({id=1,modem=true})
  m.install({"so-mod-lease.lua","so-proto.lua"})
  m.env.SO={ now = function() return m.env.os.epoch("utc") end,mods={},store={read=function() end,copy=S.copy},pair={key=function() return string.rep("ab",32) end}}
  m.env.SO.proto=m.env.dofile("so-proto.lua")
  local lease=m.env.dofile("so-mod-lease.lua")
  local id=assert(lease.send(2,{{op="inspectDown"}},{recover=true}))
  n.advance(1) lease.tick(n.time)
  assert(#m.sent==2,"unreported recovery park must be retried")
  assert(m.sent[1].payload.body.lease==m.sent[2].payload.body.lease,"retry must retain lease id")
  assert(m.sent[1].payload.rid~=m.sent[2].payload.rid,"retry must pass replay checks")
  lease.handlers["step.report"]({from=2,body={lease=id,results={{ok=true}},pose={x=0,y=0,z=0,f=0}}})
  n.advance(1) lease.tick(n.time)
  assert(#m.sent==2,"reported recovery park must stop retrying")
  assert(lease.send(2,{{op="inspectDown"}}))
  n.advance(1) lease.tick(n.time)
  assert(#m.sent==4,"unreported ordinary park must be retried")
end

S.lumberDug = function()
  local n=H.new()
  local m=n.machine({id=1,modem=true})
  m.install({"so-mod-lumber.lua","so-store.lua","so-plan.lua","so-lumber-plan.lua"})
  local marks,callback={},nil
  local store=m.env.dofile("so-store.lua")
  local plan=m.env.dofile("so-plan.lua")
  local world={dim="minecraft:overworld",x=20,y=64,z=1,facing=1}
  local pose={x=0,y=0,z=0,f=0}
  assert(store.store("so-data/lumber/job",function() return true end).save({
    dim=world.dim,spots={},running=false,phase="climb",turtle={id=4,pose=world,frame=plan.frame(world,pose)},
  }))
  m.env.SO={ now = function() return m.env.os.epoch("utc") end,store=store,mods={lease={
    status=function() return {} end,
    onReport=function(_,fn) callback=fn end,
    send=function() return "recovery" end,
  },cells={
    reserveMany=function() return true end,
    releaseOwner=function() end,
    isDug=function(x,y,z) return marks[x..","..y..","..z]~=nil end,
    markDug=function(x,y,z)
      local key=x..","..y..","..z
      marks[key]=(marks[key] or 0)+1
    end,
  }}}
  local lumber=m.env.dofile("so-mod-lumber.lua")
  lumber.tick(n.time)
  callback("recovery",4,{{ok=true}},{report={pose=pose,dug={{x=0,y=1,z=0},{x=0,y=1,z=0}}}})
  assert(marks["20,65,1"]==1,"lumber recovery must mark journal digs once in world coordinates")
end

local function suite(test, equal, _, _, rate)
  test("SO11 harness reboots with the same disk and id and drops outage messages",function()
    local n=H.new()
    local m=n.machine({id=1,modem=true})
    m.files["program.lua"]="starts=(starts or 0)+1; while true do os.pullEvent() end"
    m.files["durable"]="kept"
    m.boot("program.lua")
    local disk,env=m.files,m.env
    n.kill(m)
    local sender=n.machine({id=2,modem=true})
    sender.env.rednet.send(1,"lost","test")
    sender.env.rednet.broadcast("also lost","test")
    n.advance(120)
    equal(#m.inbox,0)
    local reboot=n.boot(m)
    equal(reboot.id,1)
    assert(reboot.files==disk and reboot.env~=env and reboot.alive())
    equal(reboot.files.durable,"kept")
    equal(reboot.env.starts,1)
    equal(#reboot.inbox,0)
  end)
  test("SO11 new mining jobs accept every ore by default",function() equal(S.defaultOres(),{}) end)
  local g
  for check=1,7 do
    test("SO11 integration check "..check,function()
      g = g or S.run(rate)
      local failures={}
      for _,message in ipairs(g.failureList) do if message:match("^check "..check..":") then failures[#failures+1]=message end end
      assert(#failures==0,table.concat(failures,"\n"))
    end)
  end
  test("SO11 B retries an unreported recovery park with a fresh envelope",S.recoveryRetry)
  test("SO11 B lumber recovery marks journal digs exactly once",S.lumberDug)
  local busy
  for check=1,7 do
    test("SO11 B integration check "..check,function()
      busy = busy or S.runBusy(rate)
      local failures={}
      for _,message in ipairs(busy.failureList) do
        if message:match("^check "..check..":") then failures[#failures+1]=message end
      end
      assert(#failures==0,table.concat(failures,"\n"))
    end)
  end
end
if arg and arg[0] == "tests/so/so11.lua" then
  local failed=0
  suite(function(name,fn)
    local ok,err=pcall(fn) print((ok and "PASS " or "FAIL ")..name)
    if not ok then failed=failed+1 print(err) end
  end,function(a,b) local diff=S.diff(a,b) assert(not diff,diff) end)
  print("SO11 "..failed.." checks failed")
  os.exit(failed>0 and 1 or 0)
end
return suite
