-- Stub of the I1 copy-code record (plan section 2.9).
-- No X25519. The code only identifies a planner bot. I1 replaces issue and claim.
-- Planner TTL is 15 minutes. One success burns the code. Five failed claims burn it.

local M = { ttl = 900000, alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ" }

function M.codeFor(n)
  local x = n * 104729 + 1597334677
  local out = {}
  for i = 10, 1, -1 do
    local index = (x % 32) + 1
    out[i] = M.alphabet:sub(index, index)
    x = math.floor(x / 32) + n * 17 + i * 13
  end
  return table.concat(out)
end

function M.matches(code)
  if type(code) ~= "string" or #code ~= 10 then return false end
  for i = 1, 10 do
    if not M.alphabet:find(code:sub(i, i), 1, true) then return false end
  end
  return true
end

function M.issue(origin, n, bot, now)
  local code = M.codeFor(n)
  return {
    v = 1,
    code = code,
    issuer = origin,
    issuedAt = now,
    untilAt = now + M.ttl,
    role = bot.role,
    settingsRef = { revision = bot.settings.revision },
    devToggles = {},
    filesRef = { manifest = "stub", role = bot.role },
    frame = bot.pos.frame,
    home = bot.pos,
    used = false,
    attempts = 0,
    planBot = bot.id,
  }
end

return M
