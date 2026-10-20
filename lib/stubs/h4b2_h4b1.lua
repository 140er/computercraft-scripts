-- Stub for H4b1 chunk-store.lua.
-- H4b1 owns per-section slots, dirty saves, and the schema 1 migration.
-- H4b2 calls this only to name a slot. It does not write those files.

local M = {}

function M.sectionSlot(key)
  if type(key) ~= "string" or key == "" or key:find("|", 1, true) == nil then return nil, "section key" end
  return "map/sections/h4b1-stub/" .. key
end

function M.migrationAvailable()
  return false
end

return M
