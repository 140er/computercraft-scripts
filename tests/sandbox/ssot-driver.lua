local scenario=...
local id = os.getComputerID()
assert(config.get("standardsMode") and fs.getCapacity("/") == 4000000)
if not peripheral.isPresent("left") then assert(periphemu.create("left", "modem", 1)) end
local call = peripheral.call
peripheral.call = function(name,method,...)
  if name == "left" and method == "isWireless" then return true end
  return call(name,method,...)
end
rednet.open("left")
http = nil
_G.http = nil
os.reboot = function() error("ssot sandbox restart",0) end
local function program(path,...)
  while true do
    assert(assert(loadfile(path,"t",_ENV))(... )=="restart","test program stopped")
    sleep(0)
  end
end
local function report(value)
  local h = assert(fs.open("sandbox-result.json","w")) h.write(textutils.serializeJSON(value)) h.close()
end
if id == 0 then
  for peer=1,5 do
    local name="computer_" .. peer
    if not peripheral.isPresent(name) then
      assert(periphemu.create(tostring(peer),"computer"))
      local from = rednet.receive("ssot_boot",30)
      assert(from==peer,"computer did not finish BIOS startup: " .. peer)
      sleep(1)
    else peripheral.call(name,"turnOn") end
  end
  program("test-server.lua")
elseif id == 5 then
  rednet.send(0,true,"ssot_boot")
  local A=dofile("atomic.lua")
  local store=A.store("world.state",function(v) return type(v)=="table" and type(v.poses)=="table" end)
  local world = dofile("turtle.lua").world(store.value)
  local results,order={},{}
  while true do
    local from,m,proto = rednet.receive()
    if proto == "ssot_world" then
      if m.op == "done" and from == 4 then
        local state = world.state()
        local h = fs.open("world.json","w") h.write(textutils.serializeJSON(state)) h.close()
        report({ok=state.collisions==0,booted=true,errors={},lines={"physical occupancy checked"},moves=#state.timeline})
      else
        local key=from .. ":" .. m.rid
        local values=results[key]
        if not values then
          values=world.handle(from,m.op,m.args)
          if m.op~="pose" and not m.op:match("^get") and not m.op:match("^inspect") and not m.op:match("^detect") then
            assert(store.save(world.state()))
          end
          results[key]=values order[#order+1]=key
          while #order>128 do results[table.remove(order,1)]=nil end
        end
        rednet.send(from,{rid=m.rid,values=values},"ssot_world_reply")
      end
    end
  end
else
  rednet.send(0,true,"ssot_boot")
  program("ssot-runtime.lua","sandbox",scenario)
end
