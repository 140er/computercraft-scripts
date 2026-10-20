-- Pocket host for the full planner (plan item T2).

local tools = dofile("planner-tools.lua")
local api = tools.host("panel")

function api.hook(ui, tabs, tabColor)
  if tabColor.plan == nil then
    tabs[#tabs + 1] = { "plan", "Plan" }
    tabColor.plan = colors and colors.magenta or 8192
  end
  if ui.tab ~= "plan" then return end
  local cfg = api.discover(api.config())
  local w, h = 26, 20
  if term and term.getSize then w, h = term.getSize() end
  local origin = os and os.getComputerID and os.getComputerID() or 0
  if cfg.server ~= false then origin = cfg.server end
  api.start({
    enabled = cfg.enabled, server = cfg.server, screen = { w = w, h = h }, origin = origin,
  })
  ui.tab = "home"
end

local running = shell and shell.getRunningProgram and shell.getRunningProgram():find("planner%-panel%.lua$")
if running then
  local cfg = api.discover(api.config())
  local w, h = term.getSize()
  local session, err = api.start({
    enabled = cfg.enabled, server = cfg.server, screen = { w = w, h = h },
    origin = cfg.server ~= false and cfg.server or os.getComputerID(),
  })
  if not session then print(tostring(err)) end
end

return api
