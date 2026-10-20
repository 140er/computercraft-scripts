local M = {}

-- Provisional fleet boundary. Reconcile this function when wh2-client is committed.
-- wh2-client.open(private wh2.cfg) returns dot-call call(op, body), dispatch(sender, msg, proto), worker().
-- call queues and waits; dispatch never yields; worker owns authenticated outbound work.
local function fleetClient()
  local ok, fleet = pcall(require, "wh2-client")
  if not ok or type(fleet) ~= "table" or type(fleet.open) ~= "function" then
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
  local client
  ok, client = pcall(fleet.open, config)
  if not ok or not client then return nil, "Authenticated wh2-client unavailable" end
  return client
end

function M.open(options)
  options = options or {}
  local enabled = settings and settings.get("wh2.enabled", false) == true or false
  local client, failure
  if enabled then
    if options.client ~= nil then client = options.client else client, failure = fleetClient() end
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
