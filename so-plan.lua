local P = {}
P.dimensions = {
  ["minecraft:overworld"] = { drop = 0 },
  ["minecraft:the_nether"] = { drop = -1, min = 1, max = 126, bottom = 15 },
  ["minecraft:the_end"] = { drop = 1, min = 1, max = 255, bottom = 48 },
}
function P.dimension(name)
  return ({overworld="minecraft:overworld", nether="minecraft:the_nether", the_nether="minecraft:the_nether",
    ["end"]="minecraft:the_end", the_end="minecraft:the_end"})[name] or (P.dimensions[name] and name)
end
function P.dimensionError(dim, config)
  if not P.dimensions[dim] then return "invalid dimension" end
  if dim ~= "minecraft:overworld" and not (type(config) == "table" and config.remoteDimensions == true) then
    return "remote dimensions disabled"
  end
end
function P.heightError(dim, y)
  local rule = P.dimensions[dim]
  if not rule then return "invalid dimension" end
  if rule.min and (y < rule.min or y > rule.max) then
    return dim == "minecraft:the_nether" and "Nether bedrock boundary" or "End void or height boundary"
  end
end
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

P.moves = { forward = true, back = true, up = true, down = true }
P.turns = { turnLeft = true, turnRight = true }
P.digs = { dig = "forward", digUp = "up", digDown = "down" }

function P.membership(p, boxes)
  local found = {}
  for _, box in ipairs(boxes) do
    if p.dim == box.dim and p.x >= box.x1 and p.x <= box.x2 and p.y >= box.y1 and p.y <= box.y2
      and p.z >= box.z1 and p.z <= box.z2 then found[box.id] = true end
  end
  return found
end

function P.samePose(a, b)
  return a and b and a.dim == b.dim and a.x == b.x and a.y == b.y and a.z == b.z
    and facing(a) == facing(b)
end

function P.boundary(action)
  local out, at, n = copy(action), action.from, #action.steps
  for i, step in ipairs(action.steps) do
    if P.moves[step.op] or P.turns[step.op] then n = i break end
  end
  out.steps, out.rest = P.chunk(action.steps, n)
  out.cells, out.actions = {}, action.actions and {} or nil
  for _, step in ipairs(out.steps) do
    if at then
      if P.digs[step.op] then
        local x, y, z = P.ahead(at, P.digs[step.op])
        out.cells[#out.cells + 1] = { dim = at.dim, x = x, y = y, z = z }
      end
      at = P.apply(at, step.op)
      if P.moves[step.op] then out.cells[#out.cells + 1] = at end
    end
  end
  if n == #action.steps and action.cells then out.cells = action.cells end
  if at then out.pose = at end
  for _, part in ipairs(action.actions or {}) do
    if (part.first or 1) > n then break end
    local p = copy(part)
    p.steps = P.chunk(part.steps, n - (part.first or 1) + 1)
    out.actions[#out.actions + 1] = p
  end
  return out
end

function P.confirm(from, steps, results, actual)
  if not results or #results ~= #steps or not actual then return false end
  local at = from
  for i, step in ipairs(steps) do
    local result = results[i]
    if not result or not result.ok and not step.op:match("^inspect") then return false end
    at = P.apply(at, step.op)
  end
  return P.samePose(at, actual)
end

function P.assess(from, steps, checks)
  checks = checks or {}
  if type(from) ~= "table" or type(from.dim) ~= "string" or type(from.x) ~= "number"
    or type(from.y) ~= "number" or type(from.z) ~= "number" or type(from.facing) ~= "number"
    or from.facing % 1 ~= 0 or from.facing < 0 or from.facing > 3 then
    return { ok = false, reason = "pose unknown" }
  end
  for _, axis in ipairs({"x","y","z"}) do
    local n = from[axis]
    if n ~= n or math.abs(n) >= 2^53 or n % 1 ~= 0 then return {ok=false,reason="pose unknown"} end
  end
  local at = copy(from)
  for i, step in ipairs(steps) do
    local to, target = P.apply(at, step.op)
    if P.moves[step.op] then target = to
    elseif P.digs[step.op] then
      local x, y, z = P.ahead(at, P.digs[step.op])
      target = { dim = at.dim, x = x, y = y, z = z }
    end
    if target then
      local ok, reason, holder = true
      if checks.admit then ok, reason, holder = checks.admit(at, step.op, target) end
      if not ok then return { ok=false, first=i, reason=reason, cell=copy(target), holder=holder, limit=checks.limit } end
      if P.moves[step.op] and checks.clear and checks.clear(target) ~= true then
        return { ok=false, first=i, reason="unknown", cell=copy(target), limit=checks.limit }
      end
      if checks.range then
        local allowed, distance, limit = checks.range(target)
        if not allowed then
          return { ok=false, first=i, reason="range", cell=copy(target), distance=distance, limit=limit or checks.limit }
        end
      end
    end
    at = to
  end
  return { ok=true, limit=checks.limit }
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

local burnValues = {
  ["minecraft:oak_log"] = 15, ["minecraft:oak_wood"] = 15,
  ["minecraft:stripped_oak_log"] = 15, ["minecraft:stripped_oak_wood"] = 15,
  ["minecraft:spruce_log"] = 15, ["minecraft:spruce_wood"] = 15,
  ["minecraft:stripped_spruce_log"] = 15, ["minecraft:stripped_spruce_wood"] = 15,
  ["minecraft:birch_log"] = 15, ["minecraft:birch_wood"] = 15,
  ["minecraft:stripped_birch_log"] = 15, ["minecraft:stripped_birch_wood"] = 15,
  ["minecraft:jungle_log"] = 15, ["minecraft:jungle_wood"] = 15,
  ["minecraft:stripped_jungle_log"] = 15, ["minecraft:stripped_jungle_wood"] = 15,
  ["minecraft:acacia_log"] = 15, ["minecraft:acacia_wood"] = 15,
  ["minecraft:stripped_acacia_log"] = 15, ["minecraft:stripped_acacia_wood"] = 15,
  ["minecraft:dark_oak_log"] = 15, ["minecraft:dark_oak_wood"] = 15,
  ["minecraft:stripped_dark_oak_log"] = 15, ["minecraft:stripped_dark_oak_wood"] = 15,
  ["minecraft:mangrove_log"] = 15, ["minecraft:mangrove_wood"] = 15,
  ["minecraft:stripped_mangrove_log"] = 15, ["minecraft:stripped_mangrove_wood"] = 15,
  ["minecraft:cherry_log"] = 15, ["minecraft:cherry_wood"] = 15,
  ["minecraft:stripped_cherry_log"] = 15, ["minecraft:stripped_cherry_wood"] = 15,
}

function P.burnValue(name)
  return burnValues[name]
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

function P.chestPresent(result)
  local block=result and result.ok and result.data
  if type(block)~="table" or type(block.name)~="string" then return false end
  return block.name:find("chest",1,true) ~= nil or block.name:find("barrel",1,true) ~= nil
    or block.name:find("shulker_box",1,true) ~= nil
    or (block.tags and (block.tags["c:chests"] or block.tags["forge:chests"])) == true
end

function P.transferFailure(kind, result)
  local err=type(result.err)=="string" and result.err:lower() or "failed"
  if err=="no space for items" then return (kind=="ore" or kind=="wood") and "full" or "inventory full" end
  if err=="no items to take" then return "empty" end
  if err=="failed" then return (kind=="ore" or kind=="wood") and "full" or "empty" end
  return err
end

function P.chestError(kind, reason, point)
  if not point then return "no " .. kind .. " chest set" end
  if point.id and #tostring(point.id)>8 then
    return kind .. " " .. reason .. " " .. point.x .. "," .. point.y .. "," .. point.z .. " #" .. point.id
  end
  return kind .. (point.id and (" #" .. point.id) or " chest") .. " " .. reason .. " at " .. point.x .. "," .. point.y .. "," .. point.z
end

function P.chestCheck(points, kind, near)
  local best, broken, distance, brokenDistance
  for _, point in ipairs(points or {}) do
    if not point.disabled and point.dim == near.dim and (point.kind == kind or point.kind == "any") then
      local d = math.abs(point.x-near.x) + math.abs(point.y-near.y) + math.abs(point.z-near.z)
      if point.broken then
        if not broken or d < brokenDistance then broken, brokenDistance = point, d end
      elseif not best or point.kind==kind and best.kind~=kind
          or point.kind==best.kind and (d < distance or d==distance and point.id<best.id) then
        best, distance = point, d
      end
    end
  end
  local point = best or broken
  return {ok=best ~= nil, text=point and P.chestError(kind, best and (best.verified and "verified by visit" or "not scanned") or "broken", point)
    or "no " .. kind .. " chest set"}
end

function P.missing(checks)
  local missing = {}
  for _, check in ipairs(checks) do if not check.ok and check.blocking ~= false then missing[#missing+1] = check.text end end
  return missing
end

function P.toolCheck(tools, kind, id, autoSwap)
  local known = type(tools) == "table"
  local equipped = known and ((type(tools.left) == "string" and tools.left:match("_"..kind.."$"))
    or (type(tools.right) == "string" and tools.right:match("_"..kind.."$")))
  return {ok=not known or not not equipped, blocking=autoSwap == true, text=(id and ("#"..id.." ") or "")
    ..(not known and "tools unknown" or equipped and (kind.." ready") or ("needs "..kind))}
end

return P
