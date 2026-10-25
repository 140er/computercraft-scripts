-- Test instrumentation persists observations across the worker's native reboot.
local env=_ENV
local function read(path)
  local h=fs.open(path,'r');if not h then return nil end
  local s=h.readAll();h.close();return s
end
local function save(value)
  local h=assert(fs.open('/.gateb/c16-trace.json','w'))
  h.write(textutils.serializeJSON(value));h.close()
end
local trace=textutils.unserializeJSON(read('/.gateb/c16-trace.json') or '{}')
trace.events=trace.events or {}
trace.boots=(trace.boots or 0)+1
local boot=trace.boots
local function event(kind,body)
  body=body or {};body.kind=kind;body.boot=boot;body.at=os.epoch('utc')
  trace.events[#trace.events+1]=body;save(trace)
end
save(trace)
local baseRednet=rednet
env.rednet=setmetatable({}, {__index=baseRednet})
env.rednet.send=function(id,wire,protocol)
  local proto=dofile('/so-proto.lua')
  local msg=protocol=='so' and proto.decode(wire)
  if msg and (msg.t=='hello' or msg.body and msg.body.command=='worker.update') then
    event(msg.t,{revision=msg.body.revision,state=msg.body.state,text=msg.body.text,
      rid=msg.rid,command=msg.body.command})
  end
  return baseRednet.send(id,wire,protocol)
end
local baseHTTP=http
env.http=setmetatable({}, {__index=baseHTTP})
env.http.get=function(url,...)
  local address=type(url)=='table' and url.url or url
  if address:match('^https://api%.github%.com/') then
    local remaining=tonumber(read('/.gateb/c16-fake-remaining'))
    if remaining then
      event('fake_budget',{remaining=remaining,url=address})
      return {getResponseCode=function() return 403 end,readAll=function() return '{}' end,
        getResponseHeaders=function() return {['x-ratelimit-remaining']=tostring(remaining),
          ['retry-after']='60'} end,close=function() end}
    end
    event('api',{url=address})
  end
  return baseHTTP.get(url,...)
end
local baseLoadfile=loadfile
env.loadfile=function(path,mode,environment)
  local fn,why=baseLoadfile(path,mode,environment or _ENV)
  if path=='/install.lua' and fn then
    return function(...)
      if (...)=='worker-update' then event('handoff',{revision=select(2,...),running=select(3,...)}) end
      return fn(...)
    end
  end
  return fn,why
end
local baseOS=os
env.os=setmetatable({}, {__index=baseOS})
env.os.reboot=function()
  local lines={};local _,height=term.getSize()
  -- The bridge redirects the terminal to a window with getLine.
  local screen=term.current()
  for y=1,height do
    local text=screen.getLine(y);lines[#lines+1]={text=text}
  end
  event('reboot',{terminal={lines=lines}})
  -- The installed startup is product output. Restore only the test entrypoint
  -- so the bridge can observe the next real boot without a host power command.
  local h=assert(fs.open('/startup.lua','w'))
  h.write('if shell.run("/install.lua", "recover") then shell.run("/gateb-bridge.lua") end\n');h.close()
  return baseOS.reboot()
end
