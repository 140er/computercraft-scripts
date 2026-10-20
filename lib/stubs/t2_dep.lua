-- Interface shim for planner-core.lua (plan item T1).
-- T2 loads planner-core.lua when that file exists, and this module otherwise.
-- T1 replaces this file. The functions below are the surface T2 calls.
-- transition is not the full planner. It defers every event so T2 can apply it.

local M = { version = 1, item = "T1" }

-- Glyph and colour together. Colour alone is not enough on a 16-colour screen.
M.styles = {
  known = { glyph = ".", colour = "lightGray", blit = "8" },
  predicted = { glyph = "~", colour = "brown", blit = "c" },
  unknown = { glyph = "?", colour = "gray", blit = "7" },
  intent = { glyph = "+", colour = "magenta", blit = "2" },
  occupied = { glyph = "X", colour = "red", blit = "e" },
}

M.ops = {
  put = "plan-put",
  intent = "plan-intent",
  code = "plan-code",
  claim = "plan-claim",
}

local CONF = { certain = true, suspect = true, lost = true }
local SRC = { gps = true, neighbour = true, radio = true, typed = true, reckoned = true, inherited = true }

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

function M.style(kind)
  local row = M.styles[kind]
  if not row then return nil, "bad_style" end
  return { glyph = row.glyph, colour = row.colour, blit = row.blit }
end

-- Ids are the origin computer id plus a durable counter: "p:<origin>:<n>".
function M.mint(origin, counter)
  if not integer(origin, 0, 2147483647) then return nil, "bad_origin" end
  if not integer(counter, 1, 1000000000) then return nil, "bad_counter" end
  return string.format("p:%d:%d", origin, counter), counter + 1
end

function M.pos(fields)
  if type(fields) ~= "table" then return nil, "bad_pos" end
  if fields.v ~= nil and fields.v ~= 1 then return nil, "bad_pos" end
  local frame = fields.frame
  if frame ~= "abs" and not (type(frame) == "string" and frame:match("^f:[%w:.%-]+$") and #frame <= 64) then
    return nil, "bad_pos"
  end
  if fields.yAbs ~= true and fields.yAbs ~= false then return nil, "bad_pos" end
  if type(fields.dim) ~= "string" or #fields.dim > 80 or not fields.dim:match("^[%w_]+:[%w_/.-]+$") then
    return nil, "bad_pos"
  end
  if not integer(fields.x, -30000000, 30000000) or not integer(fields.y, -2048, 2048)
    or not integer(fields.z, -30000000, 30000000) then
    return nil, "bad_pos"
  end
  local h = fields.h or 0
  if not integer(h, 0, 3) then return nil, "bad_pos" end
  if not CONF[fields.conf or "suspect"] or not SRC[fields.src or "typed"] then return nil, "bad_pos" end
  local anchoredAt = fields.anchoredAt or 0
  if not integer(anchoredAt, 0, 9007199254740991) then return nil, "bad_pos" end
  return {
    v = 1, frame = frame, yAbs = fields.yAbs, dim = fields.dim,
    x = fields.x, y = fields.y, z = fields.z, h = h,
    conf = fields.conf or "suspect", src = fields.src or "typed", anchoredAt = anchoredAt,
  }
end

-- Stand-in reducer. A real planner-core handles the MVP and returns anything it does not own as defer.
function M.transition(session, event)
  return session, { { op = "defer", event = event } }
end

return M
