http = nil
_G.http = nil
local devices={}
for _,name in ipairs(peripheral.getNames()) do devices[name]=peripheral.getType(name) end
local d=assert(fs.open("devices.txt","w")) d.write(textutils.serialize(devices)) d.close()
local ok,err=pcall(parallel.waitForAny,function()
  assert(loadfile("server.lua","t",_ENV))()
  error("server stopped")
end,function()
  while true do
    local from,m,proto = rednet.receive("ssot_test")
    if from == 4 and type(m) == "table" then
      if m.action == "reboot" then os.reboot() end
      if m.action == "metrics" then
        local A=dofile("atomic.lua")
        local store=A.store("ssot.state",function(v) return type(v)=="table" and v.schema==1 end)
        local chunks,cells=0,0
        for _,ch in pairs(store.value.chunks) do
          chunks=chunks+1
          for _ in pairs(ch.cells) do cells=cells+1 end
        end
        local available,heap=pcall(function() return collectgarbage("count") end)
        rednet.send(4,{kind="metrics",cells=cells,chunks=chunks,bytes=fs.getSize("ssot.state"),
          free=fs.getFreeSpace("/"),capacity=fs.getCapacity("/"),luaHeapAvailable=available,luaHeapKiB=available and heap or false},"ssot_test")
      end
      if m.action == "fill" then
        local remaining=fs.getFreeSpace("/")-16384
        local h=assert(fs.open("disk-fill","w"))
        while remaining>0 do
          local n=math.min(8192,remaining)
          h.write(string.rep("x",n)) remaining=remaining-n
          sleep(0)
        end
        h.close()
        rednet.send(4,{kind="filled",free=fs.getFreeSpace("/")},"ssot_test")
      end
      if m.action == "clear-and-reboot" then
        fs.delete("disk-fill")
        os.reboot()
      end
      if m.action == "done" then
        local A = dofile("atomic.lua")
        local store = A.store("ssot.state",function(v) return type(v) == "table" and v.schema == 1 end)
        assert(next(store.value.moves) == nil,"unreconciled reservations")
        local h=assert(fs.open("sandbox-result.json","w"))
        h.write(textutils.serializeJSON({ok=true,booted=true,errors={},lines={"server restart and cleanup passed"}})) h.close()
      end
    end
  end
end)
if not ok then
  local h=assert(fs.open("sandbox-result.json","w"))
  h.write(textutils.serializeJSON({ok=false,errors={tostring(err)}})) h.close()
end
