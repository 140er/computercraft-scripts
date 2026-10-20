local M = {}
function M.idle()
  local selected, heading = 1, 0
  return {
    select = function(slot) selected = slot return true end,
    getSelectedSlot = function() return selected end,
    getFuelLevel = function() return "unlimited" end,
    getFuelLimit = function() return 100000 end,
    getItemCount = function(slot) return (slot or selected) == 1 and 1 or 0 end,
    getItemDetail = function(slot)
      if (slot or selected) == 1 then return { name = "minecraft:bucket", count = 1 } end
    end,
    refuel = function() return false end,
    turnRight = function() heading = (heading + 1) % 4 return true end,
    turnLeft = function() heading = (heading + 3) % 4 return true end,
    inspect = function()
      if heading == 2 then return true, { name = "minecraft:chest" } end
      return false, "No block to inspect"
    end,
    suck = function() return false end,
    drop = function() return true end,
  }
end
function M.new(call)
  local api = {}
  for _, op in ipairs({ "forward", "back", "up", "down", "turnLeft", "turnRight", "dig", "digUp", "digDown",
    "detect", "detectUp", "detectDown", "inspect", "inspectUp", "inspectDown", "getFuelLevel", "getFuelLimit",
    "refuel", "select", "getSelectedSlot", "getItemCount", "getItemDetail", "suck", "drop" }) do
    api[op] = function(...) return table.unpack(call(op, { ... })) end
  end
  return api
end
function M.world(saved,scenario)
  local poses = saved and saved.poses or { [1] = {x=-2,y=65,z=0,h=1,fuel=10000}, [2] = {x=0,y=65,z=-2,h=2,fuel=10000},
    [3] = {x=2,y=65,z=0,h=3,fuel=10000} }
  local blocks, timeline, collisions, failures = { ["-1,65,0"]="minecraft:stone",["-2,65,-1"]="minecraft:stone",["3,66,0"]="minecraft:chest",["2,67,0"]="minecraft:water",["2,66,-1"]="minecraft:bedrock" }, {}, 0, {}
  if saved then blocks,timeline,collisions=saved.blocks,saved.timeline,saved.collisions end
  if not saved and scenario=="mining" then
    blocks={}
    for _,p in ipairs(dofile("mining-fixture.lua").blocks) do blocks[p.x..","..p.y..","..p.z]=p.name end
    for id=1,3 do poses[id]={x=id*4-3,y=65,z=0,h=2,fuel=id==2 and 42 or 10000,inventory={}} end
  end
  local function key(p) return p.x .. "," .. p.y .. "," .. p.z end
  local function target(p, op)
    local q = {x=p.x,y=p.y,z=p.z}
    if op:find("Up") or op == "up" then q.y = q.y + 1
    elseif op:find("Down") or op == "down" then q.y = q.y - 1
    else
      local sign = op == "back" and -1 or 1
      q.x = q.x + ({[0]=0,1,0,-1})[p.h] * sign
      q.z = q.z + ({[0]=-1,0,1,0})[p.h] * sign
    end
    return q
  end
  return {
    state = function() return {poses=poses,blocks=blocks,timeline=timeline,collisions=collisions} end,
    handle = function(id, op, args)
      if id == 4 and op == "fault" then failures[args[1]] = true return {true} end
      if id==3 and op=="clear-fluid" then blocks["2,67,0"]=nil return {true} end
      local p = assert(poses[id], "unknown turtle")
      if scenario=="mining" then
        p.inventory=p.inventory or {}
        if op=="inventory-full" then
          p.injected={}
          for i=1,16 do if not p.inventory[i] then p.inventory[i]={name="minecraft:stone",count=64} p.injected[i]=true end end
          return {true}
        end
        if op=="inventory-clear" then for i in pairs(p.injected or {}) do p.inventory[i]=nil end p.injected=nil return {true} end
        if op=="fuel-refill" then p.fuel=p.fuel+80 return {true} end
      end
      if op == "pose" then return {p.x,p.y,p.z,p.h} end
      if op == "getFuelLevel" then return {p.fuel} end
      if op == "getFuelLimit" then return {100000} end
      if op == "getSelectedSlot" then return {p.selected or 1} end
      if op == "select" then p.selected = args[1] return {true} end
      if op == "getItemCount" then return {p.inventory and p.inventory[args[1] or p.selected or 1] and p.inventory[args[1] or p.selected or 1].count or 0} end
      if op == "getItemDetail" then return {p.inventory and p.inventory[args[1] or p.selected or 1]} end
      if op == "refuel" or op == "suck" or op == "drop" then return {false} end
      if op == "turnLeft" or op == "turnRight" then
        p.h = (p.h + (op == "turnLeft" and 3 or 1)) % 4 return {true}
      end
      local q = target(p, op)
      local block = blocks[key(q)]
      if op:find("inspect") then return block and {true,{name=block}} or {false,"No block to inspect"} end
      if op:find("detect") then return {block ~= nil} end
      if op:find("dig") then
        if block=="minecraft:bedrock" then return {false} end
        blocks[key(q)] = nil
        if block and p.inventory then
          for i=1,16 do
            local v=p.inventory[i]
            if not v or v.name==block and v.count<64 then
              p.inventory[i]={name=block,count=(v and v.count or 0)+1} break
            end
          end
        end
        return {block ~= nil}
      end
      if failures[id] then failures[id] = nil return {false,"Injected move failure"} end
      if p.fuel <= 0 then return {false,"Out of fuel"} end
      if block then return {false,"Movement obstructed"} end
      for other, at in pairs(poses) do
        if other ~= id and key(at) == key(q) then collisions = collisions + 1 return {false,"Turtle occupancy"} end
      end
      p.x,p.y,p.z,p.fuel = q.x,q.y,q.z,p.fuel-1
      timeline[#timeline+1] = {id=id,x=p.x,y=p.y,z=p.z,at=os.epoch("utc")}
      return {true}
    end,
  }
end
return M
