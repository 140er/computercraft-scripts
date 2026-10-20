-- Stub for the planner command gate in front of PR 6 chat-control.lua.
-- PR 6 replaces this stub. chat-control.lua:event accepts only hub, recharge,
-- pro and xray, so a planner verb cannot go through that function.
-- Authorization reads the same cfg.chatEnabled and cfg.chatAllowlist fields,
-- and the same UUID shape that module stores.

local M = {}

function M.uuid(value)
  if type(value) ~= "string" then return nil end
  value = value:lower()
  if value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
    return value
  end
end

-- Returns the lowercase UUID and the command text, or nil when the sender
-- is not on the allowlist. Hidden chat may still start with "$"; AP sometimes
-- strips that character before the event and only sets the hidden flag.
function M.allow(cfg, id, hidden, message)
  if type(cfg) ~= "table" or cfg.chatEnabled ~= true then return nil end
  id = M.uuid(id)
  if not id or type((cfg.chatAllowlist or {})[id]) ~= "string" then return nil end
  if hidden ~= true or type(message) ~= "string" or #message > 256 or #message == 0 then return nil end
  if message:sub(1, 1) == "$" then message = message:sub(2) end
  if message == "" then return nil end
  return id, message
end

return M
