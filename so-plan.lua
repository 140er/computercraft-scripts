local P = {}
local dx = { [0] = 0, 1, 0, -1 }
local dz = { [0] = -1, 0, 1, 0 }

local function copy(p)
  local out = {}
  for k, v in pairs(p) do out[k] = v end
  return out
end

local function facing(p)
  return p.facing or p.f or 0
end

local function rotate(x, z, rot)
  if rot == 1 then return -z, x end
  if rot == 2 then return -x, -z end
  if rot == 3 then return z, -x end
  return x, z
end

function P.frame(worldPose, journalPose)
  local rot = (worldPose.facing - journalPose.f) % 4
  local x, z = rotate(journalPose.x, journalPose.z, rot)
  return {
    dim = worldPose.dim, rot = rot,
    ox = worldPose.x - x, oy = worldPose.y - journalPose.y, oz = worldPose.z - z,
  }
end

function P.toWorld(frame, pose)
  local x, z = rotate(pose.x, pose.z, frame.rot)
  return {
    dim = frame.dim, x = x + frame.ox, y = pose.y + frame.oy, z = z + frame.oz,
    facing = (pose.f + frame.rot) % 4,
  }
end

function P.toJournal(frame, pose)
  local x, z = rotate(pose.x - frame.ox, pose.z - frame.oz, (4 - frame.rot) % 4)
  return { x = x, y = pose.y - frame.oy, z = z, f = (pose.facing - frame.rot) % 4 }
end

function P.ahead(pose, dir)
  if dir == "up" then return pose.x, pose.y + 1, pose.z end
  if dir == "down" then return pose.x, pose.y - 1, pose.z end
  local f = facing(pose)
  if dir == "back" then f = (f + 2) % 4 end
  return pose.x + dx[f], pose.y, pose.z + dz[f]
end

function P.apply(pose, op)
  local p = copy(pose)
  if op == "turnLeft" or op == "turnRight" then
    local f = (facing(p) + (op == "turnLeft" and 3 or 1)) % 4
    if p.facing ~= nil then p.facing = f else p.f = f end
  elseif op == "forward" or op == "back" or op == "up" or op == "down" then
    p.x, p.y, p.z = P.ahead(p, op)
  end
  return p
end

function P.replay(startPose, steps, results)
  local pose = copy(startPose)
  for i, step in ipairs(steps) do
    if results[i] and results[i].ok then pose = P.apply(pose, step.op) end
  end
  return pose
end

function P.path(from, to, opts)
  opts = opts or {}
  local out = { steps = {}, cells = {}, pose = copy(from) }
  local function step(op)
    out.steps[#out.steps + 1] = { op = op }
    out.pose = P.apply(out.pose, op)
  end
  local function turn(want)
    local delta = (want - facing(out.pose)) % 4
    if delta == 3 then step("turnLeft") else
      for _ = 1, delta do step("turnRight") end
    end
  end
  local order = opts.order or "yxz"
  assert(#order == 3 and order:find("x") and order:find("y") and order:find("z"), "axis order")
  for axis in order:gmatch(".") do
    local diff = to[axis] - out.pose[axis]
    local op, dig = "forward", "dig"
    if axis == "y" then
      op, dig = diff > 0 and "up" or "down", diff > 0 and "digUp" or "digDown"
    elseif diff ~= 0 then
      if axis == "x" then turn(diff > 0 and 1 or 3) else turn(diff > 0 and 2 or 0) end
    end
    for _ = 1, math.abs(diff) do
      if opts.dig then step(dig) end
      step(op)
      local p = out.pose
      out.cells[#out.cells + 1] = { dim = p.dim, x = p.x, y = p.y, z = p.z }
    end
  end
  return out
end

function P.chunk(steps, n)
  local first, rest = {}, {}
  for i, step in ipairs(steps) do
    local dest = i <= n and first or rest
    dest[#dest + 1] = step
  end
  return first, rest
end

function P.inRange(lease, id, cells)
  if type(lease) ~= "table" or type(lease.inRange) ~= "function" then return true end
  for _, cell in ipairs(cells) do
    if not lease.inRange(id, cell) then return false end
  end
  return true
end

function P.rangeBatch(lease, id, action)
  if P.inRange(lease, id, action.cells or {}) then return action end
  local out = { kind = "batch", steps = {}, cells = {}, actions = {} }
  for _, part in ipairs(action.actions or {}) do
    if not P.inRange(lease, id, part.cells or {}) then break end
    out.actions[#out.actions + 1] = part
    for _, step in ipairs(part.steps) do out.steps[#out.steps + 1] = step end
    for _, cell in ipairs(part.cells or {}) do out.cells[#out.cells + 1] = cell end
    out.pose = part.pose
  end
  if #out.steps > 0 then return out end
end

P.park = { steps = { { op = "inspectDown" } }, ms = 600000 }

function P.fuelValue(name)
  local fuels = {
    ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
    ["minecraft:lava_bucket"] = 1000, ["minecraft:blaze_rod"] = 120,
  }
  return fuels[name] or 0
end

function P.free(inv)
  local occupied = {}
  for _, item in ipairs(inv) do
    if type(item.slot) == "number" and item.slot >= 1 and item.slot <= 16
      and item.slot % 1 == 0 and type(item.count) == "number" and item.count > 0 then
      occupied[item.slot] = true
    end
  end
  local n = 16
  for _ in pairs(occupied) do n = n - 1 end
  return n
end

return P
