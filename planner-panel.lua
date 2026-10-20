-- Pocket host for the full planner (plan item T2).
-- Off unless planner.cfg is { enabled = true, server = <id> }.
-- Screen is the pocket: 26 by 20. Q quits.

local tools = dofile("planner-tools.lua")
local api = tools.host("panel")

local running = shell and shell.getRunningProgram and shell.getRunningProgram():find("planner%-panel%.lua$")
if running then
  local cfg = api.config()
  if cfg.enabled and cfg.server == false and fs and fs.exists and fs.exists("plug.lua") then
    local ok, plug = pcall(dofile, "plug.lua")
    if ok and type(plug) == "table" then
      local value, source = plug.fill(nil, nil, function()
        return plug.lookup({ peripheral = peripheral, rednet = rednet }, "fleetserver", "server")
      end, function(spec)
        spec.title, spec.question = "Planner", "Fleet server id"
        spec.kind = spec.kind or "number"
        return plug.ask(plug.termio(), spec)
      end)
      if type(value) == "number" and (source == "discover" or source == "prompt") then
        local raw = {}
        if fs.exists("planner.cfg") then
          local handle = fs.open("planner.cfg", "r")
          local parsedOk, parsed = pcall(textutils.unserialize, handle.readAll())
          handle.close()
          if parsedOk and type(parsed) == "table" then raw = parsed end
        end
        if raw.server == nil then
          raw.server = value
          raw.enabled = raw.enabled == true
          local handle = fs.open("planner.cfg", "w")
          handle.write(textutils.serialize(raw))
          handle.close()
          cfg.server = value
        end
      end
    end
  end
  local w, h = term.getSize()
  local session, err = api.start({
    enabled = cfg.enabled, server = cfg.server, screen = { w = w, h = h },
    origin = cfg.server or os.getComputerID(),
  })
  if not session then print(tostring(err)) end
end

return api
