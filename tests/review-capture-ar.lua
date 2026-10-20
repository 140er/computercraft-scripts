local F = dofile("tests/ar-fixture.lua")
local m = F.install(true)
local H = dofile("ar-hud.lua")
local cfg = H.defaults()
cfg.enabled=true
cfg.origin={x=0,y=64,z=0,dim="minecraft:overworld"}
cfg.xrayTunnels=true
assert(H.render(m.ar,F.snapshot(),{},cfg) ~= false)
local h=assert(fs.open("ar-calls.json","w"))
h.write(textutils.serializeJSON(m.arCalls)) h.close()
sleep(1)
term.screenshot()
sleep(1)
os.shutdown()
