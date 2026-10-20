local M = {}

function M.run()
  local id = os.getComputerID()
  local function read(path)
    local file = fs.open(path, "r")
    if not file then return nil end
    local value = textutils.unserializeJSON(file.readAll())
    file.close()
    return value
  end
  local function write(path, value)
    local file = assert(fs.open(path .. ".tmp", "w"))
    file.write(textutils.serializeJSON(value))
    file.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(path .. ".tmp", path)
  end
  local cfg = assert(read("wizard-config.json"), "missing wizard config")
  assert(cfg.enabled == true, "scenario requires explicit opt-in")
  local previousBoot = read("wizard-boot.json")
  local bootCount = previousBoot and previousBoot.bootCount + 1 or 1
  local bootId = tostring(os.epoch("utc")) .. ":" .. id .. ":" .. bootCount
  local boot = {id=id, role=cfg.role, bootId=bootId, bootCount=bootCount, bootNonce=cfg.bootNonce or false,
    capacity=fs.getCapacity("/"), free=fs.getFreeSpace("/"), authenticated=false, stage="preflight"}
  write("wizard-boot.json", boot)
  local eventLimit = cfg.outputLimitBytes or 393216
  assert(type(eventLimit) == "number" and eventLimit >= 16384 and eventLimit <= 524288
    and eventLimit % 1 == 0, "invalid evidence byte limit")
  local function evidence(kind, value)
    local line = textutils.serializeJSON({at=os.epoch("utc"), id=id, bootId=bootId, kind=kind, value=value})
    local bytes = fs.exists("wizard-events.jsonl") and fs.getSize("wizard-events.jsonl") or 0
    assert(bytes + #line + 1 <= eventLimit, "evidence byte limit reached; collect this attempt before continuing")
    assert(fs.getFreeSpace("/") >= #line + 65536, "evidence would consume the control reserve")
    local file = assert(fs.open("wizard-events.jsonl", "a"))
    file.writeLine(line)
    file.close()
  end
  evidence("boot", boot)
  assert(boot.capacity == cfg.diskLimit, "native disk capacity differs from scenario limit")
  local inventory = require("wh2-wizard-gate-inventory")
  if cfg.runtime == "sandbox" and cfg.role == "turtle" and not turtle then inventory.install(cfg) end
  local binding = require("wh2-wizard-gate-bindings").open(cfg)
  local auth = assert(binding.authentication, "missing verified production authentication context")
  assert(binding.authenticated == true and auth.version == 2 and auth.mac == "blake3-keyed"
    and auth.requireMac == true and auth.handshakeVerified == true and auth.serverPinned == true,
    "binding did not verify the pinned v2 keyed BLAKE3 session")
  boot.authenticated, boot.stage = true, "connected"
  boot.authentication = {version=auth.version, mac=auth.mac, requireMac=auth.requireMac,
    handshakeVerified=auth.handshakeVerified, serverPinned=auth.serverPinned}
  boot.authorityBoot = binding.authorityBoot or false
  write("wizard-boot.json", boot)
  evidence("authenticated-session", {version=auth.version, mac=auth.mac, authorityBoot=boot.authorityBoot})
  local checks = require("wh2-wizard-gate-checks")
  local function worker()
    if cfg.role == "server" then return assert(binding.server, "missing real SSOT server entry")() end
    local client = assert(binding.client, "missing shared authenticated wh2-client")
    local previous = read("wizard-result.json")
    local last = previous and previous.nonce or false
    while true do
      local command = read("wizard-command.json")
      if command and command.nonce ~= last then
        assert(type(command.nonce) == "string" and #command.nonce > 0 and #command.nonce <= 128,
          "invalid scenario command identity")
        last = command.nonce
        local reboot = false
        local ok, err = pcall(function()
          if command.action == "report" then
            checks.report(client, cfg.unknowns, evidence, inventory.snapshot(), "input:" .. id)
          elseif command.action == "answer" then
            checks.board(client, cfg.unknowns, evidence, binding.boardTerm)
          elseif command.action == "draft" then
            local saved = checks.draft(client, cfg.unknowns[1], evidence, binding.boardTerm)
            saved.bootId, saved.authorityBoot = bootId, boot.authorityBoot
            write("wizard-draft.json", saved)
          elseif command.action == "draft-retained" then
            local saved = assert(read("wizard-draft.json"), "missing durable draft checkpoint")
            assert(saved.bootId ~= bootId, "draft retention requires a real computer reboot")
            checks.draftRetained(client, saved, evidence, binding.boardTerm)
          elseif command.action == "draft-discard" then
            checks.discard(client, assert(read("wizard-draft.json"), "missing draft checkpoint").item,
              evidence, binding.boardTerm)
          elseif command.action == "draft-owner" then
            checks.draftOwner(client, command.item or cfg.unknowns[1], evidence, binding.boardTerm)
          elseif command.action == "checkpoint" then
            write("wizard-checkpoint.json", {bootId=bootId, authorityBoot=boot.authorityBoot,
              snapshot=checks.retained(client, cfg.unknowns, evidence)})
          elseif command.action == "retained" then
            local saved = assert(read("wizard-checkpoint.json"), "missing restart checkpoint")
            assert(command.barrier == "computer-reboot" or command.barrier == "server-restart"
              or command.barrier == "modem-restored", "missing retention barrier")
            if command.barrier == "computer-reboot" then
              assert(saved.bootId ~= bootId, "retention check did not cross a computer reboot")
            elseif command.barrier == "server-restart" then
              assert(boot.authorityBoot ~= false and saved.authorityBoot ~= boot.authorityBoot,
                "production authority restart identity was not observed")
            end
            checks.retained(client, cfg.unknowns, evidence, saved.snapshot)
          elseif command.action == "fuzz" then checks.fuzz(client, evidence)
          elseif command.action == "stale" then checks.concurrent(client, evidence)
          elseif command.action == "revision" then
            write("wizard-revision.json", {nonce=last, revision=checks.snapshot(client).revision})
          elseif command.action == "race-answer" then
            local reply = assert(client.call("wh2-class", {wh2=1, action="set", item=command.item,
              baseRevision=command.baseRevision,
              value={class="misc", route="store", storeCategory="misc", recipeId=false}}))
            write("wizard-race.json", {nonce=last, reply=reply})
            evidence("racing-answer", reply)
          elseif command.action == "route" then
            inventory.route(checks.snapshot(client).classes, cfg.unknowns, evidence)
          elseif command.action == "snapshot" then
            local value = inventory.snapshot()
            local held = {}
            for _, row in ipairs(value.held) do held[row.name] = (held[row.name] or 0) + row.count end
            write("wizard-inventory.json", {nonce=last, inventory=held, slots=value.held, input=value.input,
              output=value.output, totals=value.totals, bootId=bootId})
          elseif command.action == "boundary" then
            assert(binding.boundary, "missing production boundary " .. tostring(command.case))(command.case, evidence)
          elseif command.action == "reboot" then reboot = true
          else error("unknown scenario action") end
        end)
        evidence("command", {nonce=last, action=command.action, ok=ok, error=not ok and tostring(err) or false})
        write("wizard-result.json", {nonce=last, ok=ok, error=not ok and tostring(err) or false, bootId=bootId})
        if ok and reboot then os.reboot() end
      end
      sleep(0.1)
    end
  end
  local function metrics()
    local saveSequence = 0
    while true do
      local held = {}
      if turtle then
        for slot = 1, 16 do
          local row = turtle.getItemDetail(slot)
          if row then held[row.name] = (held[row.name] or 0) + row.count end
        end
      end
      local serverMetrics = false
      if cfg.role == "server" then
        serverMetrics = assert(binding.metrics, "missing production save instrumentation")()
        assert(type(serverMetrics) == "table" and serverMetrics.source == "production-storage"
          and type(serverMetrics.saveSequence) == "number" and serverMetrics.saveSequence >= saveSequence
          and type(serverMetrics.lastSaveMs) == "number" and serverMetrics.lastSaveMs >= 0
          and type(serverMetrics.lastSavedAt) == "number" and serverMetrics.lastSavedAt > 0
          and type(serverMetrics.stateBytes) == "number" and serverMetrics.stateBytes >= 0,
          "invalid measured production save metrics")
        saveSequence = serverMetrics.saveSequence
        serverMetrics = {source=serverMetrics.source, saveSequence=serverMetrics.saveSequence,
          lastSaveMs=serverMetrics.lastSaveMs, lastSavedAt=serverMetrics.lastSavedAt, stateBytes=serverMetrics.stateBytes}
      end
      evidence("metrics", {capacity=fs.getCapacity("/"), free=fs.getFreeSpace("/"), server=serverMetrics,
        allocatedBytes=fs.getCapacity("/") - fs.getFreeSpace("/"),
        stateBytes=serverMetrics and serverMetrics.stateBytes or false,
        inventory=held, fuel=turtle and turtle.getFuelLevel() or false})
      sleep(cfg.sampleSeconds)
    end
  end
  parallel.waitForAny(worker, metrics, assert(binding.receiver, "missing authenticated receiver"))
  error("scenario service stopped")
end

return M
