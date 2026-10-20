-- Stub of H4b1 cell confidence. H4b1 derives confidence. It does not store it.
-- confidence(sample, dim, x, y, z) returns "observed", "predicted", or "unknown".
-- H4b1 ships observed and unknown. Predicted is accepted here so the view can
-- draw it when H4b2 fills the sample.

local M = {}

local function cell(sample, dim, x, y, z)
  if type(sample) ~= "table" then return nil end
  return sample[tostring(dim) .. "|" .. tostring(x) .. "|" .. tostring(y) .. "|" .. tostring(z)]
end

function M.confidence(sample, dim, x, y, z)
  local found = cell(sample, dim, x, y, z)
  if found == "observed" or found == "predicted" or found == "unknown" then return found end
  if type(found) == "table" then
    if found.conf == "observed" or found.conf == "predicted" or found.conf == "unknown" then
      return found.conf
    end
  end
  return "unknown"
end

function M.name(sample, dim, x, y, z)
  local found = cell(sample, dim, x, y, z)
  if type(found) == "table" and type(found.name) == "string" then return found.name end
  return false
end

return M
