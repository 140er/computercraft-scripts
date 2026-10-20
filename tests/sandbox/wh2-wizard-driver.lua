local booted = false
local role = false
local flowResult
local function ensure(name, kind, ...)
  if peripheral.getType(name) == kind then return end
  assert(periphemu.create(name, kind, ...), "could not attach " .. kind .. " on " .. name)
end
local ok, err = pcall(function()
  local h = assert(fs.open("wizard-config.json", "r"))
  local cfg = assert(textutils.unserializeJSON(h.readAll()))
  h.close()
  role = cfg.role
  if cfg.runtime == "sandbox" then
    assert(config.get("standardsMode") == true, "standardsMode disabled")
    assert(fs.getCapacity("/") == cfg.diskLimit, "wrong native disk capacity")
    ensure("left", "modem")
    local call = peripheral.call
    peripheral.call = function(name, method, ...)
      if name == "left" and method == "isWireless" then return true end
      return call(name, method, ...)
    end
    if not rednet.isOpen("left") then rednet.open("left") end
    if role == "board" then pcall(ensure, "right", "monitor") end
    if role == "turtle" then
      for _, name in ipairs({"top", "bottom", "wizard_turtle"}) do ensure(name, "chest") end
      assert(require("wh2-wizard-gate-inventory").install(cfg), "could not install sandbox turtle inventory")
    end
    booted = true
    local report = assert(fs.open("wizard-sandbox-boot.json", "w"))
    local monitor = peripheral.find("monitor")
    local width, height = term.getSize()
    if monitor then width, height = monitor.getSize() end
    report.write(textutils.serializeJSON({id=os.getComputerID(), role=role, capacity=fs.getCapacity("/"),
      free=fs.getFreeSpace("/"), turtle=turtle ~= nil, monitor={width=width, height=height},
      modem=peripheral.getType("left")}))
    report.close()
    local id = os.getComputerID()
    if id ~= 0 then rednet.send(0, true, "wizard_sandbox_boot") end
    if id == 0 then
      for peer = 1, 6 do
        assert(periphemu.create(tostring(peer), "computer"), "could not start computer " .. peer)
        local sender = rednet.receive("wizard_sandbox_boot", 30)
        assert(sender == peer, "computer did not finish native startup " .. tostring(sender))
      end
    end
    flowResult = require("wh2-wizard-flow").run(cfg)
    return
  end
  booted = true
  return require("wh2-wizard-gate-runtime").run()
end)
local payload = flowResult
if type(payload) ~= "table" then
  payload = {ok=false, booted=booted, free=fs.getFreeSpace("/"), capacity=fs.getCapacity("/"),
    role=role, errors={tostring(err or (ok and "wizard service returned" or "wizard driver stopped"))}, lines={}}
end
local out = assert(fs.open("sandbox-result.json", "w"))
out.write(textutils.serializeJSON(payload))
out.close()
while true do os.pullEvent() end
