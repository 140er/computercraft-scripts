local F = dofile("so-flags.lua")
-- Server-owned shop screen for the existing Storage Room turtle.
local S = {
  turtle = nil,
  lookupAt = nil,
  stockAt = nil,
  sampleAt = nil,
  rid = 0,
  pending = {},
  totals = {},
  history = {},
  state = "waiting for stock",
  views = {},
  heardAt = nil,
  selectedAt = nil,
  staleAfter = 300000,
  orders = {},
  latestOrder = nil,
  registered = false,
  -- Learned from roomsorter stock replies (additive fields; older rooms send none).
  labels = {},
  stacks = {},
  tags = {},
  recipes = {},
  -- Recent orders per item, newest first, and cached categories.
  recent = {},
  kinds = {},
}

local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end

-- Amsterdam time of the newest stock plus the elapsed server time since.
S.wall = function()
  if not U or not S.heardDate then return "--:--" end
  return U.clock(S.heardDate + SO.now() - S.heardAt).hm
end

S.request = function(kind, name, count, view, reservedRid)
  if not S.turtle then
    if view then view.order = "Order: failed, storage room not found" end
    return nil, "storage room missing"
  end
  local entry
  if kind == "order" and not reservedRid then
    local why
    entry, why = S.ordinaryOutput()
    if why then
      if view then view.order,view.orderDetail="Order: failed",why end
      return nil, why
    end
  end
  local rid, why = reservedRid, nil
  if not rid then rid, why = S.allocate(kind~="stock") end
  if not rid then return nil, why end
  if entry then
    entry.requestRid, entry.state, entry.sentAt = rid, "ordering", SO.now()
    if not S.outputSave() then return nil, "output save failed" end
  end
  local pending = { kind = kind, sender = S.turtle, at = SO.now(), view = view }
  S.pending[rid] = pending
  if kind == "order" then
    S.latestOrder = rid
    S.orders = { "sent " .. tostring(count) .. " " .. name }
    -- Only orders from a shop display are listed under the item; shop.order leaves displays alone.
    local list = view and (S.recent[name] or {})
    if list then
      S.recent[name] = list
      pending.entry = { hm = S.wall(), n = count, status = "sent" }
      table.insert(list, 1, pending.entry)
      if #list > 8 then table.remove(list) end
    end
    if view then
      view.order, view.orderDetail, view.orderRid = "Order: sent " .. count, nil, rid
    end
  end
  local ok = rednet.send(S.turtle, { cmd = kind, text = name, n = count, rid = rid,
    outputToken=entry and entry.token }, "roomsorter")
  if ok == false then
    S.pending[rid] = nil
    if kind == "order" then
      S.orders = { "failed: send failed" }
      if pending.entry then pending.entry.status = "failed" end
      if view then view.order, view.orderDetail = "Order: failed", "send failed" end
    end
    return nil, "send failed"
  end
  return rid
end

S.fuelPointOk = function(point)
  if type(point) ~= "table" or type(point.id) ~= "string" then return false end
  if point.dim ~= 0 and point.dim ~= -1 and point.dim ~= 1
      and point.dim ~= "minecraft:overworld" and point.dim ~= "minecraft:the_nether" and point.dim ~= "minecraft:the_end" then return false end
  for _, key in ipairs({"x","y","z"}) do
    local n = point[key]
    if type(n) ~= "number" or n ~= n or math.abs(n) == math.huge or n % 1 ~= 0 then return false end
  end
  return point.side == "front" or point.side == "down"
end
S.fuelBox = SO.store and SO.store.store and SO.store.store("so-data/fuel-policy", function(v)
  if type(v) ~= "table" or type(v.auto) ~= "boolean" or type(v.cooldowns) ~= "table" then return false end
  if v.output ~= nil and not S.fuelPointOk(v.output) then return false end
  if v.waiting ~= nil and (type(v.waiting) ~= "table" or not S.fuelPointOk(v.waiting.point)
      or type(v.waiting.at) ~= "number" or v.waiting.at ~= v.waiting.at or v.waiting.at < 0 or v.waiting.at == math.huge) then return false end
  if v.alert ~= nil and (type(v.alert) ~= "table" or type(v.alert.reason) ~= "string" or type(v.alert.text) ~= "string") then return false end
  if v.serial ~= nil and (type(v.serial) ~= "number" or v.serial ~= v.serial or v.serial < 0
      or v.serial >= 2^53 or v.serial % 1 ~= 0) then return false end
  if v.waiting and (type(v.waiting.rid) ~= "number" or v.waiting.rid ~= v.serial
      or type(v.waiting.sender) ~= "number" or v.waiting.sender < 0 or v.waiting.sender % 1 ~= 0) then return false end
  local n = 0
  for key, at in pairs(v.cooldowns) do
    n = n + 1
    if type(key) ~= "string" or type(at) ~= "number" or at ~= at or at < 0 or at == math.huge then return false end
  end
  return n <= 64
end) or {save=function() return false,"store unavailable" end}
S.fuel = S.fuelBox.value or {auto=false,cooldowns={}}
S.rid = S.fuel.serial or 0
S.fuelKey = function(point)
  if not point then return end
  local dim = ({["minecraft:overworld"]=0,["minecraft:the_nether"]=-1,["minecraft:the_end"]=1})[point.dim] or point.dim
  return table.concat({tostring(dim),tostring(point.x),tostring(point.y),tostring(point.z)}, "/")
end
S.fuelSave = function(nextPolicy)
  local hadAlert = S.fuel.alert ~= nil
  local ok, err = S.fuelBox.save(nextPolicy)
  if ok then S.fuel, S.fuelSaveError = nextPolicy, nil
  else S.fuelSaveError = "fuel policy save failed: " .. tostring(err) end
  if ok and hadAlert and not nextPolicy.alert then
    local state = SO.mods.state
    if state and state.emit then state.emit("shop.alert",false) end
  end
  return ok, err
end
S.fuelAlert = function(reason, point, failed)
  reason = tostring(reason):sub(1,160)
  local text = "Fuel " .. reason .. " #" .. tostring(point and point.id or "output"):sub(1,64)
  if S.fuel.alert and S.fuel.alert.text == text and not (failed and S.fuel.waiting) then return end
  local nextPolicy = SO.store.copy(S.fuel)
  nextPolicy.alert = {reason=reason,text=text,point=point}
  local waiting = S.fuel.waiting
  if failed then nextPolicy.waiting = nil end
  if not S.fuelSave(nextPolicy) then return false end
  if failed and waiting then S.pending[waiting.rid] = nil end
  local state = SO.mods.state
  if state and state.emit then state.emit("shop.alert", nextPolicy.alert) end
  return true
end
S.fuelConfig = function(auto, output)
  if auto == nil and output == nil then return SO.store.copy(S.fuel) end
  local nextPolicy = SO.store.copy(S.fuel)
  if auto ~= nil then nextPolicy.auto = auto == true end
  if output ~= nil then
    local drops = SO.mods.drops
    local picked
    for _, p in ipairs(drops and drops.list and drops.list() or {}) do
      if p.id == output and p.kind == "fuel" and not p.broken then picked = p break end
    end
    if not picked then return false, "fuel output point missing or broken" end
    nextPolicy.output = picked
  end
  if not nextPolicy.waiting then nextPolicy.alert = nil end
  return S.fuelSave(nextPolicy)
end
S.fuelClear = function()
  local waiting = S.fuel.waiting
  if not waiting and not S.fuel.alert then return true end
  local nextPolicy = SO.store.copy(S.fuel)
  nextPolicy.waiting, nextPolicy.alert = nil, nil
  local ok, err = S.fuelSave(nextPolicy)
  if ok and waiting then S.pending[waiting.rid] = nil end
  return ok, err
end
S.fuelAvailable = function(point, orderRid)
  local row=S.output and S.output.outputs[S.fuelKey(point)]
  if row and row.kind=="fuel" and S.integer(orderRid,1,2^53-2) and row.requestRid==orderRid and row.state~="released" then
    if not S.outputReconciled(row.ownerId) then return false end
  end
  local waiting = S.fuel.waiting
  if orderRid ~= nil and (waiting and waiting.rid ~= orderRid or not waiting and orderRid ~= false) then return end
  local expected = S.fuel.waiting and S.fuel.waiting.point or S.fuel.output
  if S.fuelKey(point) ~= S.fuelKey(expected) then return end
  return S.fuelClear()
end
S.fuelEmpty = function(point)
  if not S.fuel.auto or not S.fuelPointOk(point) then return false end
  if not S.fuel.output then S.fuelAlert("output not set", point) return false end
  local key, now = S.fuelKey(point), SO.now()
  if key ~= S.fuelKey(S.fuel.output) then return false end
  if S.fuel.waiting then return true, "waiting" end
  if now < (S.fuel.cooldowns[key] or 0) then return true, "cooldown" end
  if not S.turtle then S.fuelAlert("storage room missing",point) return true end
  if not S.heardAt or now - S.heardAt >= 30000 then S.fuelAlert("stock stale",point) return true end
  local name
  for _, fuel in ipairs({"minecraft:charcoal","minecraft:coal"}) do
    if (S.totals[fuel] or 0) >= 64 then name = fuel break end
  end
  if not name then S.fuelAlert("stock below 64",point) return true end
  local nextPolicy = SO.store.copy(S.fuel)
  local count = 0
  for saved, untilAt in pairs(nextPolicy.cooldowns) do
    if untilAt <= now then nextPolicy.cooldowns[saved] = nil else count = count + 1 end
  end
  if not nextPolicy.cooldowns[key] and count >= 64 then S.fuelAlert("cooldown ledger full",point) return true end
  nextPolicy.cooldowns[key] = now + 600000
  local entry, why = S.ordinaryOutput(point, "fuel")
  if why then S.fuelAlert(why,point) return true end
  local allocated = S.allocate()
  if not allocated then S.fuelAlert("output save failed",point) return true end
  if entry then
    entry.requestRid, entry.state, entry.sentAt = allocated, "ordering", now
    if not S.outputSave() then return true end
  end
  nextPolicy.serial = allocated
  nextPolicy.waiting = {at=now,point=SO.store.copy(point),rid=nextPolicy.serial,sender=S.turtle}
  nextPolicy.alert = nil
  -- Save before sending so a power cut cannot repeat the order.
  if not S.fuelSave(nextPolicy) then return true end
  local rid, err
  if entry then
    S.pending[allocated] = {kind="order",sender=S.turtle,at=now}
    local sent = rednet.send(S.turtle,{cmd="order",text=name,n=64,rid=allocated,outputToken=entry.token},"roomsorter")
    if sent ~= false then rid=allocated else err="send failed" end
  else rid, err = S.request("order", name, 64, nil, nextPolicy.serial) end
  if not rid then S.fuelAlert(err,point,true) end
  return true
end
S.fuelAlerts = function()
  if S.fuelSaveError then return {{reason="save failed",text=S.fuelSaveError}} end
  if S.fuel.auto and S.fuel.alert then return {SO.store.copy(S.fuel.alert)} end
  return {}
end


-- Output ownership outlives the delivery flags and every logical order wait.
S.outputValid = function(v)
  if type(v) ~= "table" or v.v ~= 1 or not S.integer(v.highWater,0,2^53-2) or type(v.outputs) ~= "table" then return false end
  if v.answeredRooms~=nil and type(v.answeredRooms)~="table" then return false end
  for id,answered in pairs(v.answeredRooms or {}) do
    if type(id)~="string" or not S.integer(tonumber(id),0,2^53-2)
      or id~=tostring(tonumber(id)) or answered~=true then return false end
  end
  local n = 0
  for key, row in pairs(v.outputs) do
    n = n+1
    if n > 64 or type(key) ~= "string" or type(row) ~= "table" or not S.fuelPointOk(row.point)
      or key ~= S.fuelKey(row.point) or not S.integer(row.roomId,0,2^53-2)
      or type(row.token) ~= "string" or #row.token < 1 or #row.token > 128
      or type(row.ownerId) ~= "string" or not ({delivery=true,fuel=true,ordinary=true})[row.kind]
      or row.sentAt~=nil and not S.integer(row.sentAt,0,2^53-2)
      or row.pollAt~=nil and not S.integer(row.pollAt,0,2^53-2)
      or row.controlRid~=nil and not S.integer(row.controlRid,1,v.highWater)
      or row.reconciled~=nil and type(row.reconciled)~="boolean"
      or row.retired~=nil and type(row.retired)~="boolean"
      or row.claimed~=nil and type(row.claimed)~="boolean"
      or row.releaseIntent~=nil and type(row.releaseIntent)~="boolean"
      or row.roomReleased~=nil and type(row.roomReleased)~="boolean"
      or row.abandoned~=nil and type(row.abandoned)~="boolean"
      or row.claimDenied~=nil and type(row.claimDenied)~="boolean"
      or row.createdAt~=nil and not S.integer(row.createdAt,0,2^53-2)
      or not ({claiming=true,claimed=true,ordering=true,quarantined=true,settled=true,releasing=true,released=true})[row.state]
      or row.requestRid ~= nil and not S.integer(row.requestRid,1,v.highWater)
      or row.barrier ~= nil and not S.integer(row.barrier,0,2^53-2) then return false end
  end
  return true
end
S.deliverySeedValid = function(v)
  if type(v)~="table" or v.v~=1 or not S.integer(v.serial,0,2^53-2) then return false end
  for _,key in ipairs({"active","last"}) do
    local row=v[key]
    if row~=nil and (type(row)~="table" or row.orderRid~=nil and not S.integer(row.orderRid,1,2^53-2)) then return false end
  end
  return true
end
S.outputInit = function()
  if S.output then return not S.outputFault end
  S.output = {v=1,highWater=math.max(math.floor(SO.now()),S.fuel.serial or 0),outputs={}}
  if not SO.store or not SO.store.store then S.outputFault=true return false end
  local path = "so-data/shop-output"
  local ok, box = pcall(function()
    local newest, rejected = 0,0
    for _,file in ipairs({path,path..".tmp",path..".bak"}) do
      if fs and fs.exists and fs.exists(file) then
        local t, bytes = SO.store.read(file)
        if type(t) ~= "table" or not S.integer(t.generation,1,2^53-2) then error("invalid output generation") end
        if t.schema == 1 and S.outputValid(t.value) and type(bytes)=="string" and #bytes<=65536 then newest=math.max(newest,t.generation)
        else rejected=math.max(rejected,t.generation) end
      end
    end
    assert(rejected==0 or rejected<newest,"invalid output generation")
    return SO.store.store(path,S.outputValid,65536)
  end)
  if not ok then S.outputFault=true return false end
  if box.value and not S.outputValid(box.value) then S.outputFault=true return false end
  S.outputBox=box
  S.output=box.value or S.output
  S.output.answeredRooms=S.output.answeredRooms or {}
  -- Delivery ids may predate this allocator's first generation.
  local okDelivery, delivery = pcall(function()
    local newest,rejected=0,0
    for _,file in ipairs({"so-data/build/delivery","so-data/build/delivery.tmp","so-data/build/delivery.bak"}) do
      if fs and fs.exists and fs.exists(file) then
        local v,bytes=SO.store.read(file)
        assert(type(v)=="table" and S.integer(v.generation,1,2^53-2),"invalid delivery generation")
        if v.schema==1 and S.deliverySeedValid(v.value) and type(bytes)=="string" and #bytes<=65536 then newest=math.max(newest,v.generation)
        else rejected=math.max(rejected,v.generation) end
      end
    end
    assert(rejected==0 or rejected<newest,"invalid delivery generation")
    return SO.store.store("so-data/build/delivery",S.deliverySeedValid,65536)
  end)
  if not okDelivery then S.outputFault=true return false end
  local saved = delivery.value
  S.output.highWater=math.max(S.output.highWater,S.fuel.serial or 0,
    saved and saved.active and saved.active.orderRid or 0,saved and saved.last and saved.last.orderRid or 0)
  for _,row in pairs(S.output.outputs) do
    if row.claimed or row.barrier~=nil or row.claimDenied or row.roomReleased then
      S.output.answeredRooms[tostring(row.roomId)]=true
    end
    if row.state~="released" then row.state,row.reconciled="quarantined",row.abandoned==true and not row.requestRid end
  end
  return S.outputSave()
end
S.outputSave = function()
  if S.outputFault or not S.outputBox then return false end
  if not S.outputBox.save(S.output) then S.outputSaveError=true return false end
  S.outputSaveError=nil
  return true
end
S.deliveryEnabled = function()
  local cfg=SO.store and SO.store.read and SO.store.read("so-server.cfg")
  return F.enabled(cfg, "storageDeliveries")
end
S.outputNeeded = function()
  if S.deliveryEnabled() then return true end
  if S.output then return S.outputFault or next(S.output.outputs)~=nil end
  if not SO.store or not SO.store.read then return false end
  for _,path in ipairs({"so-data/shop-output","so-data/shop-output.tmp","so-data/shop-output.bak"}) do
    if fs and fs.exists and fs.exists(path) then
      local saved,bytes=SO.store.read(path)
      if type(saved)~="table" or saved.schema~=1 or not S.integer(saved.generation,1,2^53-2)
        or not S.outputValid(saved.value) or type(bytes)~="string" or #bytes>65536 then return true end
      S.rid=math.max(S.rid,saved.value.highWater)
      if next(saved.value.outputs)~=nil then return true end
    end
  end
  return false
end
S.allocate = function(persist)
  if persist==false or not S.outputNeeded() then
    local n=math.max(S.rid,S.fuel.serial or 0,S.output and S.output.highWater or 0)+1
    if not S.integer(n,1,2^53-2) then return nil,"request ids exhausted" end
    S.rid=n return n
  end
  if not S.outputInit() then return nil,"output save failed" end
  local n=math.max(S.rid,S.output.highWater,math.floor(SO.now()),S.fuel.serial or 0)+1
  if not S.integer(n,1,2^53-2) then return nil,"request ids exhausted" end
  S.output.highWater=n
  if not S.outputSave() then return nil,"output save failed" end
  S.rid=n
  return n
end
S.outputSend = function(row,cmd)
  local rid,why=S.allocate()
  if not rid then return nil,why end
  row.controlRid,row.controlCmd=rid,cmd
  if cmd=="output.claim" then row.state="claiming" end
  if cmd=="output.release" then row.state,row.releaseIntent="releasing",true end
  if not S.outputSave() then return nil,"output save failed" end
  S.pending[rid]={kind="output",sender=row.roomId,key=S.fuelKey(row.point),at=SO.now(),cmd=cmd}
  local requestRid=row.requestRid
  if cmd=="output.status" and row.releaseIntent then requestRid=nil end
  rednet.send(row.roomId,{cmd=cmd,rid=rid,outputToken=row.token,output={
    dim=({[0]="minecraft:overworld",[-1]="minecraft:the_nether",[1]="minecraft:the_end"})[row.point.dim] or row.point.dim,
    x=row.point.x,y=row.point.y,z=row.point.z},requestRid=requestRid,barrier=row.barrier},"roomsorter")
  row.pollAt=SO.now()
  return rid
end
S.outputClaim = function(ownerId,point,kind)
  if not S.fuelPointOk(point) or type(ownerId)~="string" or #ownerId>128
    or not ({delivery=true,fuel=true,ordinary=true})[kind] then return nil,"invalid output" end
  if not S.outputInit() then return nil,"output save failed" end
  local key=S.fuelKey(point)
  local row=S.output.outputs[key]
  if row and row.state~="released" then
    if row.ownerId~=ownerId or row.kind~=kind then return nil,"output quarantined" end
    return SO.store.copy(row)
  end
  if not S.turtle then return nil,"storage room missing" end
  local n=0 for _ in pairs(S.output.outputs) do n=n+1 end
  if not row and n>=64 then return nil,"output ledger full" end
  local rid,why=S.allocate()
  if not rid then return nil,why end
  row={point=SO.store.copy(point),roomId=S.turtle,token="so-"..tostring(os.getComputerID()).."-"..string.format("%.0f",rid),
    kind=kind,ownerId=ownerId,state="claiming",createdAt=SO.now(),reconciled=false}
  S.output.outputs[key]=row
  if not S.outputSave() then return nil,"output save failed" end
  S.outputSend(row,"output.claim")
  return SO.store.copy(row)
end
S.outputStatus = function(ownerId)
  if not S.outputInit() then return nil,"output save failed" end
  for _,row in pairs(S.output.outputs) do
    if row.ownerId==ownerId and row.state~="released" then return SO.store.copy(row) end
  end
end
S.outputReconciled = function(ownerId)
  if not S.outputInit() then return false end
  for _,row in pairs(S.output.outputs) do
    if row.ownerId==ownerId and row.state~="released" then
      row.reconciled=true
      if not S.outputSave() then return false end
      if row.roomReleased then row.state="released" return S.outputSave() end
      if row.state=="settled" then S.outputSend(row,"output.release") end
      return true
    end
  end
  return true
end
S.outputReleaseLocal = function(row)
  row.state="released"
  local key=S.fuelKey(row.point)
  for rid,pending in pairs(S.pending) do
    if pending.key==key and pending.sender==row.roomId then S.pending[rid]=nil end
  end
end
S.outputAbandon = function(ownerId)
  if not S.outputNeeded() then return true end
  if not S.outputInit() then return false end
  for _,row in pairs(S.output.outputs) do
    if row.ownerId==ownerId and row.state~="released" then
      if row.requestRid then return false end
      row.abandoned,row.reconciled=true,true
      if row.claimDenied then S.outputReleaseLocal(row) end
      return S.outputSave()
    end
  end
  return true
end
S.ordinaryOutput = function(point,kind)
  if not S.outputNeeded() then return nil end
  if not S.outputInit() then return nil,"output save failed" end
  local cfg=SO.store.read("so-server.cfg") or {}
  local pinned=point or S.fuel.output
  local chosen=cfg.storageDeliveryOutput
  local drops=SO.mods.drops
  for _,p in ipairs(drops and drops.list and drops.list() or {}) do
    if not point and p.id==chosen then pinned=p break end
  end
  local row=pinned and S.output.outputs[S.fuelKey(pinned)]
  -- A room has one physical output. A retired enrollment still requires claims.
  for _,other in pairs(S.output.outputs) do
    if other.roomId==S.turtle then
      if other.state~="released" then row=other break end
      row=row or other
    end
  end
  if point and row and S.fuelKey(row.point)~=S.fuelKey(point) then return nil,"output quarantined" end
  if not row then
    if pinned and chosen and F.enabled(cfg, "storageDeliveries") then
      local claimed,why=S.outputClaim((kind or "ordinary")..":"..S.fuelKey(pinned),pinned,kind or "ordinary")
      return nil,why or (claimed and "output claim pending") or "output quarantined"
    end
    return nil
  end
  if row.state=="released" then
    local claimed,why=S.outputClaim((kind or "ordinary")..":"..S.fuelKey(row.point),row.point,kind or "ordinary")
    return nil,why or (claimed and "output claim pending") or "output quarantined"
  end
  local expected=(kind or "ordinary")..":"..S.fuelKey(row.point)
  if row.ownerId~=expected or row.state~="claimed" or row.requestRid then return nil,"output quarantined" end
  return row
end
S.deliveryReady = function(item,n)
  if not S.itemId(item) or not S.integer(n,1,64) then return false,"invalid delivery" end
  if not S.turtle then return false,"storage room missing" end
  if not S.heardAt or SO.now()-S.heardAt>=30000 then return false,"stock stale" end
  if not S.stacks[item] then return false,"stack unknown" end
  if n>S.stacks[item] then return false,"bad count" end
  if (S.totals[item] or 0)<n then return false,"stock below "..n end
  return true
end
S.deliveryOrder = function(jobId,item,n,point)
  if type(jobId)~="string" or not S.fuelPointOk(point) then return nil,"invalid delivery" end
  if not S.outputInit() then return nil,"output save failed" end
  if not S.itemId(item) or not S.integer(n,1,64) then return nil,"invalid delivery" end
  local build=SO.mods.build
  if not build or not build.deliveryItem or not build.deliveryItem(item) then return nil,"tools refused" end
  local ready,reason=S.deliveryReady(item,n)
  if not ready then return nil,reason end
  local row=S.output.outputs[S.fuelKey(point)]
  if not row or row.kind~="delivery" or row.ownerId~=jobId or row.state~="claimed" or row.requestRid
    or row.roomId~=S.turtle then return nil,"room support missing or output quarantined" end
  local rid,why=S.allocate()
  if not rid then return nil,why end
  row.requestRid,row.sentAt,row.state=rid,SO.now(),"ordering"
  if not S.outputSave() then return nil,"output save failed" end
  S.pending[rid]={kind="delivery",sender=row.roomId,key=S.fuelKey(point),at=row.sentAt}
  rednet.send(row.roomId,{cmd="get",text=item,n=n,rid=rid,outputToken=row.token},"roomsorter")
  return rid
end
S.deliveryOrderStatus = function(jobId) return S.outputStatus(jobId) end
-- What panel and pocket SHOP draw for deliveries: the live flag, the room output point id and every
-- output row that is not released. With the flag off and no saved output state it reads and saves nothing.
S.deliveryView = function()
  local cfg=SO.store and SO.store.read and SO.store.read("so-server.cfg")
  cfg=type(cfg)=="table" and cfg or {}
  local view={enabled=F.enabled(cfg, "storageDeliveries"),output=cfg.storageDeliveryOutput,outputs={}}
  if not S.outputNeeded() then return view end
  if not S.outputInit() then view.fault="output save failed" return view end
  for _,row in pairs(S.output.outputs) do
    if row.state~="released" then
      view.outputs[#view.outputs+1]={kind=row.kind,ownerId=row.ownerId,state=row.state,error=row.error}
    end
  end
  table.sort(view.outputs,function(a,b) return a.ownerId<b.ownerId end)
  return view
end
S.outputReply = function(sender,message,pending)
  local row=S.output.outputs[pending.key]
  if not row or row.state=="released" or row.roomId~=sender or message.v~=1 or message.outputToken~=row.token
    or not S.integer(message.barrier,0,2^53-2)
    or message.requestRid~=nil and not S.integer(message.requestRid,1,2^53-2)
    or not ({claimed=true,busy=true,settled=true,released=true,refused=true,quarantined=true})[message.state] then return end
  if not S.output.answeredRooms[tostring(sender)] then
    S.output.answeredRooms[tostring(sender)]=true
    if not S.outputSave() then return end
  end
  if pending.kind=="delivery" then
    -- An acceptance is not a settlement receipt.
    return
  end
  if pending.cmd=="output.status" and row.releaseIntent and row.requestRid~=nil
    and message.state=="settled" and message.requestRid==nil then
    row.roomReleased,row.barrier=true,message.barrier
    row.state=row.reconciled and "released" or "settled"
    S.pending[message.rid]=nil S.outputSave() return
  end
  if message.requestRid~=row.requestRid then return end
  S.pending[message.rid]=nil
  if pending.cmd=="output.claim" and message.state~="claimed" then
    row.claimDenied=true
    if row.abandoned then S.outputReleaseLocal(row) S.outputSave() return end
  end
  if pending.cmd=="output.release" and message.state=="released" then row.state="released"
  elseif row.abandoned and not row.requestRid and message.state=="refused"
    and (message.error=="room support missing" or message.error=="output claim required") then S.outputReleaseLocal(row)
  elseif message.state=="claimed" and not row.requestRid then row.state,row.claimed="claimed",true
  elseif message.state=="settled" and S.integer(message.barrier,0,2^53-2) then
    row.state,row.barrier="settled",message.barrier
  else row.state="quarantined" end
  row.error=message.error
  S.outputSave()
end
S.outputTick = function(now)
  if not S.outputNeeded() then return end
  if not S.outputInit() then return end
  for _,row in pairs(S.output.outputs) do
    if row.state=="claiming" and now-(row.createdAt or 0)>=15000 then
      row.state,row.error="quarantined","room support missing or claim unconfirmed"
      if not S.outputSave() then return end
    end
    local pending=row.requestRid and S.pending[row.requestRid]
    local timeout=row.kind=="ordinary" and pending and pending.acknowledged and 600000 or 120000
    if row.requestRid and row.sentAt and now-row.sentAt>=timeout and not row.retired then
      if row.kind~="ordinary" then S.pending[row.requestRid]=nil end
      row.retired,row.error=true,"order timed out"
      if row.state~="settled" and row.state~="released" then row.state="quarantined" end
      if not S.outputSave() then return end
    end
    if row.kind=="ordinary" and not row.reconciled
      and (row.retired or not row.requestRid and now-(row.createdAt or 0)>=120000) then
      row.reconciled=true
      if not S.outputSave() then return end
    end
    if row.state~="released" and row.reconciled and not row.requestRid and row.claimed~=true
      and not S.output.answeredRooms[tostring(row.roomId)]
      and now-(row.createdAt or 0)>=15000 then
      S.outputReleaseLocal(row)
      if not S.outputSave() then return end
    end
    if row.state~="released" and (not row.pollAt or now-row.pollAt>=10000) then
      S.outputSend(row,row.state=="settled" and row.reconciled and "output.release" or "output.status")
    end
  end
end

S.savedBoxes, S.watchKeys = {}, {}
S.savedEnabled = function()
  local read = SO.store and SO.store.read
  local cfg = read and read("so-server.cfg")
  return F.enabled(cfg, "shopSaved")
end
S.integer = function(n, lo, hi)
  return type(n) == "number" and n == n and n >= lo and n <= hi and n % 1 == 0
end
S.itemId = function(id)
  return type(id) == "string" and #id <= 128 and id:match("^[a-z0-9_.-]+:[a-z0-9_./-]+$") ~= nil
end
S.dense = function(t, limit, valid)
  if type(t) ~= "table" then return false end
  local n = 0
  for key, value in pairs(t) do
    n = n+1
    if not S.integer(key,1,limit) or not valid(value) then return false end
  end
  if n > limit then return false end
  for i = 1,n do if t[i] == nil then return false end end
  return true
end
S.allowedKeys = function(t, allowed)
  if type(t) ~= "table" then return false end
  for key in pairs(t) do if not allowed[key] then return false end end
  return true
end
S.savedValid = function(v, kind)
  if type(v) ~= "table" or v.v ~= 1 or v.kind ~= kind or not S.integer(v.revision,0,2147483647)
      or type(v.entries) ~= "table" or not S.allowedKeys(v,{v=true,kind=true,revision=true,entries=true}) then return false end
  local seen, names = {}, {}
  if kind == "minimums" then
    local n = 0
    for item, count in pairs(v.entries) do
      n = n+1
      if n > 256 or not S.itemId(item) or not S.integer(count,1,4096) then return false end
    end
    return true
  elseif kind == "watches" or kind == "pins" then
    return S.dense(v.entries,kind == "pins" and 4 or 256,function(item)
      if not S.itemId(item) or seen[item] then return false end
      seen[item] = true
      return true
    end)
  elseif kind == "lists" then
    return S.dense(v.entries,16,function(list)
      if not S.allowedKeys(list,{id=true,name=true,items=true}) or type(list.id) ~= "string"
          or #list.id < 1 or #list.id > 32 or not list.id:match("^[a-z0-9_-]+$") or seen[list.id]
          or type(list.name) ~= "string" or #list.name < 1 or #list.name > 32
          or list.name:find("[^ -~]") or names[list.name] then return false end
      seen[list.id], names[list.name] = true,true
      local items = {}
      return S.dense(list.items,32,function(row)
        if not S.allowedKeys(row,{item=true,count=true}) or not S.itemId(row.item)
            or items[row.item] or not S.integer(row.count,1,64) then return false end
        items[row.item] = true
        return true
      end)
    end)
  end
  return false
end
S.savedEqual = function(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do if not S.savedEqual(value,b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end
S.savedPreflight = function(kind)
  local path, newest, rejected, picked = "so-data/shop-"..kind, 0, 0, nil
  for _, file in ipairs({path,path..".tmp",path..".bak"}) do
    if fs.exists(file) then
      local ok, t, bytes = pcall(SO.store.read,file)
      local generation = ok and type(t) == "table" and t.generation
      if not S.integer(generation,1,2^53-1) then return false end
      if t.schema == 1 and S.savedValid(t.value,kind) and type(bytes) == "string" and #bytes <= 65536 then
        if generation > newest then newest,picked = generation,t.value end
      else rejected = math.max(rejected,generation) end
    end
  end
  return rejected == 0 or rejected < newest, picked
end
S.savedCommitted = function(kind, current)
  local ok, value = S.savedPreflight(kind)
  if not ok then return false end
  if not value then return current.revision == 0 and next(current.entries) == nil end
  if value.revision ~= current.revision then return false end
  return S.savedEqual(value.entries,current.entries)
end
S.savedBlock = function(kind, box)
  box.blocked = true
  if SO.error then SO.error("shop-"..kind..": save unavailable; recovery failed",true) end
end
S.savedRestore = function(kind, box)
  if S.savedCommitted(kind,box.current) then return end
  local ok, restored = pcall(function()
    -- Ignore the rejected revision while selecting the rollback source.
    local rollback = SO.store.store("so-data/shop-"..kind,function(v)
      return S.savedValid(v,kind) and v.revision == box.current.revision
    end,65536)
    if not rollback.save(box.current) or not S.savedCommitted(kind,box.current) then return end
    local reopened = SO.store.store("so-data/shop-"..kind,function(v) return S.savedValid(v,kind) end,65536)
    reopened.current,reopened.present = box.current,true
    return reopened
  end)
  if ok and restored then S.savedBoxes[kind] = restored
  else S.savedBlock(kind,box) end
end
S.savedBox = function(kind)
  if not S.savedEnabled() then return nil, "off" end
  if kind ~= "minimums" and kind ~= "watches" and kind ~= "lists" and kind ~= "pins" then return nil, "invalid" end
  if S.savedBoxes[kind] == nil then
    if not S.savedPreflight(kind) then S.savedBoxes[kind] = false return nil,"save unavailable" end
    local ok, box = pcall(SO.store.store, "so-data/shop-" .. kind,
      function(v) return S.savedValid(v, kind) end, 65536)
    S.savedBoxes[kind] = ok and box or false
    if ok then
      box.current = box.value or {v=1, kind=kind, revision=0, entries={}}
      box.present = box.value ~= nil
    end
  end
  return S.savedBoxes[kind] or nil, "save unavailable"
end
S.saved = function(kind)
  local box, err = S.savedBox(kind)
  if not box then return nil, err end
  if box.blocked then return nil,"save unavailable" end
  return SO.store.copy(box.current)
end
S.minimum = function(item)
  local box = S.savedBox("minimums")
  return box and box.current.entries[item] or math.min(16, S.stackOf(item, S.kind(item)))
end
S.watchAlerts = function(fresh)
  local state = SO.mods.state
  if not state or not state.get or not state.emit then return end
  if not S.watchScanned and state.view then
    S.watchScanned = true
    for key, value in pairs(state.view().values or {}) do
      if type(key) == "string" and key:match("^shop%.watch%..+%.alert$") and value then S.watchKeys[key] = true end
    end
  end
  local enabled, watched = S.savedEnabled(), {}
  local box = enabled and S.savedBox("watches")
  for _, item in ipairs(box and box.current.entries or {}) do watched[item] = true end
  for key in pairs(S.watchKeys) do
    local item = key:sub(12, -7)
    if not enabled or box and (not watched[item] or fresh and S.totals[item] ~= nil and S.totals[item] > 0) then
      if not state.get(key) or state.emit(key, false) ~= false then S.watchKeys[key] = nil end
    end
  end
  if not fresh or not box then return end
  for item in pairs(watched) do
    if S.totals[item] == 0 then
      local key = "shop.watch." .. item .. ".alert"
      if not state.get(key) then state.emit(key, {item=item, count=0, text=item .. " empty"}) end
      S.watchKeys[key] = true
    end
  end
end
S.savedChange = function(kind, revision, edit)
  local box, err = S.savedBox(kind)
  if not box then return false, err end
  if box.blocked then return false,"save unavailable" end
  if not S.savedPreflight(kind) then S.savedBlock(kind,box) return false,"save unavailable" end
  if not S.integer(revision, 0, 2147483647) or revision ~= box.current.revision then return false, "changed" end
  if revision == 2147483647 then return false, "save unavailable" end
  local data = SO.store.copy(box.current)
  local ok, why = edit(data.entries)
  if not ok then return false, why or "invalid" end
  data.revision = revision + 1
  if not S.savedValid(data, kind) then return false, "invalid" end
  if not box.present then
    if not box.save(box.current) then return false,"save unavailable" end
    box.present = true
  end
  if not box.save(data) then
    S.savedRestore(kind,box)
    return false, "save unavailable"
  end
  box.current = data
  if kind == "watches" then S.watchAlerts(S.heardAt ~= nil and SO.now() - S.heardAt < 30000) end
  return true
end

S.savedEdit = function(kind, item, value, revision)
  return S.savedChange(kind,revision,function(entries)
    if not S.itemId(item) then return false end
    if kind == "minimums" then entries[item] = value
    else
      if type(value) ~= "boolean" then return false end
      for i = #entries,1,-1 do if entries[i] == item then table.remove(entries,i) end end
      if value then entries[#entries+1] = item end
    end
    return true
  end)
end
S.setList = function(id, list, revision)
  return S.savedChange("lists",revision,function(entries)
    local found
    for i, saved in ipairs(entries) do if saved.id == id then found = i break end end
    if list ~= nil then
      if type(list) ~= "table" or list.id ~= id then return false end
      local candidate = {v=1,kind="lists",revision=0,entries={list}}
      if not S.savedValid(candidate,"lists") then return false end
      for _, row in ipairs(list.items) do
        local stack = S.stacks[row.item]
        if not stack then return false,"stack unknown" end
        if row.count > stack then return false,"bad count" end
      end
      entries[found or #entries+1] = SO.store.copy(list)
    elseif found then table.remove(entries,found)
    else return false,"changed" end
    return true
  end)
end
S.listOrder = function(id, item, revision, view)
  local data, why = S.saved("lists")
  if not data then return nil,why end
  if data.revision ~= revision then return nil,"changed" end
  for _, list in ipairs(data.entries) do
    if list.id == id then
      for _, row in ipairs(list.items) do
        if row.item == item then
          if not S.stacks[item] then return nil,"stack unknown" end
          if row.count > S.stacks[item] then return nil,"bad count" end
          local room = S.status()
          if not room.found then return nil,"storage room missing" end
          if room.stale then return nil,"stock stale" end
          if S.totals[item] == nil then return nil,"stock unknown" end
          return S.order(item,row.count,view)
        end
      end
    end
  end
  return nil,"changed"
end
S.firstPin = function()
  local pins = S.saved("pins")
  return pins and pins.entries[1]
end

S.savedNav = function(c, _state, item, x, y, width, lists)
  local pins, why = S.saved("pins")
  if why == "off" then return end
  local nx = x
  if item then
    local pinned = false
    for _, id in ipairs(pins and pins.entries or {}) do pinned = pinned or id == item end
    if pins then nx = c.chip(nx,y,pinned and "UNPIN" or "PIN","saved2:pin:"..pins.revision..":"..item)+1 end
  end
  if (not item or lists) and nx+7 <= x+width then nx = c.chip(nx,y,"LISTS","saved2:lists")+1 end
  if item and nx+5 <= x+width then c.chip(nx,y,"ADD","saved2:add:"..item) end
end
S.savedRecord = function(state, frame)
  state.savedHeight = #frame.rows
  state.extraDrawn = {}
  for _, b in ipairs(frame.buttons) do
    if b.id:match("^saved2:") then state.extraDrawn[b.id] = b end
  end
end
S.savedHit = function(event, button, state)
  if not button or type(event.x) ~= "number" or type(event.y) ~= "number" then return false end
  local session, y = event.session, event.y
  if session and type(session.h) == "number" and state.savedHeight then
    y = y-math.max(0,session.h-state.savedHeight)
  end
  return event.x >= button.x and event.x < button.x+button.w
    and y >= button.y and y < button.y+(button.h or 1)
end
S.savedCanvas = function(c, state, w, h)
  local data, why = S.saved("lists")
  local page, draft = state.savedPage, state.listDraft
  c.section(2,3,w-2,"LISTS",state.savedResult or why or "")
  local back = function() c.chip(w-6,h,"BACK","saved2:back") end
  if not data then back() return end
  local list
  for _, row in ipairs(data.entries) do if row.id == page then list = row end end
  -- Too short for a full row and the footer: close up the blank rows, list pager beside the name.
  local step = draft and 2 or w < 24 and 4 or 3
  local tight = h < (draft and 12 or step+8)
  if draft then
    if draft.row then
      local row, g = draft.value.items[draft.row], h < 12 and 1 or 2
      c.put(2,3+g,row.item:sub(1,w-2),"0")
      c.leader(2,3+2*g,w-2,"requested",tostring(row.count))
      U.stepper(c,2,3+3*g,row.count,"saved2:count",2)
      c.chip(2,h-g,"REMOVE","saved2:remove")
      c.chip(2,h,"DONE","saved2:done")
      back()
      return
    end
    if tight then c.chip(2,4,"NAME","saved2:name") c.put(9,4,draft.value.name:sub(1,w-9),"0")
    else c.chip(2,5,"NAME","saved2:name") c.put(2,6,draft.value.name:sub(1,w-2),"0") end
    list = draft.value
  elseif list then c.put(2,4,list.name:sub(1,tight and #list.items > 1 and w-10 or w-2),"0") end
  if list then
    local top = tight and 5 or draft and 8 or 6
    local per = math.max(1,math.min(4,math.floor((h-2-top)/step)))
    local pages = math.max(1,math.ceil(#list.items/per))
    state.listPage = math.max(1,math.min(state.listPage or 1,pages))
    for i = (state.listPage-1)*per+1,math.min(#list.items,state.listPage*per) do
      local row = list.items[i]
      local y = top+(i-(state.listPage-1)*per-1)*step
      c.put(2,y,S.label(row.item):upper():sub(1,w-2),"0")
      if draft then
        c.leader(2,y+1,w-2,"requested",tostring(row.count))
        c.hit("saved2:row:"..i,2,y,w-2,2)
      else
        local stack, room = S.stacks[row.item], S.status()
        local available = room.found and not room.stale and S.totals[row.item] or nil
        c.leader(2,y+1,w-2,"requested",tostring(row.count))
        c.leader(2,y+2,w < 24 and w-2 or w-11,"available",available ~= nil and tostring(available) or "-",available ~= nil and "0" or "8")
        local orderY = y+(w < 24 and 3 or 2)
        if available and available > 0 and stack and row.count <= stack then
          c.put(w-8,orderY,"[","8"); c.put(w-7,orderY,"ORDER","0"); c.put(w-2,orderY,"]","8")
          c.hit("saved2:order:"..data.revision..":"..list.id..":"..row.item,w-8,orderY,7,1,"ORDER")
        end
      end
    end
    if pages > 1 and tight and not draft then
      c.chip(w-7,4,U.g.left,"saved2:prev")
      c.chip(w-3,4,U.g.right,"saved2:next")
    elseif pages > 1 then
      c.chip(2,h-2,U.g.left,"saved2:prev")
      c.put(6,h-2,state.listPage.."/"..pages,"8")
      c.chip(10,h-2,U.g.right,"saved2:next")
    end
    if draft then
      if draft.confirm and SO.now()-(draft.confirmAt or 0) > 5000 then U.confirm(draft,nil,SO.now()) end
      local control = U.confirmChip(draft,"delete","DELETE","saved2:delete","plain")
      c.chip(2,h-1,control[1],control[2],control[3])
      c.chip(2,h,"SAVE","saved2:save")
    else c.chip(2,h,"EDIT","saved2:edit:"..data.revision..":"..list.id) end
  else
    local per = math.max(1,h-7)
    local pages = math.max(1,math.ceil(#data.entries/per))
    state.listPage = math.max(1,math.min(state.listPage or 1,pages))
    for i = (state.listPage-1)*per+1,math.min(#data.entries,state.listPage*per) do
      local row,y = data.entries[i],4+i-(state.listPage-1)*per
      c.leader(2,y,w-2,row.name,tostring(#row.items))
      c.hit("saved2:open:"..data.revision..":"..row.id,2,y,w-2,1)
    end
    if pages > 1 then
      c.chip(2,h-2,U.g.left,"saved2:prev")
      c.put(6,h-2,state.listPage.."/"..pages,"8")
      c.chip(10,h-2,U.g.right,"saved2:next")
    end
    if #data.entries < 16 then c.chip(2,h,"NEW","saved2:new") end
  end
  if state.listOrder then
    local status = tostring(state.order or ""):match("^Order: (%a+)") or "sent"
    c.put(2,h-1,(state.listOrder.." "..status):sub(1,w-2),status == "failed" and "e" or "d")
  end
  back()
end
S.savedInput = function(event, state)
  local id, draft = event.id, state.listDraft
  if type(event.text) == "string" and state.savedPage then
    if S.savedEnabled() and draft then
      if draft.row then
        local n = tonumber(event.text)
        if S.integer(n,1,64) then draft.value.items[draft.row].count = n end
      elseif #event.text >= 1 and #event.text <= 32 and not event.text:find("[^ -~]") then draft.value.name = event.text end
    end
    return true
  end
  if type(id) ~= "string" or not id:match("^saved2:") then return false end
  local b = state.extraDrawn and state.extraDrawn[id]
  if not S.savedHit(event,b,state) then return true end
  state.extraDrawn = nil
  if not S.savedEnabled() then return true end
  state.savedResult, state.listOrder = nil,nil
  if draft and id ~= "saved2:delete" then U.confirm(draft,nil,SO.now()) end
  local pinRev, item = id:match("^saved2:pin:(%d+):(.+)$")
  if pinRev then
    local pins = S.saved("pins")
    local on = true
    for _, name in ipairs(pins and pins.entries or {}) do if name == item then on = false end end
    local ok, err = S.savedEdit("pins",item,on,tonumber(pinRev))
    state.savedResult = not ok and err or nil
    return true
  end
  if id == "saved2:lists" or id:match("^saved2:add:") then
    state.savedPage,state.listDraft,state.listPage,state.addItem = true,nil,1,id:match("^saved2:add:(.+)$")
    return true
  end
  if id == "saved2:back" then
    if draft and draft.row then draft.row = nil
    elseif draft then state.listDraft = nil
    elseif state.savedPage ~= true then state.savedPage,state.listPage = true,1
    else state.savedPage,state.addItem = nil,nil end
    return true
  end
  local data, why = S.saved("lists")
  if not data then state.savedResult = why return true end
  local action, revision, listId = id:match("^saved2:(%a+):(%d+):([a-z0-9_-]+)$")
  local orderRev, orderList, orderItem = id:match("^saved2:order:(%d+):([a-z0-9_-]+):(.+)$")
  if orderRev then
    local name, result = S.listOrder(orderList,orderItem,tonumber(orderRev),state)
    if name then state.listOrder = result else state.savedResult = result end
    return true
  end
  if action then
    if tonumber(revision) ~= data.revision then state.savedResult = "changed" return true end
    for _, list in ipairs(data.entries) do
      if list.id == listId then
        state.savedPage,state.listPage = listId,1
        if action == "edit" or state.addItem then
          state.listDraft = {revision=data.revision,value=SO.store.copy(list)}
          if state.addItem then
            local found
            for _, row in ipairs(state.listDraft.value.items) do if row.item == state.addItem then found = true end end
            if not found then table.insert(state.listDraft.value.items,{item=state.addItem,count=1}) end
            state.addItem = nil
          end
        end
        break
      end
    end
  elseif id == "saved2:new" then
    local used, n = {},1
    for _, list in ipairs(data.entries) do used[list.id],used[list.name] = true,true end
    while used["list-"..n] or used["List "..n] do n = n+1 end
    state.listDraft = {revision=data.revision,value={id="list-"..n,name="List "..n,items={}}}
    if state.addItem then state.listDraft.value.items={{item=state.addItem,count=1}} state.addItem = nil end
  elseif id == "saved2:prev" or id == "saved2:next" then
    state.listPage = math.max(1,(state.listPage or 1)+(id == "saved2:next" and 1 or -1))
  elseif draft then
    if id == "saved2:delete" then
      if U.confirm(draft,"delete",SO.now()) then
        local ok, err = S.setList(draft.value.id,nil,draft.revision)
        if ok then state.savedPage,state.listDraft = true,nil else state.savedResult = err end
      end
      return true
    end
    local row = tonumber(id:match("^saved2:row:(%d+)$"))
    if row and draft.value.items[row] then draft.row = row
    elseif id == "saved2:done" then draft.row = nil
    elseif id == "saved2:remove" and draft.row then table.remove(draft.value.items,draft.row) draft.row = nil
    elseif id == "saved2:count-" and draft.row then draft.value.items[draft.row].count = math.max(1,draft.value.items[draft.row].count-1)
    elseif id == "saved2:count+" and draft.row then draft.value.items[draft.row].count = math.min(64,draft.value.items[draft.row].count+1)
    elseif id == "saved2:save" then
      local ok, err = S.setList(draft.value.id,draft.value,draft.revision)
      if ok then state.savedPage,state.listDraft = draft.value.id,nil else state.savedResult = err end
    end
  end
  return true
end

S.stock = function(message)
  if type(message.totals) == "table" then
    S.heardAt = SO.now()
    S.heardDate = os.epoch("utc")
    local totals = {}
    for name, count in pairs(message.totals) do
      if type(name) == "string" and type(count) == "number" and count >= 0
          and count < math.huge then totals[name] = count end
    end
    S.totals = totals
    S.watchAlerts(true)
  end
  if type(message.state) == "string" then S.state = message.state end
  for name, label in pairs(type(message.labels) == "table" and message.labels or {}) do
    if type(name) == "string" and type(label) == "string" then S.labels[name] = label:sub(1, 40) end
  end
  for name, stack in pairs(type(message.stacks) == "table" and message.stacks or {}) do
    if type(name) == "string" and type(stack) == "number" and stack >= 1 and stack <= 64 then
      S.stacks[name] = math.floor(stack)
    end
  end
  for name, tags in pairs(type(message.tags) == "table" and message.tags or {}) do
    if type(name) == "string" and type(tags) == "table" then
      local list = {}
      for _, tag in ipairs(tags) do if type(tag) == "string" and #list < 16 then list[#list + 1] = tag end end
      if table.concat(list, " ") ~= table.concat(S.tags[name] or {}, " ") then S.kinds[name] = nil end
      S.tags[name] = list
    end
  end
  if type(message.recipes) == "table" then
    local recipes = {}
    for _, recipe in ipairs(message.recipes) do
      if type(recipe) == "table" and type(recipe.name) == "string" and type(recipe.can) == "number" then
        recipes[recipe.name] = recipe.can
      end
    end
    S.recipes = recipes
  end
end

S.reply = function(sender, message)
  if type(message) ~= "table" then return end
  local pending = S.pending[message.rid]
  if pending and pending.sender ~= sender then pending = nil end
  if pending and (pending.kind=="output" or pending.kind=="delivery") then
    S.outputReply(sender,message,pending) return
  end
  local waiting = S.fuel.waiting
  if waiting and S.deliveryEnabled() and SO.now()-waiting.at>=120000 then
    S.fuelAlert("fuel order timed out",waiting.point,true)
    if message.rid==waiting.rid and sender==waiting.sender then return end
    waiting=nil
  end
  local fuelReply = waiting and waiting.rid == message.rid and waiting.sender == sender
  if not pending and not fuelReply then return end
  if pending and pending.kind == "stock" then
    S.pending[message.rid] = nil
    S.stock(message)
  else
    local lines = {}
    for i = 1, #message do
      if type(message[i]) == "string" then lines[#lines + 1] = message[i] end
    end
    if message.rid == S.latestOrder then S.orders = lines end
    local text = table.concat(lines, "; ")
    local lower = text:lower()
    local status = "failed"
    if lower:match("^getting ") or lower:match("^crafting ") or lower:find("getting those", 1, true) then
      status = "sent"
    elseif lower:match("^delivered ") or lower:find("sent to output chest", 1, true) then
      status = "delivered"
    end
    if fuelReply then
      if status == "failed" then
        local refused = lower:match("^not in storage") or lower:match("^none in storage")
          or lower:match("^not enough") or lower:match("^which one") or lower:match("^refused") or lower:match("^failed")
        S.fuelAlert((refused and "order refused: " or "reply unconfirmed: ") .. (text ~= "" and text or "empty reply"), waiting.point, refused)
      elseif status == "delivered" then S.fuelAvailable(waiting.point) end
    end
    if pending then
      if status == "sent" then pending.acknowledged = true
      else S.pending[message.rid] = nil end
      if pending.entry then pending.entry.status = status end
    end
    if pending and pending.view and pending.view.orderRid == message.rid then
      pending.view.order = "Order: " .. status
      pending.view.orderDetail = text ~= "" and text or "empty reply"
    end
  end
end

S.broadcast = function(sender, message)
  if type(message) ~= "table" or type(message.totals) ~= "table" then return end
  if not S.turtle then S.turtle = sender S.selectedAt = SO.now() end
  if sender ~= S.turtle then return end
  S.stock(message)
  local state = SO.mods.state
  if state and state.get and state.emit then
    local full = message.full == true
    local alerted = not not state.get("shop.room.alert")
    if full ~= alerted then
      state.emit("shop.room.alert", full and { text = "Storage room full" } or false)
    end
  end
end

S.dns = function(sender, message)
  if not S.turtle and type(message) == "table" and message.sType == "lookup response"
      and message.sProtocol == "roomsorter" then
    S.turtle = sender
    S.selectedAt = SO.now()
  end
end

-- One sample per minute and item, 60 kept. An item gone from stock for the whole hour is forgotten.
S.sample = function(now)
  if S.sampleAt and now - S.sampleAt < 60000 then return end
  if next(S.totals) == nil and next(S.history) == nil then return end
  S.sampleAt = now
  for name, samples in pairs(S.history) do
    if S.totals[name] == nil then
      samples[#samples + 1] = 0
      if #samples > 60 then table.remove(samples, 1) end
      local seen = false
      for _, value in ipairs(samples) do seen = seen or value > 0 end
      if not seen then S.history[name] = nil end
    end
  end
  for name, count in pairs(S.totals) do
    local samples = S.history[name]
    if not samples then samples = {} S.history[name] = samples end
    samples[#samples + 1] = count
    if #samples > 60 then table.remove(samples, 1) end
  end
end

S.row = function(text)
  return { text = text, fg = "0", bg = "f" }
end

S.view = function(client)
  local key = type(client) == "table" and (client.id or client) or client or 0
  if not S.views[key] then
    S.views[key] = { search = "", page = 1, sort = "count", tab = "items", cat = "all", sub = "all", low = "all" }
  end
  return S.views[key]
end

S.norm = function(text)
  return (text:lower():gsub("%s+", "_"))
end

S.match = function(name, query)
  if query == "" or name:lower():find(query, 1, true) then return true end
  return S.norm(S.label(name)):find(query, 1, true) ~= nil
end

-- Read-only: stocked items whose id or name contains the search, most stock first, then by id.
S.matches = function(search, limit)
  local query, list = S.norm(tostring(search or "")), {}
  for name, count in pairs(S.totals) do
    if S.match(name, query) then list[#list + 1] = { name = name, count = count, label = S.label(name):upper() } end
  end
  table.sort(list, function(a, b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
  for i = #list, (limit or 10) + 1, -1 do list[i] = nil end
  return list
end

-- An exact id keeps its stock count, including zero; other searches use the first match.
S.best = function(search)
  if type(search) ~= "string" or search == "" then return nil end
  if S.totals[search] ~= nil then return search, S.totals[search] end
  local best = S.matches(search, 1)[1]
  if best and best.count > 0 then return best.name, best.count end
  return nil
end

-- Read-only: low and empty items (S.items) whose id or name contains the search, emptiest first, then by id.
S.lows = function(limit, search)
  local query, list = S.norm(tostring(search or "")), {}
  for _, item in ipairs(S.items()) do
    if item.state ~= "ok" and S.match(item.name, query) then
      list[#list + 1] = { name = item.name, count = item.count, label = item.label:upper(), stack = item.stack,
        state = item.state }
    end
  end
  table.sort(list, function(a, b) return a.count < b.count or (a.count == b.count and a.name < b.name) end)
  for i = #list, (limit or 10) + 1, -1 do list[i] = nil end
  return list
end

-- Whether the storage room is known and whether its stock is older than 30 seconds.
S.status = function()
  return { found = S.turtle ~= nil, stale = S.heardAt == nil or SO.now() - S.heardAt >= 30000 }
end

-- One order for the best match: a whole count from 1 to its stack size, "stack" (its stack size) or "all"
-- (its stock, at most one stack). No order is ever larger than a stack. Returns the
-- item and count sent, or nil and a reason. Changes no display's screen state; a given view gets the
-- order status and reply the way a shop display's view does.
S.order = function(search, count, view)
  local name, stock = S.best(search)
  if not name then return nil, "no match" end
  local stack = S.stackOf(name, S.kind(name))
  if count == "stack" then count = stack elseif count == "all" then count = math.min(stock, stack) end
  if stock <= 0 then return nil, "out of stock" end
  if type(count) ~= "number" or count ~= math.floor(count) or count < 1 or count > stack then
    return nil, "bad count"
  end
  local rid, err = S.request("order", name, count)
  if not rid then return nil, err end
  if type(view) == "table" then
    S.pending[rid].view = view
    view.order, view.orderDetail, view.orderRid = "Order: sent " .. count, nil, rid
  end
  return name, count
end

S.legacy = function(_w, _h, clientId)
  local search = S.view(clientId).search
  local picture = {
    rows = {},
    buttons = {
      { id = "clear", x = 9, y = 1, w = 5, label = "clear" },
    },
  }
  local rows, buttons = picture.rows, picture.buttons
  rows[1] = S.row("              Storage: " .. S.state)
  rows[2] = S.row("")
  if not S.turtle then
    rows[#rows + 1] = S.row("Storage room not found, still looking")
    return picture
  end
  for i = 1, #S.orders do rows[#rows + 1] = S.row("Order: " .. S.orders[i]) end
  local items = {}
  local query = search:lower():gsub("%s+", "_")
  for name, count in pairs(S.totals) do
    if name:lower():find(query, 1, true) then items[#items + 1] = { name = name, count = count } end
  end
  table.sort(items, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)
  for i = 1, #items do
    local item = items[i]
    local samples = S.history[item.name]
    local baseline = samples and samples[1] or item.count
    local arrow = item.count > baseline and "^" or (item.count < baseline and "v" or "-")
    -- Counts above the item's stack are left blank and get no button.
    local y, stack = #rows + 1, S.stackOf(item.name, S.kind(item.name))
    rows[y] = S.row("1 " .. (stack >= 16 and "16" or "  ") .. " " .. (stack >= 64 and "64" or "  ") .. " " .. arrow
      .. " " .. tostring(item.count) .. " " .. item.name)
    for _, amount in ipairs({ 1, 16, 64 }) do
      if amount <= stack then
        buttons[#buttons + 1] = {
          id = "order:" .. tostring(amount) .. ":" .. item.name,
          x = amount == 1 and 1 or (amount == 16 and 3 or 6),
          y = y, w = #tostring(amount), label = tostring(amount),
        }
      end
    end
  end
  return picture
end

-- Categories in chip order with their sub ids. MODS has one sub per namespace present.
S.cats = {
  { "ores", "ore raw ingot nugget block gem dust" },
  { "wood", "log planks sapling crafted" },
  { "stone", "stone earth build" },
  { "plants", "leaves seeds flowers plants" },
  { "food", "crops meat meals" },
  { "tools", "tools weapons armour" },
  { "redstone", "dust logic motion" },
  { "mobs", "hostile passive" },
  { "mods", "" },
  { "other", "" },
}

-- First match wins. Patterns test the id after its namespace. "=metal" is a storage
-- block of a metal or gem, "=wood" any id starting with a wood type.
S.rules = {
  "tools/armour _helmet$ _chestplate$ _leggings$ _boots$ ^elytra$ _horse_armor$ ^wolf_armor$",
  "tools/weapons _sword$ ^bow$ ^crossbow$ ^trident$ ^mace$ ^shield$ arrow$",
  "tools/tools _pickaxe$ _axe$ _shovel$ _hoe$ ^shears$ ^fishing_rod$ ^flint_and_steel$ ^brush$ ^spyglass$"
    .. " ^compass$ ^clock$ bucket$",
  "redstone/dust ^redstone$ ^redstone_block$",
  "redstone/logic ^repeater$ ^comparator$ ^observer$ ^redstone_torch$ ^lever$ _button$ _pressure_plate$"
    .. " ^daylight_detector$ ^target$ ^tripwire_hook$ ^redstone_lamp$ sculk_sensor$ ^note_block$ ^lightning_rod$",
  "redstone/motion piston$ ^hopper$ ^dropper$ ^dispenser$ rail$ minecart$ ^tnt$ ^crafter$",
  "food/meals ^cooked_ ^bread$ ^baked_potato$ ^cookie$ _pie$ _stew$ _soup$ ^cake$ ^dried_kelp$ ^golden_carrot$"
    .. " golden_apple$ ^honey_bottle$",
  "food/meat ^beef$ ^porkchop$ ^chicken$ ^mutton$ ^rabbit$ ^cod$ ^salmon$ ^tropical_fish$ ^pufferfish$",
  "food/crops ^wheat$ ^carrot$ ^potato$ ^poisonous_potato$ ^beetroot$ ^melon_slice$ ^melon$ ^pumpkin$ ^apple$"
    .. " _berries$ ^chorus_fruit$ ^nether_wart$ ^sugar$ ^cocoa_beans$",
  "mobs/hostile ^bone$ ^bone_meal$ ^string$ spider_eye$ ^gunpowder$ ^rotten_flesh$ ^ender_pearl$ ^ender_eye$"
    .. " ^blaze_ ^ghast_tear$ ^slime_ball$ ^phantom_membrane$ ^magma_cream$ ^shulker_shell$ ^prismarine_shard$"
    .. " ^prismarine_crystals$ _skull$ ^nether_star$ ^breeze_rod$",
  "mobs/passive ^leather$ ^feather$ ink_sac$ ^egg$ ^rabbit_hide$ ^rabbit_foot$ scute$ ^honeycomb$ ^nautilus_shell$",
  "ores/ore _ore$ ^ancient_debris$",
  "ores/block =metal",
  "ores/raw ^raw_",
  "ores/ingot _ingot$ ^ingot_ ^netherite_scrap$",
  "ores/nugget _nugget$ ^nugget_",
  "ores/gem ^diamond$ ^emerald$ ^lapis_lazuli$ ^quartz$ ^amethyst_shard$ ^coal$ ^charcoal$ _gem$ ^gem_",
  "ores/dust _dust$ ^dust_",
  "wood/log _log$ _wood$ _stem$ _hyphae$ ^stripped_ ^bamboo_block$",
  "wood/planks _planks$",
  "wood/sapling _sapling$ _propagule$ azalea$ _fungus$",
  "plants/leaves _leaves$",
  "plants/seeds _seeds$",
  "plants/flowers ^dandelion$ ^poppy$ ^blue_orchid$ ^allium$ ^azure_bluet$ _tulip$ ^oxeye_daisy$ ^cornflower$"
    .. " ^lily_of_the_valley$ ^sunflower$ ^lilac$ ^rose_bush$ ^peony$ ^wither_rose$ ^torchflower$ ^pitcher_plant$",
  "plants/plants ^vine$ ^kelp$ ^cactus$ ^sugar_cane$ ^bamboo$ ^moss_ ^lily_pad$ _mushroom$ grass$ fern$"
    .. " ^dead_bush$ ^seagrass$ ^sea_pickle$ ^glow_lichen$ _roots$ _vines$ dripleaf$ ^spore_blossom$",
  "stone/stone ^stone$ ^cobblestone$ ^mossy_cobblestone$ ^cobbled_deepslate$ ^deepslate$ ^granite$ ^diorite$"
    .. " ^andesite$ ^tuff$ ^calcite$ basalt$ ^blackstone$ ^netherrack$ ^end_stone$ obsidian$ ^dripstone_block$"
    .. " ^pointed_dripstone$ ^smooth_stone$ sandstone$ ^magma_block$",
  "stone/earth ^dirt$ ^coarse_dirt$ ^rooted_dirt$ ^grass_block$ ^podzol$ ^mycelium$ nylium$ ^sand$ ^red_sand$"
    .. " ^gravel$ ^clay$ ^clay_ball$ ^mud$ ^soul_sand$ ^soul_soil$ ^snow ^ice$ ^packed_ice$ ^flint$",
  "wood/crafted =wood ^stick$ ^chest$ ^barrel$ ^crafting_table$ ^ladder$ ^bowl$",
  "stone/build brick glass$ glass_pane$ _concrete terracotta$ _wool$ _carpet$ ^quartz_ ^smooth_ ^polished_"
    .. " ^chiseled_ ^cut_ _tiles$ prismarine$ ^purpur_ _stairs$ _slab$ _wall$ ^bookshelf$",
}
S.metals = {}
for word in ("iron gold copper netherite diamond emerald lapis coal zinc tin lead silver nickel osmium"
    .. " uranium aluminum platinum brass bronze steel"):gmatch("%S+") do S.metals[word] = true end
S.woods = {}
for word in ("oak spruce birch jungle acacia dark_oak pale_oak mangrove cherry bamboo crimson warped")
    :gmatch("%S+") do S.woods[word] = true end
-- Common item tags (c:, forge:, minecraft:) for ids the rules miss, keyed by the tag's base word.
S.tagKinds = {
  ores = "ores/ore", raw_materials = "ores/raw", ingots = "ores/ingot", nuggets = "ores/nugget",
  gems = "ores/gem", dusts = "ores/dust", storage_blocks = "ores/block", logs = "wood/log",
  planks = "wood/planks", saplings = "wood/sapling", leaves = "plants/leaves", seeds = "plants/seeds",
  flowers = "plants/flowers", small_flowers = "plants/flowers", crops = "food/crops", foods = "food/meals",
  tools = "tools/tools", swords = "tools/weapons", armors = "tools/armour", stones = "stone/stone",
  stone = "stone/stone", cobblestones = "stone/stone", cobblestone = "stone/stone",
}

S.special = function(token, path)
  if token == "=metal" then
    local base = path:match("^(.+)_block$")
    return base ~= nil and (S.metals[base] or base:match("^raw_") ~= nil)
  end
  for wood in pairs(S.woods) do
    if path:sub(1, #wood + 1) == wood .. "_" then return true end
  end
  return false
end

-- Category and sub of an item id, from the rules, then its tags, then its namespace.
S.kind = function(name)
  local cached = S.kinds[name]
  if cached then return cached[1], cached[2] end
  if not S.compiled then
    S.compiled = {}
    for _, line in ipairs(S.rules) do
      local cat, sub, rest = line:match("^(%a+)/(%a+)%s+(.+)$")
      local patterns = {}
      for pattern in rest:gmatch("%S+") do patterns[#patterns + 1] = pattern end
      S.compiled[#S.compiled + 1] = { cat, sub, patterns }
    end
  end
  local space, path = name:match("^([^:]+):(.+)$")
  if not space then space, path = "minecraft", name end
  local cat, sub
  for _, rule in ipairs(S.compiled) do
    for _, pattern in ipairs(rule[3]) do
      local hit
      if pattern:sub(1, 1) == "=" then hit = S.special(pattern, path) else hit = path:find(pattern) ~= nil end
      if hit then cat, sub = rule[1], rule[2] break end
    end
    if cat then break end
  end
  for _, tag in ipairs(cat == nil and S.tags[name] or {}) do
    local found = S.tagKinds[tag:gsub("^[%w_]+:", ""):gsub("/.*$", "")]
    if found then cat, sub = found:match("^(%a+)/(%a+)$") break end
  end
  if not cat then
    if space == "minecraft" then cat, sub = "other", "other" else cat, sub = "mods", space end
  end
  S.kinds[name] = { cat, sub }
  return cat, sub
end

S.label = function(name)
  if S.labels[name] then return S.labels[name] end
  local path = name:match(":(.+)$") or name
  return ((" " .. path:gsub("_", " ")):gsub(" (%l)", function(c) return " " .. c:upper() end):sub(2))
end

S.stackOf = function(name, cat)
  if S.stacks[name] then return S.stacks[name] end
  local path = name:match(":(.+)$") or name
  for _, pattern in ipairs({ "^ender_pearl$", "^egg$", "^snowball$", "^bucket$", "^honey_bottle$", "_sign$",
      "_banner$", "^armor_stand$" }) do
    if path:find(pattern) then return 16 end
  end
  if cat == "tools" and not path:find("arrow$") then return 1 end
  return 64
end

S.short = function(n)
  if n >= 10000 then return math.floor(n / 1000) .. "k" end
  return tostring(n)
end

-- Every known item: stocked now, or stocked within the sampled hour (count 0).
S.items = function()
  local names, list = {}, {}
  local box = S.savedBox("minimums")
  local minimums = box and box.current.entries or {}
  for name in pairs(S.totals) do names[name] = true end
  for name in pairs(S.history) do names[name] = true end
  for name in pairs(names) do
    local count, samples = S.totals[name] or 0, S.history[name]
    local delta = count - (samples and samples[1] or count)
    local rate = math.floor(math.abs(delta) * 60 / math.max(1, samples and #samples - 1 or 1) + 0.5)
    local cat, sub = S.kind(name)
    local stack = S.stackOf(name, cat)
    list[#list + 1] = { name = name, label = S.label(name), count = count, stack = stack, cat = cat, sub = sub,
      rate = delta < 0 and -rate or rate,
      state = count == 0 and "empty" or count < (minimums[name] or math.min(16, stack)) and "low" or "ok" }
  end
  return list
end

S.sorts = {
  count = function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end,
  name = function(a, b)
    local x, y = a.label:lower(), b.label:lower()
    if x == y then return a.name < b.name end
    return x < y
  end,
  trend = function(a, b)
    local x, y = math.abs(a.rate), math.abs(b.rate)
    if x == y then return a.name < b.name end
    return x > y
  end,
}

-- The shown list for this display: its tab's filter in its sort, plus the selected item.
S.gather = function(client)
  local view = S.view(client)
  local status = S.status()
  local m = { found = status.found, all = S.items(), items = {}, recipes = S.recipes, stale = status.stale, time = "-" }
  if S.heardAt then m.time = U and U.clock(S.heardDate).hm or "-" end
  local query = S.norm(view.search)
  for _, item in ipairs(m.all) do
    local keep
    if view.tab == "low" then keep = item.state ~= "ok" and (view.low == "all" or item.state == view.low)
    elseif view.tab == "find" then keep = S.match(item.name, query)
    else keep = (view.cat == "all" or item.cat == view.cat) and (view.sub == "all" or item.sub == view.sub) end
    if keep then m.items[#m.items + 1] = item end
    if item.name == view.selected then m.selected = item end
  end
  table.sort(m.items, S.sorts[view.sort] or S.sorts.count)
  m.recent = m.selected and S.recent[m.selected.name] or {}
  return m
end

-- Sub chips of the open category: its table, or one per mod namespace by item count.
S.subs = function(view, m)
  local subs = { { "sub:all", "all" } }
  for _, cat in ipairs(S.cats) do
    if cat[1] == view.cat then
      for sub in cat[2]:gmatch("%S+") do subs[#subs + 1] = { "sub:" .. sub, sub } end
    end
  end
  if view.cat == "mods" then
    local counts, spaces = {}, {}
    for _, item in ipairs(m.all) do
      if item.cat == "mods" then
        if not counts[item.sub] then spaces[#spaces + 1] = item.sub end
        counts[item.sub] = (counts[item.sub] or 0) + 1
      end
    end
    table.sort(spaces, function(a, b)
      if counts[a] == counts[b] then return a < b end
      return counts[a] > counts[b]
    end)
    for _, space in ipairs(spaces) do subs[#subs + 1] = { "sub:" .. space, space:sub(1, 10) } end
  end
  return #subs > 1 and subs or nil
end

-- Route A layout. docs/ui/schematic/shop.py is its twin and writes the fixtures; change both.
S.tabs = { "items", "low", "find" }
S.keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
S.marks = { sent = "d", delivered = "8", failed = "e" }
S.most, S.budget = 32, 15000

S.stateFg = function(item)
  return item.state == "empty" and "8" or item.state == "low" and "1" or "0"
end

-- Header row: the kit bar when SHOP, the tabs and the right word fit, else the tabs alone.
-- The time gives way first; a stale word that still does not fit moves to the footer (m.note).
S.head = function(C, m, view, w)
  local word = not m.found and "missing" or m.stale and "stale" or "stock"
  local rfg = not m.found and "e" or m.stale and "1" or "8"
  local right = word == "missing" and word or w >= 52 and word .. " " .. m.time or word == "stock" and m.time or word
  if w < 31 + #right then right = word == "stock" and "" or word end
  if w >= 31 + #right or (w >= 29 and right == "") then return C.bar("SHOP", S.tabs, view.tab, right, rfg) end
  if w < 23 + #right then m.note, right = word == "stale", "" end
  local x = 1
  for _, t in ipairs(S.tabs) do
    local label = " " .. t .. " "
    if t == view.tab then C.put(x, 1, label, "0", "7") else C.put(x, 1, label, "8") end
    C.hit("tab:" .. t, x, 1, #label, 1, t)
    x = x + #label + 1
  end
  local last = w - #right - 1
  if right ~= "" then C.put(last + 1, 1, right, rfg) end
  C.rule(x, 1, last - 1)
end

S.note = function(C, m, x, y)
  if m.note then C.put(x, y, "stale", "1") end
end

-- Chips left to right with one cell between, wrapping at x2. Returns the rows used; dry only counts.
S.flow = function(C, x1, x2, y, entries, active, dry)
  local x, rows = x1, 1
  for _, entry in ipairs(entries) do
    if x > x1 and x + #entry[2] + 1 > x2 then x, rows = x1, rows + 1 end
    if dry then x = x + #entry[2] + 3
    else x = C.chip(x, y + rows - 1, entry[2], entry[1], entry[1] == active and "plain" or "off") + 1 end
  end
  return rows
end

-- The column head is the sort control: item, stock and /h; the active one is a chip with a down arrow.
S.sorter = function(C, x, y, lw, view, trend)
  for _, s in ipairs({ { "item", "name", x - 1, x }, { "stock", "count", x + lw - 8, x + lw - 5 },
      { "/h", "trend", x + lw + 1, x + lw + 2 } }) do
    if s[2] ~= "trend" or trend then
      if view.sort == s[2] then C.chip(s[3], y, s[1] .. " " .. U.g.down, "sort:" .. s[2])
      else
        C.put(s[4], y, s[1], "8")
        C.hit("sort:" .. s[2], s[4], y, #s[1], 1, s[1])
      end
    end
  end
end

S.line = function(C, x, y, cw, item, trend, selected)
  if selected then C.fill(x - 1, y, cw + 2, 1, "7") end
  local lw = trend and cw - 7 or cw
  C.leader(x, y, lw, item.label:upper(), tostring(item.count), S.stateFg(item), "0")
  if trend and item.rate ~= 0 then
    local up = item.rate > 0
    C.put(x + lw + 2, y, (up and "\24" or "\25") .. S.short(math.abs(item.rate)), up and "8" or "1")
  end
  C.hit("item:" .. item.name, x, y, cw, 1, item.label:upper())
end

S.pages = function(C, m, w, h, page, count)
  local text = page .. " of " .. count
  C.put(2, h, text, "8")
  S.note(C, m, 3 + #text, h)
  S.chip(C, w - 11, h, U.g.left, "prev", page > 1, 5)
  S.chip(C, w - 5, h, U.g.right, "next", page < count, 5)
end

-- A chip that does nothing now is drawn muted and has no target.
S.chip = function(C, x, y, label, id, on, width)
  if on then return C.chip(x, y, label, id, "plain", width) end
  width = width or #label + 2
  C.put(x, y, string.rep(" ", width), "8", "7")
  C.put(x + math.max(0, math.floor((width - #label) / 2)), y, label:sub(1, width), "8", "7")
  return x + width
end

-- The item: name, facts as leaders, ORDER chips, then the recent orders.
S.pane = function(C, m, item, x, y, pw, bottom, close, view)
  local tall = bottom - y + 1 >= 13
  C.put(x, y, item.label:upper():sub(1, pw - (close and 3 or 0)), "0")
  if close then
    C.put(x + pw - 1, y, "\215", "8")
    C.hit("items", x + pw - 3, y, 3, 1, "\215")
  end
  y = y + (tall and 2 or 1)
  local facts = { { "stock", tostring(item.count), S.stateFg(item) } }
  if tall and item.stack > 1 then
    local full, rest = math.floor(item.count / item.stack), item.count % item.stack
    facts[#facts + 1] = { "stacks", full .. (rest > 0 and "+" .. rest or ""), "0" }
  end
  local rate = item.rate
  facts[#facts + 1] = { "last hour", rate == 0 and "0" or (rate > 0 and "\24" or "\25") .. S.short(math.abs(rate)),
    rate < 0 and "1" or rate > 0 and "0" or "8" }
  if tall and item.sub ~= item.cat then facts[#facts + 1] = { item.cat, item.sub, "0" } end
  if tall and (m.recipes[item.name] or 0) > 0 then facts[#facts + 1] = { "craftable", tostring(m.recipes[item.name]), "0" } end
  for _, fact in ipairs(facts) do
    C.leader(x, y, pw, fact[1], fact[2], fact[3])
    y = y + 1
  end
  if tall then y = y + 1 end
  C.section(x, y, pw, "ORDER")
  local cw, cw2 = math.floor((pw - 2) / 3), math.floor((pw - 1) / 2)
  for i, n in ipairs({ "1", "16", "64" }) do
    S.chip(C, x + (i - 1) * (cw + 1), y + 1, n, "order:" .. n .. ":" .. item.name, m.found and tonumber(n) <= item.stack, cw)
  end
  for i, n in ipairs({ "stack", "all" }) do
    S.chip(C, x + (i - 1) * (cw2 + 1), y + 2, n, "order:" .. n .. ":" .. item.name,
      m.found and (n ~= "all" or item.count > 0), cw2)
  end
  y = y + (tall and 4 or 3)
  if view and S.savedEnabled() and y <= bottom then S.savedNav(C,view,item.name,x,y,pw) y = y+1 end
  for _, e in ipairs(m.recent) do
    if y > bottom then break end
    C.put(x, y, U.g.bullet, S.marks[e.status] or "e")
    C.put(x + 2, y, (e.n .. " " .. e.status):sub(1, math.max(0, pw - 8)), "0")
    C.put(x + pw - #e.hm, y, e.hm, "8")
    y = y + 1
  end
  return y - 1
end

-- Narrow screens pick a category or sub from leader rows with item counts.
S.picker = function(C, m, view, y, w, bottom)
  local counts = {}
  for _, item in ipairs(m.all) do
    local keys = { "cat:all", "cat:" .. item.cat }
    if item.cat == view.cat then keys[3], keys[4] = "sub:all", "sub:" .. item.sub end
    for _, key in ipairs(keys) do counts[key] = (counts[key] or 0) + 1 end
  end
  local entries, active = { { "cat:all", "all" } }, "cat:" .. view.cat
  if view.pick == "cats" then
    for _, cat in ipairs(S.cats) do entries[#entries + 1] = { "cat:" .. cat[1], cat[1] } end
  else entries, active = S.subs(view, m) or {}, "sub:" .. view.sub end
  -- Columns stay 12 cells or wider; entries past the last column are left out (mods by count).
  local n = math.max(1, bottom - y + 1)
  local cols = math.max(1, math.min(math.ceil(#entries / n), math.floor(w / 14)))
  local cw = math.floor((w - 2 - 2 * (cols - 1)) / cols)
  for i = #entries, n * cols + 1, -1 do entries[i] = nil end
  for i, entry in ipairs(entries) do
    local x, ry = 2 + math.floor((i - 1) / n) * (cw + 2), y + (i - 1) % n
    if entry[1] == active then C.fill(x - 1, ry, cw + 2, 1, "7") end
    C.leader(x, ry, cw, entry[2], tostring(counts[entry[1]] or 0), "0", "0")
    C.hit(entry[1], x, ry, cw, 1, entry[2])
  end
end

-- The controls above the list for the open tab. Returns the next free row.
S.controls = function(C, m, view, w, y, gap, wide, bottom)
  if view.tab == "items" and wide then
    local cats = { { "cat:all", "all" } }
    for _, cat in ipairs(S.cats) do cats[#cats + 1] = { "cat:" .. cat[1], cat[1] } end
    y = y + S.flow(C, 2, w - 1, y, cats, "cat:" .. view.cat)
    local subs = view.cat ~= "all" and S.subs(view, m)
    -- More subs than two rows hold (many mod namespaces) open the picker instead.
    if subs and S.flow(C, 2, w - 1, y, subs, nil, true) > 2 then
      C.chip(2, y + gap, view.sub .. " " .. U.g.down, "pick:subs", view.pick == "subs" and "on" or "plain")
      y = y + gap + 1
    elseif subs then y = y + gap + S.flow(C, 2, w - 1, y + gap, subs, "sub:" .. view.sub) end
  elseif view.tab == "items" then
    local x = C.chip(2, y, view.cat .. " " .. U.g.down, "pick:cats", view.pick == "cats" and "on" or "plain")
    if view.cat ~= "all" and S.subs(view, m) then
      C.chip(x + 1, y, view.sub .. " " .. U.g.down, "pick:subs", view.pick == "subs" and "on" or "plain")
    end
    y = y + 1
  elseif view.tab == "low" then
    y = y + S.flow(C, 2, w - 1, y, { { "low:all", "all" }, { "low:low", "low" }, { "low:empty", "empty" } },
      "low:" .. view.low)
  else
    C.chip(C.chip(w - 12, y, "del", "key:DEL") + 1, y, "clr", "key:CLR")
    C.put(2, y, ">", "8")
    C.put(4, y, view.search:upper():sub(-math.max(1, w - 19)), "0")
    if view.keys then C.put(4 + math.min(#view.search, math.max(1, w - 19)), y, "_", "8") end
    if w > 15 then C.hit("keys", 2, y, w - 15, 1, ">") end
    y = y + 1
    if view.keys then
      local per = math.max(1, math.min(13, math.floor((w - 1) / 4)))
      for i = 1, #S.keys do
        local k, ky = S.keys:sub(i, i), y + gap + math.floor((i - 1) / per)
        if ky <= bottom then C.chip(2 + (i - 1) % per * 4, ky, k, "key:" .. k) end
      end
      y = y + gap + math.ceil(#S.keys / per)
    end
  end
  return y + gap
end

S.layout = function(m, view, w, h, most)
  local C = U.canvas(w, h)
  S.head(C, m, view, w)
  local gap = h >= 16 and 1 or 0
  local y, bottom, wide, item = 2 + gap, h - 1 - gap, w >= 52, m.selected
  if S.savedEnabled() then
    if view.savedPage then S.savedCanvas(C,view,w,h) return C.frame() end
    S.savedNav(C,view,nil,2,y,w-2)
    y = y+1
  else view.savedPage,view.listDraft = nil,nil end
  view.capacity = nil
  if item and not wide then
    S.pane(C, m, item, 2, y, w - 2, bottom, false, view)
    S.note(C, m, C.chip(2, h, "back", "items") + 1, h)
    return C.frame()
  end
  y = S.controls(C, m, view, w, y, gap, wide, bottom)
  if view.pick and view.tab == "items" and (not wide or view.pick == "subs") then
    S.picker(C, m, view, y, w, bottom)
    S.note(C, m, C.chip(2, h, "back", "back") + 1, h)
    return C.frame()
  end
  local cols, cw, trend, top, rx, last
  if item then
    rx = w - math.min(40, math.max(24, math.floor(w * 0.42))) - 2
    last = S.pane(C, m, item, rx + 2, y, w - rx - 2, bottom, true, view)
    cols, cw, trend, top = 1, rx - 3, false, y
  else
    cols = w >= 90 and 2 or 1
    cw = math.floor((w - 2 - 3 * (cols - 1)) / cols)
    trend, top = cw >= 36, y + 1
    for c = 1, cw >= 14 and cols or 0 do S.sorter(C, 2 + (c - 1) * (cw + 3), y, trend and cw - 7 or cw, view, trend) end
  end
  -- A page holds at most `most` items (S.most), which keeps the biggest walls under the frame budget.
  local n = math.min(math.max(0, bottom - top + 1), math.floor((most or S.most) / cols))
  local per = math.max(1, n * cols)
  local count = math.max(1, math.ceil(#m.items / per))
  view.page = math.max(1, math.min(view.page or 1, count))
  view.capacity = per
  if not m.found then
    C.put(2, top, "!", "e")
    C.put(4, top, ("storage room not found"):sub(1, math.max(0, w - 4)), "0")
  elseif #m.items == 0 then
    C.put(2, top, "no items", "8")
  end
  local first = (view.page - 1) * per
  local shown = n > 0 and math.min(per, #m.items - first) or 0
  local rows = math.max(1, math.min(n, math.ceil(shown / cols)))
  for i = 0, shown - 1 do
    local x = 2 + math.floor(i / rows) * (cw + 3)
    if i >= rows and i % rows == 0 then
      for ry = y, top + rows - 1 do C.put(x - 2, ry, "|", "c") end
    end
    local entry = m.items[first + i + 1]
    S.line(C, x, top + i % rows, cw, entry, trend, item ~= nil and entry.name == item.name)
  end
  for ry = y, item and math.max(last, shown > 0 and top + rows - 1 or y) or 0 do C.put(rx, ry, "|", "c") end
  S.pages(C, m, w, h, view.page, count)
  return C.frame()
end

-- Long item names on big walls can still pass the frame budget; redraw with fewer items a page.
S.render = function(w, h, session)
  if not U then return S.legacy(w, h, session) end
  w, h = w or 57, h or 24
  local m, view, most = S.gather(session), S.view(session), S.most
  local frame = S.layout(m, view, w, h, most)
  local ser = type(SO.proto) == "table" and SO.proto.ser
  while ser and most > 8 and #ser(frame) > S.budget do
    most = most - 8
    frame = S.layout(m, view, w, h, most)
  end
  S.savedRecord(view,frame)
  return frame
end

-- One shop tap. Tabs, categories, subs, sorts and searches reset the page and close the item.
S.press = function(view, client, id)
  local tab, cat, sub = id:match("^tab:(%a+)$"), id:match("^cat:(%a+)$"), id:match("^sub:(.+)$")
  local known = cat == "all"
  for _, entry in ipairs(S.cats) do known = known or entry[1] == cat end
  if tab == "items" or tab == "low" or tab == "find" or known or sub or id:match("^low:") or id:match("^sort:") then
    view.page, view.selected, view.pick = 1, nil, nil
  end
  if tab == "items" or tab == "low" or tab == "find" then
    view.tab = tab
    view.savedPage,view.listDraft,view.savedResult,view.addItem = nil,nil,nil,nil
    if tab == "find" then view.keys = true end
  elseif known then view.tab, view.cat, view.sub = "items", cat, "all"
  elseif sub then
    -- Only a sub of the open category; a tap from an older frame is dropped.
    for _, entry in ipairs(S.subs(view, S.gather(client)) or {}) do
      if entry[1] == id then view.sub = sub end
    end
  elseif id == "low:all" or id == "low:low" or id == "low:empty" then view.low = id:sub(5)
  elseif id == "pick:cats" or id == "pick:subs" then
    local pick = id:sub(6)
    view.pick = view.pick ~= pick and pick or nil
  elseif id == "back" then view.pick = nil
  elseif id == "keys" then view.keys = not view.keys
  elseif id:match("^sort:") then
    if S.sorts[id:sub(6)] then view.sort = id:sub(6) end
  elseif id == "items" then view.selected = nil
  elseif id == "next" or id == "prev" then
    local count = math.max(1, math.ceil(#S.gather(client).items / (view.capacity or 1)))
    view.page = math.max(1, math.min(count, (view.page or 1) + (id == "next" and 1 or -1)))
  end
  local key = id:match("^key:(%u+)$")
  if key then
    view.page, view.selected = 1, nil
    if key == "DEL" then view.search = view.search:sub(1, -2)
    elseif key == "CLR" then view.search = ""
    elseif #key == 1 and #view.search < 16 then view.search = view.search .. key:lower() end
  end
  local name = id:match("^item:(.+)$")
  if name and (S.totals[name] ~= nil or S.history[name] ~= nil) then
    view.selected = view.selected ~= name and name or nil
    view.order, view.orderDetail, view.orderRid = nil, nil, nil
  end
  local amount, target = id:match("^order:(%w+):(.+)$")
  if not amount or view.selected ~= target then return end
  local item = S.gather(client).selected
  local count = item and (amount == "stack" and item.stack or amount == "all" and math.min(item.count, item.stack)
    or (amount == "1" or amount == "16" or amount == "64") and tonumber(amount))
  if count and count >= 1 and count <= item.stack then S.request("order", target, count, view) end
end

S.input = function(event)
  local client = event.session or event.from
  local view = S.view(client)
  if S.savedInput(event,view) then return end
  if type(event.text) == "string" then
    view.search = (event.text == " " or event.text == "*") and "" or event.text:sub(1, 32)
    view.page, view.selected, view.pick, view.keys = 1, nil, nil, false
    if U then view.tab = "find" end
    return
  end
  if event.id == "clear" then view.search = ""; view.page, view.selected = 1, nil; return end
  if type(event.id) ~= "string" then return end
  if U then return S.press(view, client, event.id) end
  local count, name = event.id:match("^order:(%d+):(.+)$")
  count = tonumber(count)
  -- S.order refuses a count above the item's stack.
  if (count == 1 or count == 16 or count == 64) and S.totals[name] ~= nil then S.order(name, count, view) end
end

S.tick = function(now)
  S.outputTick(now)
  S.watchAlerts(false)
  if (S.fuel.auto or S.deliveryEnabled()) and S.fuel.waiting and now - S.fuel.waiting.at >= 120000 then
    S.fuelAlert("fuel order timed out", S.fuel.waiting.point, true)
  end
  local display = SO.mods.display
  if not S.registered and type(display) == "table" and type(display.screen) == "function" then
    display.screen("shop", S.render, S.input)
    S.registered = true
  end
  if S.turtle and now - (S.heardAt or S.selectedAt or now) >= S.staleAfter then
    S.turtle, S.heardAt, S.selectedAt, S.stockAt, S.lookupAt = nil, nil, nil, nil, nil
    S.totals, S.history, S.labels, S.stacks, S.tags, S.recipes, S.kinds = {}, {}, {}, {}, {}, {}, {}
    S.state = "waiting for stock"
    for rid, pending in pairs(S.pending) do
      if pending.kind == "stock" then S.pending[rid] = nil end
    end
  end
  if not S.turtle and (not S.lookupAt or now - S.lookupAt >= 10000) then
    S.lookupAt = now
    rednet.broadcast({ sType = "lookup", sProtocol = "roomsorter" }, "dns")
  end
  if S.turtle then
    if not S.stockAt or now - S.stockAt >= 10000 then
      S.stockAt = now
      S.request("stock")
    end
    S.sample(now)
  end
  for rid, pending in pairs(S.pending) do
    local timeout = pending.acknowledged and 600000 or 120000
    if now - pending.at >= timeout then
      S.pending[rid] = nil
      if pending.kind == "order" then
        local reason = pending.acknowledged and "no delivery" or "timed out"
        if rid == S.latestOrder then S.orders = { pending.acknowledged and reason or "reply timed out" } end
        if pending.entry then pending.entry.status = "failed" end
        if pending.view and pending.view.orderRid == rid then
          pending.view.order, pending.view.orderDetail = "Order: failed, " .. reason, reason
        end
      end
    end
  end
end

return {
  name = "shop",
  handlers = {},
  listen = { roomsorter = S.reply, roomsorter_stock = S.broadcast, dns = S.dns },
  tick = S.tick,
  order = S.order,
  outputClaim = S.outputClaim,
  outputStatus = S.outputStatus,
  outputReconciled = S.outputReconciled,
  outputAbandon = S.outputAbandon,
  deliveryOrder = S.deliveryOrder,
  deliveryReady = S.deliveryReady,
  deliveryOrderStatus = S.deliveryOrderStatus,
  deliveryView = S.deliveryView,
  matches = S.matches,
  best = S.best,
  lows = S.lows,
  stack = function(name) return type(name) == "string" and S.stackOf(name, S.kind(name)) or nil end,
  status = S.status,
  saved = S.saved,
  minimum = S.minimum,
  setMinimum = function(item, value, revision) return S.savedEdit("minimums", item, value, revision) end,
  setWatch = function(item, value, revision) return S.savedEdit("watches", item, value, revision) end,
  setPin = function(item, value, revision) return S.savedEdit("pins", item, value, revision) end,
  setList = S.setList,
  listOrder = S.listOrder,
  firstPin = S.firstPin,
  savedNav = S.savedNav,
  savedCanvas = S.savedCanvas,
  savedRecord = S.savedRecord,
  savedHit = S.savedHit,
  savedInput = S.savedInput,
  fuelConfig = S.fuelConfig,
  fuelEmpty = S.fuelEmpty,
  fuelAvailable = S.fuelAvailable,
  fuelClear = S.fuelClear,
  fuelAlerts = S.fuelAlerts,
}
