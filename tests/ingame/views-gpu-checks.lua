local M={}
local sides={top=true,bottom=true,left=true,right=true,front=true,back=true}
function M.pixelTarget(info,x,y)
  local directions={north={0,0,-1},south={0,0,1},east={1,0,0},west={-1,0,0},up={0,1,0},down={0,-1,0}}
  local front,right,down=info.facing:match("^cc:([^:]+):([^:]+):([^:]+)$")
  local n,r,d=directions[front],directions[right],directions[down]
  assert(n and r and d,"pixel targeting requires the actual CC facing basis")
  assert(info.width==1 and info.height==1,"pixel targeting fixture is a single block monitor")
  local aspect=info.pixelWidth/info.pixelHeight
  local fx,fy=math.min(1,aspect),math.min(1,1/aspect)
  local threshold=info.fitContent and 0.995 or 0.985
  if fx>=threshold then fx=1 end
  if fy>=threshold then fy=1 end
  local horizontal=((x+0.5)/info.pixelWidth-0.5)*0.76*fx
  local vertical=((y+0.5)/info.pixelHeight-0.5)*0.76*fy
  local target={normal={x=n[1],y=n[2],z=n[3]}}
  for i,axis in ipairs({"x","y","z"}) do
    target[axis]=info[axis]+0.5+n[i]*0.502+r[i]*horizontal-d[i]*vertical
  end
  return target
end
local function displayIds(displays)
  local ids={}
  for key,value in pairs(displays) do
    if type(value)=="table" and type(value.id)=="number" then ids[value.id]=true
    elseif type(key)=="number" then ids[key]=true end
  end
  return ids
end
function M.run(gpu,cfg)
  cfg=cfg or {}
  local result={checks={},selections={},peripherals={},bandwidthMeasured=false,
    bandwidthReason="DirectGPU 1.0.25 getJPEGNetworkStats returns constants. Lua frame and resource counters do not measure network bytes."}
  local before=gpu.listDisplays()
  local existing=displayIds(before)
  if cfg.existingDisplayId then existing[cfg.existingDisplayId]=true end
  local created={}
  local selectors={}
  for _,name in ipairs(cfg.selectors or {}) do selectors[#selectors+1]=name end
  for _,name in ipairs(peripheral.getNames()) do
    local kind=peripheral.getType(name)
    result.peripherals[#result.peripherals+1]={name=name,type=kind}
    if kind=="monitor" and not sides[name] then
      local found=false
      for _,selected in ipairs(selectors) do if selected==name then found=true end end
      if not found then selectors[#selectors+1]=name end
    end
  end
  result.resourcesBefore=gpu.getResourceStats()
  result.jpegStats=gpu.getJPEGNetworkStats()
  local function check(name,fn)
    local started=os.epoch("utc")
    local ok,why=pcall(fn)
    result.checks[#result.checks+1]={name=name,ok=ok,error=not ok and tostring(why) or nil,
      millis=os.epoch("utc")-started}
  end
  check("explicit adjacent and wired monitor selection",function()
    assert(#selectors>0 and #selectors<=8,"provide one to eight explicit monitor selectors")
    local adjacent,wired=false,false
    for _,name in ipairs(selectors) do
      local id=gpu.autoDetectAndCreateDisplay(name,cfg.width or 320,cfg.height or 240)
      assert(type(id)=="number","display creation did not return an id")
      if not existing[id] then created[id]=true end
      local info=gpu.getDisplayInfo(id)
      assert(info.pixelWidth>0 and info.pixelHeight>0,"missing actual pixel dimensions")
      local repeated=gpu.autoDetectAndCreateDisplay(name,cfg.width or 320,cfg.height or 240)
      assert(repeated==id,"same named monitor created duplicate display")
      adjacent=adjacent or sides[name]==true
      wired=wired or not sides[name]
      result.selections[#result.selections+1]={name=name,id=id,wired=not sides[name],info=info,reused=true}
      if created[id] then
        gpu.clear(id,12,19,29)
        gpu.drawText(id,"Explicit monitor "..name,4,4,220,230,240,"Monospaced",12,"plain")
        gpu.updateDisplay(id)
      end
    end
    result.adjacentSelectionTested=adjacent
    result.wiredSelectionTested=wired
    assert(adjacent,"no adjacent monitor fixture selected")
    assert(wired,"no attached wired monitor fixture was discovered")
  end)
  check("simultaneous distinct monitor displays",function()
    local unique,count={},0
    for _,entry in ipairs(result.selections) do
      if not unique[entry.id] then unique[entry.id]=true count=count+1 end
    end
    result.concurrentDisplayCount=count
    result.concurrentDisplays=gpu.listDisplays()
    assert(count>=2,"two physically distinct named monitors are required")
    for id in pairs(unique) do assert(gpu.getDisplayInfo(id).pixelWidth>0) end
  end)
  result.resourcesConcurrent=gpu.getResourceStats()
  for id in pairs(created) do
    local ok,why=pcall(gpu.removeDisplay,id)
    result.checks[#result.checks+1]={name="remove probe display "..id,ok=ok,error=not ok and tostring(why) or nil}
  end
  result.resourcesAfter=gpu.getResourceStats()
  result.ok=true
  for _,entry in ipairs(result.checks) do if not entry.ok then result.ok=false end end
  return result
end
return M
