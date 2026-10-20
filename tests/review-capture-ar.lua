local loadModule = dofile
dofile = function(path)
  sleep(0)
  return loadModule(path)
end
local F = dofile("tests/ar-fixture.lua")
local m = F.install(true)
local H = dofile("ar-hud.lua")
dofile = loadModule
local cfg = H.defaults()
cfg.enabled=true
cfg.origin={x=0,y=64,z=0,dim="minecraft:overworld"}
cfg.xrayTunnels=true
cfg.ownerName,cfg.ownerUUID="Jeffreyy2","00000000-0000-4000-8000-000000000001"
local auth={chatNames={cfg.ownerName},chatUUIDs={[cfg.ownerName]=cfg.ownerUUID}}
assert(H.render(m.ar,F.snapshot(),{},cfg,auth) ~= false)
local h=assert(fs.open("ar-calls.json","w"))
h.write(textutils.serializeJSON(m.arCalls)) h.close()
sleep(1)
term.screenshot()
sleep(1)
os.shutdown()
