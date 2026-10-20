-- Server monitor adapter. Turns touch and keys into planner events.
-- The core stays free of the terminal. This file is the only planner UI.

local View = dofile("planner-view.lua")
local Map = dofile("planner-map.lua")

local M = {}

function M.attach(opts)
  local host = {
    ssot = opts.ssot, screen = opts.screen, clock = opts.clock or function() return 0 end,
    tool = "draw", corner = nil, note = "", code = nil,
    focusX = 0, focusZ = 0, map = opts.map or {},
  }

  function host.setScreen(screen) host.screen = screen end

  function host.apply(event)
    local result = host.ssot.plan(event)
    host.last = result
    if type(result) == "table" and result.effects then
      for _, effect in ipairs(result.effects) do
        if effect.op == "note" or effect.op == "screen" then host.note = effect.text or "" end
        if effect.op == "code" then host.code = effect.code end
      end
    elseif type(result) == "table" and result.error then
      host.note = result.error
    end
    return result
  end

  function host.tap(x, z)
    if host.tool == "draw" then
      if not host.corner then
        host.corner = { x = x, z = z }
        host.note = "Corner " .. x .. "," .. z
        return nil
      end
      local from = host.corner
      host.corner = nil
      return host.apply({ t = "draw", x1 = from.x, z1 = from.z, x2 = x, z2 = z })
    end
    if host.tool == "chest" or host.tool == "bot" then
      return host.apply({ t = "place", kind = host.tool, x = x, z = z })
    end
  end

  function host.touch(x, y)
    if not host.layout then return nil end
    for _, hit in ipairs(host.layout.hits) do
      if y == hit.row and x >= hit.x1 and x <= hit.x2 then
        if hit.kind == "level" then return host.apply({ t = "level", dy = hit.dy }) end
        if hit.kind == "tool" then host.tool = hit.tool host.corner = nil return nil end
        if hit.kind == "create" then return host.apply({ t = "create", name = "Base" }) end
        if hit.kind == "issue" then return host.apply({ t = "issue" }) end
      end
    end
    if y >= host.layout.mapTop then
      local wx = host.layout.originX + (x - 1)
      local wz = host.layout.originZ + (y - host.layout.mapTop)
      return host.tap(wx, wz)
    end
  end

  function host.char(ch)
    if ch == "+" or ch == "=" then return host.apply({ t = "level", dy = 1 }) end
    if ch == "-" or ch == "_" then return host.apply({ t = "level", dy = -1 }) end
    if ch == "d" then host.tool = "draw" return nil end
    if ch == "c" then host.tool = "chest" return nil end
    if ch == "b" then host.tool = "bot" return nil end
    if ch == "n" then return host.apply({ t = "create", name = "Base" }) end
    if ch == "k" then return host.apply({ t = "issue" }) end
  end

  function host.key(code)
    local up = keys and keys.up
    local down = keys and keys.down
    local left = keys and keys.left
    local right = keys and keys.right
    if code == up or code == "up" then return host.apply({ t = "level", dy = 1 }) end
    if code == down or code == "down" then return host.apply({ t = "level", dy = -1 }) end
    if code == left or code == "left" then host.focusX = host.focusX - 4 return nil end
    if code == right or code == "right" then host.focusX = host.focusX + 4 return nil end
  end

  function host.model()
    local state = host.ssot.state() or {}
    local planner = state.planner or {}
    local plan = planner.active and planner.plans[planner.active]
    local dim = (plan and plan.dim) or planner.dim or "minecraft:overworld"
    local level = planner.y or (plan and plan.y) or 64
    local poses = state.poses or {}
    local function occupied(x, z)
      for _, pose in pairs(poses) do
        if pose.dim == dim and pose.x == x and pose.y == level and pose.z == z then return true end
      end
      return false
    end
    local function classAt(x, z)
      if occupied(x, z) then return "occupied" end
      if plan then
        for _, id in ipairs(plan.fixtures) do
          local fixture = planner.fixtures[id]
          if fixture and fixture.state ~= "retired" and fixture.pos.x == x and fixture.pos.z == z and fixture.pos.y == level then
            return fixture.kind == "chest" and "chest" or "intent"
          end
        end
        for _, id in ipairs(plan.bots) do
          local bot = planner.bots[id]
          if bot and bot.state ~= "retired" and bot.pos.x == x and bot.pos.z == z and bot.pos.y == level then
            return "bot"
          end
        end
        local area = plan.areas[1]
        if area and area.min.y == level and x >= area.min.x and x <= area.max.x
          and z >= area.min.z and z <= area.max.z then
          return "base"
        end
      end
      local conf = Map.confidence(host.map, dim, x, level, z)
      if conf == "observed" then return "known" end
      if conf == "predicted" then return "predicted" end
      return "unknown"
    end
    local function headingAt(x, z)
      if not plan then return nil end
      for _, id in ipairs(plan.bots) do
        local bot = planner.bots[id]
        if bot and bot.pos.x == x and bot.pos.z == z and bot.pos.y == level then return bot.pos.h end
      end
    end
    return {
      name = plan and plan.name or "Plan",
      y = level, rev = planner.rev or 0,
      note = host.note, code = host.code,
      originX = host.focusX, originZ = host.focusZ,
      classAt = classAt, headingAt = headingAt,
    }
  end

  function host.draw()
    if not host.screen or not host.screen.blit then return nil end
    host.layout = View.paint(host.screen, host.model())
    return host.layout
  end

  local id = 0
  if os and os.getComputerID then id = os.getComputerID() end
  host.apply({ t = "boot", origin = id })
  return host
end

return M
