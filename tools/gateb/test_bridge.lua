local encode = dofile('tests/mocks.lua').encode
local files, directories, events = {['/.so-role']='server'}, {}, {}
local function decode(raw) return assert(load('return '..raw,'json','t',{}))() end
local fs = {}
fs.open=function(path,mode)
  if mode=='r' then
    if not files[path] then return nil end
    return {readAll=function() return files[path] end,close=function() end}
  end
  local value=''
  return {write=function(text) value=value..text end,close=function() files[path]=value end}
end
fs.exists=function(path) return files[path]~=nil or directories[path] end
fs.makeDir=function(path) directories[path]=true end
fs.delete=function(path) files[path]=nil;directories[path]=nil end
fs.move=function(a,b) files[b]=assert(files[a]);files[a]=nil end
fs.list=function(path)
  local result={}
  for name in pairs(files) do
    local suffix=name:match('^'..path..'/(.+)$')
    if suffix and not suffix:find('/') then result[#result+1]=suffix end
  end
  table.sort(result);return result
end
local env=setmetatable({}, {__index=_G})
env.fs=fs
env.textutils={serializeJSON=encode,unserializeJSON=decode}
local current={getSize=function() return 5,1 end}
local line={'     ','00000','fffff'}
env.window={create=function()
  return {getSize=function() return 5,1 end,getLine=function() return table.unpack(line) end,
    write=function(text) line={text..string.rep(' ',5-#text),'00000','fffff'} end}
end}
env.term={current=function() return current end,redirect=function(value) current=value end,write=function(text) current.write(text) end}
env.peripheral={wrap=function() end,find=function() end,getNames=function() return {} end}
local now=0
local function pull(filter)
  local event=table.pack(coroutine.yield(filter))
  return table.unpack(event,1,event.n)
end
env.os={epoch=function() return now end,getComputerID=function() return 1 end,
  queueEvent=function(...) events[#events+1]=table.pack(...) end,
  pullEventRaw=pull,pullEvent=function(filter)
    local event=table.pack(pull(filter))
    if event[1]=='terminate' then error('Terminated',0) end
    return table.unpack(event,1,event.n)
  end}
env.sleep=function() pull('timer') end
env.loadfile=function(path,roleEnv)
  assert(path=='/so-server.lua')
  return assert(load('SO={marker="role-global"};term.write("ready");while true do os.pullEvent() end',path,'t',roleEnv))
end
local function request(id,q) files['/.gateb/in/'..id..'.json']=encode(q) end
local function response(id)
  local raw=assert(files['/.gateb/out/'..id..'.json'],'No response for '..id)
  return decode(raw)
end
env.parallel={waitForAny=function(...)
  local coroutines,filters={},{ }
  for i,fn in ipairs({...}) do
    coroutines[i]=coroutine.create(fn)
    local ok,filter=coroutine.resume(coroutines[i]);assert(ok,filter);filters[i]=filter
  end
  local async,cancel
  for tick=1,25 do
    if tick==1 then request('sync',{op='lua',code='return SO.marker'}) end
    if tick==2 then
      assert(response('sync').result.values[1]=='role-global')
      request('async',{op='lua_async',code='local _,v=os.pullEvent("external");return SO.marker..v'})
    end
    if tick==3 then async=response('async').result.job;request('status',{op='lua_job',job=async}) end
    if tick==4 then assert(response('status').result.state=='running');env.os.queueEvent('external','-done') end
    if tick==5 then request('done',{op='lua_job',job=async}) end
    if tick==6 then
      local result=response('done').result;assert(result.state=='done');assert(result.values[1]=='role-global-done')
      request('wait',{op='lua_async',code='os.pullEvent("never")'})
    end
    if tick==7 then cancel=response('wait').result.job;request('cancel',{op='lua_cancel',job=cancel}) end
    if tick==10 then request('failed',{op='lua_job',job=cancel}) end
    if tick==11 then
      local result=response('failed').result
      assert(result.state=='failed' and result.error:find('Terminated'))
      local snapshot=decode(assert(files['/.gateb/screen.json']))
      assert(snapshot.terminal.lines[1].text=='ready')
      assert(snapshot.terminal.lines[1].fg=='00000')
      return
    end
    events[#events+1]={'timer',tick};now=tick*100
    while #events>0 do
      local event=table.remove(events,1)
      for i,co in ipairs(coroutines) do
        if not filters[i] or filters[i]==event[1] or event[1]=='terminate' then
          local ok,filter=coroutine.resume(co,table.unpack(event));assert(ok,filter)
          assert(coroutine.status(co)~='dead','Bridge coroutine stopped')
          filters[i]=filter
        end
      end
    end
  end
  error('Bridge checks did not complete')
end}
assert(loadfile('tools/gateb/bridge.lua','t',env))()
print('PASS bridge role globals, terminal colours, asynchronous progress and cancellation')
