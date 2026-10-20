-- Hub host for the full planner (plan item T2).
-- A server has to be present. Hub-only planning arrives with S1.
-- Off unless planner.cfg is { enabled = true, server = <id> }.
-- Q quits.

local tools = dofile("planner-tools.lua")
local api = tools.host("hub")

local running = shell and shell.getRunningProgram and shell.getRunningProgram():find("planner%-hub%.lua$")
if running then
  local cfg = api.config()
  local w, h = term.getSize()
  local session, err = api.start({
    enabled = cfg.enabled, server = cfg.server, screen = { w = w, h = h },
    origin = cfg.server or os.getComputerID(),
  })
  if not session then print(tostring(err)) end
end

return api
