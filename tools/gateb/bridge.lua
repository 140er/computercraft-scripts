local function read(path)
  local h=fs.open(path,'r');if not h then return nil end
  local s=h.readAll();h.close();return s
end
local function write(path,value)
  local tmp=path..'.tmp';local h=assert(fs.open(tmp,'w'))
  h.write(textutils.serializeJSON(value));h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp,path)
end
local role=assert(read('/.so-role')):match('^%s*(.-)%s*$')
local bootId=read('/.gateb/boot-id')
local programs={server='so-server.lua',worker='worker.lua',display='display.lua'}
local env=setmetatable({}, {__index=_ENV})
env._G=env
local screens={}
local jobs={}
local pending={}
local nextJob=0
local function capture(base,name)
  if screens[name] then return screens[name].proxy end
  local w,h=base.getSize()
  local win=window.create(base,1,1,w,h,true)
  local proxy=setmetatable({},getmetatable(base))
  for k,v in pairs(base) do proxy[k]=v end
  for k,v in pairs(win) do proxy[k]=v end
  if base.setTextScale then
    proxy.setTextScale=function(scale)
      base.setTextScale(scale);local nw,nh=base.getSize();win.reposition(1,1,nw,nh)
    end
  end
  screens[name]={win=win,proxy=proxy}
  return proxy
end
term.redirect(capture(term.current(),'terminal'))
local originalWrap=peripheral.wrap
peripheral.wrap=function(name)
  local p=originalWrap(name)
  if p and peripheral.hasType(name,'monitor') then return capture(p,name) end
  return p
end
local originalFind=peripheral.find
peripheral.find=function(kind,filter)
  if kind~='monitor' then return originalFind(kind,filter) end
  local all={}
  for _,name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name,kind) then
      local p=peripheral.wrap(name)
      if not filter or filter(name,p) then all[#all+1]=p end
    end
  end
  return table.unpack(all)
end
fs.makeDir('/.gateb/in');fs.makeDir('/.gateb/out')
local function snapshot()
  local out={at=os.epoch('utc'),boot_id=bootId,uptime=os.clock(),monitors={},frame=env.GATEB_FRAME}
  for name,s in pairs(screens) do
    local w,h=s.win.getSize();local t={width=w,height=h,lines={},at=out.at}
    for y=1,h do local a,b,c=s.win.getLine(y);t.lines[y]={text=a,fg=b,bg=c} end
    if name=='terminal' then out.terminal=t else out.monitors[name]=t end
  end
  write('/.gateb/screen.json',out)
end
local function inputs()
  local ok,names=pcall(fs.list,'/.gateb/in')
  if ok then return names end
  fs.makeDir('/.gateb/in');return {}
end
local function bridge()
  while true do
    if fs.exists('/.gateb/disabled') then
      for _,name in ipairs(inputs()) do fs.delete('/.gateb/in/'..name) end
      os.pullEventRaw('gateb_enable')
    end
    for _,name in ipairs(inputs()) do
      if name:match('%.json$') then
        local raw=read('/.gateb/in/'..name);fs.delete('/.gateb/in/'..name)
        local q=textutils.unserializeJSON(raw or '')
        local ok,result=pcall(function()
          if q.op=='input' then
            os.queueEvent(q.event,table.unpack(q.args or {}));return {queued=true}
          elseif q.op=='lua_async' then
            nextJob=nextJob+1;local id=tostring(nextJob)..'-'..tostring(os.epoch('utc'))
            jobs[id]={state='queued',code=q.code};pending[#pending+1]=id
            os.queueEvent('gateb_job');return {job=id}
          elseif q.op=='lua_job' then
            local job=assert(jobs[q.job],'Unknown Lua job')
            return {job=q.job,state=job.state,values=job.values,error=job.error}
          elseif q.op=='lua_cancel' then
            local job=assert(jobs[q.job],'Unknown Lua job');job.cancel=true
            return {job=q.job,cancelling=true}
          elseif q.op=='lua' then
            local fn=assert(load(q.code,'gateb-request','t',env))
            local values=table.pack(fn());values.n=nil;return {values=values}
          elseif q.op=='power' then
            write('/.gateb/out/'..name,{ok=true,result={action=q.action,computer=os.getComputerID()}})
            if q.action=='off' then os.shutdown() else os.reboot() end
          end
          error('Unknown bridge operation')
        end)
        write('/.gateb/out/'..name,{ok=ok,result=ok and result or nil,error=not ok and tostring(result) or nil})
      end
    end
    snapshot();sleep(.1)
  end
end
local function executor()
  while true do
    if #pending==0 then os.pullEventRaw('gateb_job') end
    while #pending>0 do
      local id=table.remove(pending,1);local job=jobs[id];job.state='running'
      local fn,why=load(job.code,'gateb-async','t',env)
      if not fn then job.state='failed';job.error=why
      else
        local co=coroutine.create(fn);local event={};local filter
        while true do
          local result=table.pack(coroutine.resume(co,table.unpack(event)))
          if not result[1] then job.state='failed';job.error=tostring(result[2]);break end
          if coroutine.status(co)=='dead' then
            job.state='done';job.values={};for i=2,result.n do job.values[i-1]=result[i] end;break
          end
          filter=result[2]
          repeat
            event=table.pack(os.pullEventRaw())
            if job.cancel then event={'terminate'};break end
          until not filter or event[1]==filter or event[1]=='terminate'
        end
      end
      job.code=nil
    end
  end
end
local function frames()
  while true do
    local _,sender,packet,protocol=os.pullEvent('rednet_message')
    if protocol=='so' and role=='display' then
      local ok=pcall(function()
        local proto=dofile('/so-proto.lua');local pair=dofile('/so-pair.lua')
        pair.open(proto,dofile('/so-store.lua'))
        local m=proto.decode(packet);local key=pair.key(sender)
        if m and key and m.t=='view.frame' and proto.macOk(key,m) then env.GATEB_FRAME=m.body end
      end)
    end
  end
end
parallel.waitForAny(function()
  local fn,why=loadfile('/'..assert(programs[role]),env)
  assert(fn,why);fn();while true do sleep(1) end
end,bridge,frames,executor)
