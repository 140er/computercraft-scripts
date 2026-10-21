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
        local disk=A.mount("/")
        local map=disk:open("ssot.map",function(v) return type(v)=="table" end,{class="bulk",limit=900000,anchor="ssot.control"})
        local chunks,cells,bytes=0,0,0
        for _,ch in pairs((map.value and map.value.chunks) or {}) do
          chunks=chunks+1
          for _ in pairs(ch.cells or {}) do cells=cells+1 end
        end
        -- compactSections clears ssot.map chunks and keeps the cells in map/.
        if chunks==0 and fs.exists("map/index") then
          local Section=dofile("mapsection.lua")
          local index=assert(fs.open("map/index","r"))
          local text=index.readAll() index.close()
          local lines={}
          for line in (text.."\n"):gmatch("([^\n]*)\n") do lines[#lines+1]=line end
          if lines[#lines]=="" then lines[#lines]=nil end
          local count=lines[1]=="CCS2IDX" and tonumber(lines[4]) or 0
          for n=1,count do
            local row=lines[4+n]
            local id,slot
            if row then id,slot=row:match("^[^\t]+\t(%d+)\t([ab])\t") end
            local file=id and fs.open("map/"..slot.."/"..id,"rb")
            if file then
              local raw=file.readAll() file.close()
              local section=Section.decode(raw)
              if section then
                chunks=chunks+1
                for _,run in ipairs(section.runs) do cells=cells+run.n end
              end
            end
          end
        end
        for _,slot in ipairs({"ssot.map.a","ssot.map.b","ssot.control.a","ssot.control.b"}) do
          if fs.exists(slot) then bytes=bytes+fs.getSize(slot) end
        end
        local available,heap=pcall(function() return collectgarbage("count") end)
        rednet.send(4,{kind="metrics",rid=m.rid,cells=cells,chunks=chunks,bytes=bytes,
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
        local control = A.mount("/"):open("ssot.control",function(v) return type(v) == "table" end,{class="control",limit=32768})
        assert(next((control.value and control.value.moves) or {}) == nil,"unreconciled reservations")
        local h=assert(fs.open("sandbox-result.json","w"))
        h.write(textutils.serializeJSON({ok=true,booted=true,errors={},lines={"server restart and cleanup passed"}})) h.close()
      end
    end
  end
end)
if not ok and err=="ssot sandbox restart" then return "restart" end
if not ok then
  local h=assert(fs.open("sandbox-result.json","w"))
  h.write(textutils.serializeJSON({ok=false,errors={tostring(err)}})) h.close()
  error(err,0)
end
