local h=assert(fs.open("probe-mode","r")) local mode=h.readAll() h.close()
local before=turtle.getFuelLevel()
local initial=before
if mode=="unload" or mode=="interruption" then
  sleep(3)
  local f=assert(fs.open(mode.."-ready.json","w")) f.write(textutils.serializeJSON({initial=initial,warm=turtle.getFuelLevel()})) f.close()
  while not fs.exists(mode.."-go") do
    if mode=="unload" then
      local h=assert(fs.open("unload-heartbeat.json","w")) h.write(textutils.serializeJSON({at=os.epoch("utc")})) h.close()
    end
    sleep(.25)
  end
  before=turtle.getFuelLevel()
end
if mode=="loader" or mode=="capture" then
  local f=assert(fs.open(mode.."-ready.json","w")) f.write(textutils.serializeJSON({ok=true,fuel=before})) f.close()
  while not fs.exists(mode.."-go") do sleep(.1) end
  assert(turtle.forward())
end
local samples={{at=os.epoch("utc"),fuel=before}}
for _=1,12 do sleep(.5) samples[#samples+1]={at=os.epoch("utc"),fuel=turtle.getFuelLevel()} end
local f=assert(fs.open("charge-"..mode..".json","w"))
f.write(textutils.serializeJSON({mode=mode,initial=initial,before=before,after=turtle.getFuelLevel(),samples=samples})) f.close()
while true do sleep(1) end
