local booted = false
local role = false
local ok, err = pcall(function()
  local h = assert(fs.open("wizard-config.json", "r"))
  local cfg = assert(textutils.unserializeJSON(h.readAll()))
  h.close()
  role = cfg.role
  if cfg.runtime == "sandbox" then
    assert(config.get("standardsMode") == true, "standardsMode disabled")
    assert(fs.getCapacity("/") == cfg.diskLimit, "wrong native disk capacity")
    assert(periphemu.create("left", "modem", 1), "could not attach native modem")
    local call = peripheral.call
    peripheral.call = function(name, method, ...)
      if name == "left" and method == "isWireless" then return true end
      return call(name, method, ...)
    end
    rednet.open("left")
    local id = os.getComputerID()
    booted = true
    if id ~= 0 then rednet.send(0, true, "wizard_sandbox_boot") end
    if role == "board" then
      assert(periphemu.create("right", "monitor", 51, 19), "could not attach native monitor")
    end
    if role == "turtle" then
      for _, name in ipairs({"top", "bottom", "wizard_turtle"}) do
        assert(periphemu.create(name, "chest", false), "could not attach native inventory " .. name)
      end
      assert(require("wh2-wizard-gate-inventory").install(cfg), "could not install sandbox turtle inventory")
    end
    booted = true
    local report = assert(fs.open("wizard-sandbox-boot.json", "w"))
    local monitor = peripheral.find("monitor")
    local width, height = 0, 0
    if monitor then width, height = monitor.getSize() end
    report.write(textutils.serializeJSON({id=id,role=role,capacity=fs.getCapacity("/"),free=fs.getFreeSpace("/"),
      turtle=turtle ~= nil,monitor={width=width,height=height},modem=peripheral.getType("left")}))
    report.close()
    if id == 0 then
      for peer = 1, 6 do
        assert(periphemu.create(tostring(peer), "computer"), "could not start computer " .. peer)
        local sender = rednet.receive("wizard_sandbox_boot", 30)
        assert(sender == peer, "computer did not finish native startup " .. peer)
      end
    end
  else
    booted = true
  end
  return require("wh2-wizard-gate-runtime").run()
end)
local h = assert(fs.open("sandbox-result.json", "w"))
h.write(textutils.serializeJSON({ok=false,booted=booted,free=fs.getFreeSpace("/"),capacity=fs.getCapacity("/"),
  role=role,errors={tostring(err or (ok and "wizard service returned" or "wizard driver stopped"))},lines={}}))
h.close()
while true do os.pullEvent() end
