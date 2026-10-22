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
local programs={server='so-server.lua',worker='worker.lua',display='display.lua'}
local env=setmetatable({}, {__index=_ENV})
env._G=env
local screens={}
local function capture(base,name)
  if screens[name] then return screens[name].proxy end
  local w,h=base.getSize()
  local win=window.create(base,1,1,w,h,true)
  local proxy={}
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
  local out={at=os.epoch('utc'),monitors={},frame=env.GATEB_FRAME}
  for name,s in pairs(screens) do
    local w,h=s.win.getSize();local t={width=w,height=h,lines={},at=out.at}
    for y=1,h do local a,b,c=s.win.getLine(y);t.lines[y]={text=a,fg=b,bg=c} end
    if name=='terminal' then out.terminal=t else out.monitors[name]=t end
  end
  write('/.gateb/screen.json',out)
end
local function bridge()
  while true do
    if fs.exists('/.gateb/disabled') then
      for _,name in ipairs(fs.list('/.gateb/in')) do fs.delete('/.gateb/in/'..name) end
      os.pullEventRaw('gateb_enable')
    end
    for _,name in ipairs(fs.list('/.gateb/in')) do
      if name:match('%.json$') then
        local raw=read('/.gateb/in/'..name);fs.delete('/.gateb/in/'..name)
        local q=textutils.unserializeJSON(raw or '')
        local ok,result=pcall(function()
          if q.op=='input' then
            os.queueEvent(q.event,table.unpack(q.args or {}));return {queued=true}
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
end,bridge,frames)
