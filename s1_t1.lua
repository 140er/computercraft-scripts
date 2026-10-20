-- Stub for T1 planner records. planner-core.lua replaces this file.
-- S1 stores the records and hands them over. It does not plan, draw, or issue codes.
local M = { version = 1, item = "T1", replacedBy = "planner-core.lua" }

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end
local function word(s, n)
  return type(s) == "string" and #s > 0 and #s <= n
end

function M.planId(id)
  return type(id) == "string" and id:match("^p:%d+:%d+$") ~= nil
end

function M.pos(p)
  return type(p) == "table" and p.v == 1 and type(p.yAbs) == "boolean"
    and (p.frame == "abs" or (word(p.frame, 80) and p.frame:match("^f:[%w:._-]+$")))
    and word(p.dim, 80) and p.dim:match("^[%w_]+:[%w_/.-]+$")
    and integer(p.x, -30000000, 30000000) and integer(p.y, -2048, 2048)
    and integer(p.z, -30000000, 30000000) and integer(p.h, 0, 3)
    and (p.conf == "certain" or p.conf == "suspect" or p.conf == "lost")
    and (p.src == "gps" or p.src == "neighbour" or p.src == "radio" or p.src == "typed"
      or p.src == "reckoned" or p.src == "inherited")
    and integer(p.anchoredAt, 0, 9007199254740991)
end

local function idList(list, limit)
  if type(list) ~= "table" or #list > limit then return false end
  for i, id in ipairs(list) do
    if not integer(i, 1, #list) or not M.planId(id) then return false end
  end
  return true
end

function M.plan(p)
  if type(p) ~= "table" or p.v ~= 1 or not M.planId(p.id) then return false end
  if not (p.frame == "abs" or (word(p.frame, 80) and p.frame:match("^f:[%w:._-]+$"))) then return false end
  if not word(p.dim, 80) or not p.dim:match("^[%w_]+:[%w_/.-]+$") then return false end
  if not integer(p.y, -2048, 2048) or not word(p.name, 40) or not integer(p.rev, 0, 2147483647) then return false end
  if type(p.areas) ~= "table" or #p.areas > 32 or not idList(p.fixtures, 64) or not idList(p.bots, 64) then return false end
  for i, area in ipairs(p.areas) do
    if not integer(i, 1, #p.areas) or type(area) ~= "table" or not M.planId(area.id) then return false end
    if not word(area.kind, 16) or not M.pos(area.min) or not M.pos(area.max) then return false end
  end
  return true
end

function M.fixture(p)
  return type(p) == "table" and p.v == 1 and M.planId(p.id) and M.planId(p.plan)
    and (p.kind == "chest" or p.kind == "dropoff" or p.kind == "charger" or p.kind == "furnace")
    and M.pos(p.pos) and word(p.side, 16)
    and (p.state == "planned" or p.state == "verified" or p.state == "active" or p.state == "retired")
    and (p.layoutId == false or M.planId(p.layoutId))
end

function M.bot(p)
  return type(p) == "table" and p.v == 1 and M.planId(p.id) and M.planId(p.plan) and word(p.role, 32)
    and M.pos(p.pos) and type(p.settings) == "table" and integer(p.settings.revision, 0, 2147483647)
    and type(p.settings.overrides) == "table" and type(p.devToggles) == "table"
    and type(p.jobArea) == "table" and M.pos(p.jobArea.min) and M.pos(p.jobArea.max)
    and type(p.expect) == "table" and type(p.expect.neighbours) == "table" and type(p.expect.peripherals) == "table"
    and (p.state == "planned" or p.state == "code-issued" or p.state == "claimed"
      or p.state == "verified" or p.state == "active" or p.state == "retired")
    and (p.code == false or (word(p.code, 16)))
    and (p.computerId == false or integer(p.computerId, 0, 2147483647))
end

-- Cells a planned fixture or bot holds as intent. T1's reservation check replaces the caller.
function M.cells(record)
  if M.fixture(record) then return { record.pos } end
  if M.bot(record) then return { record.pos } end
  return {}
end

function M.samplePos(x, y, z, h)
  return {
    v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
    x = x, y = y, z = z, h = h or 0, conf = "certain", src = "typed", anchoredAt = 0,
  }
end

return M
