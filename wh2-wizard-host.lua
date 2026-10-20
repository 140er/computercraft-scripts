local M = {}

local function fleetClient(options)
  local ok, fleet = pcall(require, "wh2-client")
  if not ok or type(fleet) ~= "table" or type(fleet.new) ~= "function" then
    return nil, "Authenticated wh2-client unavailable"
  end
  local config
  ok = pcall(function()
    local file = fs.open("wh2.cfg", "r")
    if not file then return end
    local data = file.readAll()
    file.close()
    config = textutils.unserialize(data)
  end)
  if not ok or type(config) ~= "table" or type(config.server) ~= "number"
    or config.server < 0 or config.server > 2147483647 or config.server % 1 ~= 0 then
    return nil, "Wizard unavailable. Pin server in wh2.cfg"
  end
  local rpc=options.rpc
  if not rpc then
    local authenticated=pcall(require,"ssot-auth")
    if not authenticated then return nil,"Authenticated wh2-client unavailable" end
    local loaded,transport=pcall(require,"ssot-client")
    if not loaded or type(transport)~="table" or type(transport.new)~="function" then
      return nil,"Authenticated wh2-client unavailable"
    end
    if type(config.pairingFile)~="string" or #config.pairingFile==0 or #config.pairingFile>128
      or config.pairingFile:find("[%c]") then return nil,"Wizard unavailable. Set pairingFile in wh2.cfg" end
    loaded,rpc=pcall(transport.new,{server=config.server,pairingFile=config.pairingFile,
      counterFile="wh2-ssot.outbox"})
    if not loaded then return nil,"Authenticated wh2-client unavailable" end
  end
  if type(rpc)~="table" or type(rpc.call)~="function" or type(rpc.dispatch)~="function" then
    return nil,"Authenticated wh2-client unavailable"
  end
  local client
  ok, client = pcall(fleet.new, {enabled=true,rpc=rpc,role=options.role=="hub" and "hub" or "panel"})
  if not ok or not client then return nil, "Authenticated wh2-client unavailable" end
  return client
end

function M.open(options)
  options = options or {}
  local enabled = settings and settings.get("wh2.enabled", false) == true or false
  local client, failure
  if enabled then
    if options.client ~= nil then client = options.client else client, failure = fleetClient(options) end
    if type(client) ~= "table" or type(client.call) ~= "function"
      or type(client.dispatch) ~= "function" or type(client.worker) ~= "function" then
      client, failure = nil, failure or "Authenticated wh2-client unavailable"
    end
  else failure = "Wizard disabled. Set wh2.enabled true" end
  local host = { context = { enabled = enabled, role = options.role or "roomsorter" }, error = failure }
  host.context.client = client or { call = function() return nil, failure, enabled and "unavailable" or "disabled" end }

  function host.dispatch(sender, message, protocol)
    if client then return client.dispatch(sender, message, protocol) end
    return false
  end

  local started = false
  function host.worker()
    assert(not started, "Wizard host worker already started")
    started = true
    if client then
      client.worker()
      error("Authenticated wh2-client worker stopped", 0)
    end
    while true do os.pullEvent("wh2_wizard_host_idle") end
  end

  return host
end

return M
