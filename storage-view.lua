local M = {}

local REMIND_MS = 300000

local CHOICES = {
  { id = "forget", label = "Forget old" },
  { id = "expand", label = "Needs storage turtles" },
  { id = "decline", label = "Keep everything" },
}

function M.prompt(ledger, enabled)
  if not enabled or type(ledger) ~= "table" or ledger.state ~= "warn" then
    return { v = 1, choices = {}, panel = {}, glasses = {}, chat = false }
  end
  return {
    v = 1,
    choices = {
      { id = CHOICES[1].id, label = CHOICES[1].label },
      { id = CHOICES[2].id, label = CHOICES[2].label },
      { id = CHOICES[3].id, label = CHOICES[3].label },
    },
    panel = {
      "Storage " .. ledger.localUsed .. "/" .. ledger.localTotal,
      "Choose before the map grows.",
      "Forget old",
      "Needs storage turtles",
      "Keep everything",
    },
    glasses = { "Storage at the limit", "Forget, turtles, or keep" },
    chat = "Storage is at the limit. Forget old map data, add storage turtles, or keep everything. Nothing is dropped.",
  }
end

function M.lines(ledger, preview, enabled)
  if not enabled or type(ledger) ~= "table" then return { "Storage ledger is off." } end
  local out = {
    "Storage " .. ledger.state,
    ledger.localUsed .. " of " .. ledger.localTotal .. " bytes",
    "Peers " .. ledger.peerUsed .. " of " .. ledger.peerTotal,
    "Growth " .. ledger.growthPerHour .. " bytes/hour",
  }
  if ledger.state == "warn" or ledger.state == "paused" then
    out[#out + 1] = "Expand needs storage turtles."
  end
  if ledger.state == "paused" then
    out[#out + 1] = "Map writes are paused."
  end
  if type(preview) == "table" and type(preview.items) == "table" then
    out[#out + 1] = "Preview " .. tostring(preview.id) .. " " .. #preview.items .. " files " .. tostring(preview.bytes) .. " bytes"
  end
  return out
end

function M.due(lastAt, now)
  if lastAt == false or lastAt == nil then return true end
  if type(lastAt) ~= "number" or type(now) ~= "number" then return false end
  return now - lastAt >= REMIND_MS
end

return M
