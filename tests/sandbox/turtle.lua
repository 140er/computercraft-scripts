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
function M.world(saved)
  local poses = saved and saved.poses or { [1] = {x=-2,y=65,z=0,h=1,fuel=10000}, [2] = {x=0,y=65,z=-2,h=2,fuel=10000},
    [3] = {x=2,y=65,z=0,h=3,fuel=10000} }
  local blocks, timeline, collisions, failures = { ["-1,65,0"]="minecraft:stone",["-2,65,-1"]="minecraft:stone" }, {}, 0, {}
  if saved then blocks,timeline,collisions=saved.blocks,saved.timeline,saved.collisions end
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
      local p = assert(poses[id], "unknown turtle")
      if op == "pose" then return {p.x,p.y,p.z,p.h} end
      if op == "getFuelLevel" then return {p.fuel} end
      if op == "getFuelLimit" then return {100000} end
      if op == "getSelectedSlot" then return {p.selected or 1} end
      if op == "select" then p.selected = args[1] return {true} end
      if op == "getItemCount" then return {0} end
      if op == "getItemDetail" then return {} end
      if op == "refuel" or op == "suck" or op == "drop" then return {false} end
      if op == "turnLeft" or op == "turnRight" then
        p.h = (p.h + (op == "turnLeft" and 3 or 1)) % 4 return {true}
      end
      local q = target(p, op)
      local block = blocks[key(q)]
      if op:find("inspect") then return block and {true,{name=block}} or {false,"No block to inspect"} end
      if op:find("detect") then return {block ~= nil} end
      if op:find("dig") then blocks[key(q)] = nil return {block ~= nil} end
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
