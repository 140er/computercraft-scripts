local M = {}

function M.run()
  local id = os.getComputerID()
  local function read(path)
    local h = fs.open(path, "r")
    if not h then return nil end
    local value = textutils.unserializeJSON(h.readAll())
    h.close()
    return value
  end
  local function write(path, value)
    local h = assert(fs.open(path .. ".tmp", "w"))
    h.write(textutils.serializeJSON(value)) h.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(path .. ".tmp", path)
  end
  local cfg = assert(read("wizard-config.json"), "missing wizard config")
  local function evidence(kind, value)
    local h = assert(fs.open("wizard-events.jsonl", "a"))
    h.writeLine(textutils.serializeJSON({at=os.epoch("utc"), id=id, kind=kind, value=value}))
    h.close()
  end
  assert(cfg.enabled == true, "scenario requires explicit opt-in")
  assert(fs.getCapacity("/") == cfg.diskLimit, "native disk capacity differs from scenario limit")
  for _, path in ipairs({"ssot-auth.lua", "sha2.lua", "wh2-client.lua", "wh2-wizard-gate-bindings.lua"}) do
    assert(fs.exists(path), "missing authenticated prerequisite " .. path)
  end
  local binding = require("wh2-wizard-gate-bindings").open(cfg)
  assert(binding.authenticated == true, "binding must use authenticated transport")
  evidence("boot", {capacity=fs.getCapacity("/"), free=fs.getFreeSpace("/"), role=cfg.role})
  local function worker()
    if cfg.role == "server" then return assert(binding.server, "missing real SSOT server entry")() end
    local client = assert(binding.client, "missing shared authenticated wh2-client")
    local checks = require("wh2-wizard-gate-checks")
    local previous = read("wizard-result.json")
    local last = previous and previous.nonce or false
    while true do
      local command = read("wizard-command.json")
      if command and command.nonce ~= last then
        last = command.nonce
        local ok, err = pcall(function()
          if command.action == "report" then
            for _, item in ipairs(cfg.unknowns) do
              local reply = assert(client.call("wh2-unknown", {wh2=1, item=item, sampleLocationId="input:" .. id}))
              assert(reply.ok, reply.error)
            end
          elseif command.action == "answer" then checks.board(client, cfg.unknowns, evidence, binding.boardTerm)
          elseif command.action == "retained" then checks.retained(client, cfg.unknowns, evidence)
          elseif command.action == "fuzz" then checks.fuzz(client, evidence)
          elseif command.action == "stale" then checks.concurrent(client, evidence)
          elseif command.action == "revision" then
            local snapshot = assert(require("wh2-wizard-adapter").open({enabled=true, client=client}).snapshot())
            write("wizard-revision.json", {nonce=last, revision=snapshot.revision})
          elseif command.action == "race-answer" then
            local reply = assert(client.call("wh2-class", {wh2=1, item=command.item, baseRevision=command.baseRevision,
              value={class="misc", route="store", storeCategory="misc", recipeId=false}}))
            write("wizard-race.json", {nonce=last, reply=reply})
            evidence("racing-answer", reply)
          elseif command.action == "route" then
            assert(turtle, "routing requires a turtle")
            local api = require("wh2-wizard-adapter").open({enabled=true, client=client})
            local classes = assert(api.snapshot()).classes
            local moved = {}
            for slot = 1, 16 do
              turtle.select(slot)
              if turtle.getItemCount(slot) == 0 then turtle.suckUp() end
              local item = turtle.getItemDetail(slot)
              if item then
                local known = false
                for _, wanted in ipairs(cfg.unknowns) do if wanted == item.name then known = true end end
                if known and classes[item.name] and classes[item.name].route == "store" then
                  local before = item.count
                  turtle.dropDown()
                  moved[item.name] = (moved[item.name] or 0) + before - turtle.getItemCount(slot)
                end
              end
            end
            evidence("native-transfer", {moved=moved})
          elseif command.action == "snapshot" then
            local inventory = {}
            if turtle then
              for slot = 1, 16 do
                local row = turtle.getItemDetail(slot)
                if row then inventory[row.name] = (inventory[row.name] or 0) + row.count end
              end
            end
            write("wizard-inventory.json", {nonce=last, inventory=inventory})
          elseif command.action == "boundary" then
            assert(binding.boundary, "missing fleet/layout failure boundary adapter")(command.case, evidence)
          else error("unknown scenario action") end
        end)
        evidence("command", {nonce=last, action=command.action, ok=ok, error=not ok and tostring(err) or false})
        write("wizard-result.json", {nonce=last, ok=ok, error=not ok and tostring(err) or false})
      end
      sleep(0.1)
    end
  end
  local function metrics()
    while true do
      local inventory = {}
      if turtle then
        for slot = 1, 16 do
          local row = turtle.getItemDetail(slot)
          if row then inventory[row.name] = (inventory[row.name] or 0) + row.count end
        end
      end
      local serverMetrics = cfg.role == "server" and assert(binding.metrics, "missing real save-duration instrumentation")() or false
      evidence("metrics", {capacity=fs.getCapacity("/"), free=fs.getFreeSpace("/"), server=serverMetrics,
        stateBytes=fs.exists("ssot.state") and fs.getSize("ssot.state") or 0,
        inventory=inventory, fuel=turtle and turtle.getFuelLevel() or false})
      sleep(cfg.sampleSeconds)
    end
  end
  parallel.waitForAny(worker, metrics, assert(binding.receiver, "missing authenticated receiver"))
  error("scenario service stopped")
end

return M
