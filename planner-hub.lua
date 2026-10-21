-- Hub host for the full planner (plan item T2).

local tools = dofile("planner-tools.lua")
local api = tools.host("hub")

local running = shell and shell.getRunningProgram and shell.getRunningProgram():find("planner%-hub%.lua$")
if running then
  local cfg = api.discover(api.config())
  local w, h = term.getSize()
  local session, err = api.start({
    enabled = cfg.enabled, server = cfg.server, screen = { w = w, h = h },
    origin = cfg.server ~= false and cfg.server or os.getComputerID(),
    hubOnly = cfg.server == false,
  })
  if not session then print(tostring(err)) end
end

return api
