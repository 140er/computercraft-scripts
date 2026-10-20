local Fleet=dofile("wh2-fleet.lua")
local values=Fleet.defaults()
values.enabled,values.navigation,values.mining=true,true,true
values.autoCharge,values.autoDropoff=true,true
local client={call=function(op,body)
  assert(op=="wh2-get" and body.topic=="settings")
  return {ok=true,revision=4,cursor=0,records={{id="defaults",revision=4,effective=values}}}
end}
local dev=dofile("wh2-dev.lua").open({client=client})
dev.tick()
dev.draw()
sleep(1)
term.screenshot()
sleep(1)
os.shutdown()
