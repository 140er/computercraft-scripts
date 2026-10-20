local M = {}
local Wizard = require("wh2-wizard")
local Atomic = require("atomic")
local REQ, REP, CMD, ACK = "wh2_wizard_req", "wh2_wizard_rep", "wizard_cmd", "wizard_ack"

local function readJson(path)
  local file = fs.open(path, "r")
  if not file then return nil end
  local value = textutils.unserializeJSON(file.readAll())
  file.close()
  return value
end

local function writeJson(path, value)
  local file = assert(fs.open(path .. ".tmp", "w"))
  file.write(textutils.serializeJSON(value))
  file.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".tmp", path)
end

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do if not same(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

local function evidence(kind, value)
  local line = textutils.serializeJSON({at=os.epoch("utc"), id=os.getComputerID(), kind=kind, value=value})
  local file = assert(fs.open("wizard-events.jsonl", "a"))
  file.writeLine(line)
  file.close()
end

local function boardTerm()
  local target = peripheral.find("monitor") or term.current()
  local width, height = target.getSize()
  assert(width >= 26 and height >= 16, "board terminal is " .. width .. "x" .. height)
  return target
end

local function clientCall()
  local seq = 0
  return function(op, body)
    seq = seq + 1
    local id = seq
    rednet.send(0, {id=id, op=op, body=body}, REQ)
    local deadline = os.epoch("utc") + 8000
    while os.epoch("utc") < deadline do
      local sender, reply = rednet.receive(REP, 0.2)
      if sender == 0 and type(reply) == "table" and reply.id == id then return reply.result end
    end
    error("Server did not answer " .. op, 0)
  end
end

local handlers = {}

handlers.report = function(ctx)
  local inventory = require("wh2-wizard-gate-inventory")
  local before = inventory.snapshot().totals
  require("wh2-wizard-gate-checks").report(ctx.client, ctx.cfg.unknowns, evidence, {totals=before}, "input:" .. os.getComputerID())
  assert(same(before, inventory.snapshot().totals), "Unknown report moved a stack")
end

handlers.draft = function(ctx)
  local saved = require("wh2-wizard-gate-checks").draft(ctx.client, ctx.cfg.unknowns[1], evidence, boardTerm())
  saved.bootCount = ctx.bootCount
  writeJson("wizard-draft.json", saved)
end

handlers["draft-retained"] = function(ctx)
  local saved = assert(readJson("wizard-draft.json"), "Missing saved draft")
  assert(ctx.bootCount > saved.bootCount, "Draft retention did not cross a computer reboot")
  require("wh2-wizard-gate-checks").draftRetained(ctx.client, saved, evidence, boardTerm())
end

handlers["draft-owner"] = function(ctx)
  require("wh2-wizard-gate-checks").draftOwner(ctx.client, ctx.cfg.unknowns[1], evidence, boardTerm())
end

handlers.discard = function(ctx)
  require("wh2-wizard-gate-checks").discard(ctx.client, ctx.cfg.unknowns[1], evidence, boardTerm())
end

handlers["keep-local"] = function(ctx)
  local board = require("wh2-board").open({enabled=true, client=ctx.client, term=boardTerm()})
  board.tick()
  assert(board.state.draft and board.state.draft.stale, "expected the saved local edit to conflict")
  board.handle("char", "t")
  for _ = 1, 4 do board.tick() end
  local draft = board.state.draft
  assert(draft and not draft.stale and not draft.dirty, board.state.status)
  local question = require("wh2-wizard-gate-checks").snapshot(ctx.client).questions[draft.item]
  assert(question and question.state == "answering" and question.draft.editor == os.getComputerID(),
    "local edit was not kept")
  board.close()
end

handlers.answer = function(ctx)
  require("wh2-wizard-gate-checks").board(ctx.client, ctx.cfg.unknowns, evidence, boardTerm())
end

handlers.retained = function(ctx)
  require("wh2-wizard-gate-checks").retained(ctx.client, ctx.cfg.unknowns, evidence)
end

handlers.route = function(ctx)
  local inventory = require("wh2-wizard-gate-inventory")
  local checks = require("wh2-wizard-gate-checks")
  local plan = assert(readJson("wizard-plan.json"), "Missing fixture plan")
  local expected = {}
  for _, row in ipairs(plan.inventories[1].contents) do expected[row.item] = row.count end
  local moved = inventory.route(checks.snapshot(ctx.client).classes, ctx.cfg.unknowns, evidence)
  for _, item in ipairs(ctx.cfg.unknowns) do
    assert(moved.moved[item] == expected[item], item .. " moved " .. tostring(moved.moved[item]))
  end
end

handlers.fuzz = function(ctx)
  require("wh2-wizard-gate-checks").fuzz(ctx.client, evidence)
end

handlers.stale = function(ctx)
  require("wh2-wizard-gate-checks").concurrent(ctx.client, evidence)
end

handlers.reboot = function(ctx)
  ctx.reboot = true
end

handlers.done = function(ctx)
  ctx.finish = true
end

local function runClient(cfg, result)
  local boot = readJson("wizard-flow-boot.json") or {count=0}
  boot.count = boot.count + 1
  writeJson("wizard-flow-boot.json", boot)
  local ctx = {cfg=cfg, client={call=clientCall()}, bootCount=boot.count, finish=false, failed=false, reboot=false, last=""}
  local deadline = os.epoch("utc") + 160000
  while not ctx.finish and os.epoch("utc") < deadline do
    rednet.send(0, {kind="listening", boot=ctx.bootCount, role=cfg.role}, ACK)
    local sender, msg = rednet.receive(CMD, 0.3)
    if sender == 0 and type(msg) == "table" and type(msg.nonce) == "string" and type(msg.action) == "string" then
      if msg.nonce == ctx.last and ctx.lastAck then
        rednet.send(0, ctx.lastAck, ACK)
      else
        local action = handlers[msg.action] or function() error("Unknown scenario action " .. msg.action, 0) end
        local ok, err = pcall(action, ctx)
        ctx.failed = ctx.failed or not ok
        if not ok then result.errors[#result.errors + 1] = tostring(err) end
        ctx.last = msg.nonce
        ctx.lastAck = {kind="ack", nonce=msg.nonce, ok=ok, error=not ok and tostring(err) or false}
        rednet.send(0, ctx.lastAck, ACK)
        result.lines[#result.lines + 1] = msg.action .. (ok and "" or " failed")
        if ok and ctx.reboot then
          -- The ack has to leave the modem before reboot drops this computer.
          sleep(0.5)
          os.reboot()
        end
      end
    end
  end
  if not ctx.finish then error("Scenario client timed out", 0) end
  result.ok = not ctx.failed
end

local function validAuthority(value)
  return type(value) == "table" and type(value.wh2) == "table" and value.wh2.schema == 1
    and Wizard.valid(value.wh2.wizard)
end

local function runServer(cfg, result)
  local operators = {}
  for key, allowed in pairs(cfg.operators or {}) do
    if allowed == true then operators[tostring(key)] = true end
  end
  local session = {
    running = true,
    state = {wh2={schema=1}},
    ctx = {epoch=1, now=os.epoch("utc"), config={enabled=true, operators=operators}},
    store = Atomic.store("wh2-wizard-authority", validAuthority, 200000),
  }
  if session.store.value then session.state = session.store.value end
  local function serve()
    while session.running do
      local sender, msg = rednet.receive(REQ, 0.2)
      if type(msg) == "table" and type(msg.id) == "number" and type(msg.op) == "string" and type(msg.body) == "table" then
        session.ctx.now = os.epoch("utc")
        local reply = Wizard.run(session.state, sender, {op=msg.op, body=msg.body}, session.ctx)
        if reply.ok then
          local saved, err = session.store.save(session.state)
          if not saved then error(err or "Authority save failed", 0) end
        end
        rednet.send(sender, {id=msg.id, result=reply}, REP)
      end
    end
  end
  local function command(id, action)
    local nonce = action .. ":" .. id .. ":" .. os.epoch("utc") .. ":" .. math.random(1, 1000000)
    local deadline = os.epoch("utc") + 30000
    while os.epoch("utc") < deadline do
      rednet.send(id, {action=action, nonce=nonce}, CMD)
      local sender, msg = rednet.receive(ACK, 0.3)
      if sender == id and type(msg) == "table" and msg.kind == "ack" and msg.nonce == nonce then
        if not msg.ok then error(msg.error or action .. " failed", 0) end
        result.lines[#result.lines + 1] = action .. ":" .. id
        return
      end
    end
    error("No ack for " .. action .. " from " .. id, 0)
  end
  local function waitListening(minBoot)
    local seen = {}
    local deadline = os.epoch("utc") + 30000
    while os.epoch("utc") < deadline do
      local sender, msg = rednet.receive(ACK, 0.2)
      if type(msg) == "table" and msg.kind == "listening" and (msg.boot or 0) >= (minBoot[sender] or 1) then
        seen[sender] = true
      end
      local ready = true
      for id = 1, 6 do if not seen[id] then ready = false end end
      if ready then return end
    end
    error("A sandbox computer did not start", 0)
  end
  local function waitBoot(id, count)
    local deadline = os.epoch("utc") + 30000
    while os.epoch("utc") < deadline do
      local sender, msg = rednet.receive(ACK, 0.2)
      if sender == id and type(msg) == "table" and msg.kind == "listening" and (msg.boot or 0) >= count then return end
    end
    error("Computer " .. id .. " did not reboot", 0)
  end
  local function reload()
    local stored = Atomic.read("wh2-wizard-authority")
    assert(stored and stored.schema == 1 and validAuthority(stored.value), "Saved authority is invalid")
    assert(same(stored.value.wh2.wizard, session.state.wh2.wizard), "Saved authority differs from memory")
    session.state = stored.value
    result.lines[#result.lines + 1] = "reloaded-authority"
  end
  local steps = {
    function() for id = 1, 4 do command(id, "report") end end,
    function() command(5, "draft") end,
    function() for id = 1, 4 do command(id, "report") end end,
    function() command(5, "reboot") end,
    function() waitBoot(5, 2) end,
    function() command(5, "draft-retained") end,
    function() command(6, "draft-owner") end,
    function() command(6, "discard") end,
    function() command(5, "keep-local") end,
    function() command(5, "discard") end,
    function() command(5, "answer") end,
    reload,
    function() for id = 1, 4 do command(id, "retained") end end,
    function() for id = 1, 4 do command(id, "route") end end,
    function() command(6, "fuzz") end,
    function() command(6, "stale") end,
  }
  local ran, why = pcall(function()
    parallel.waitForAny(serve, function()
      waitListening({})
      for _, step in ipairs(steps) do step() end
      result.ok = true
    end)
  end)
  session.running = false
  for id = 1, 6 do pcall(command, id, "done") end
  if not ran then error(why, 0) end
end

function M.run(cfg)
  local result = {ok=false, booted=true, role=cfg.role, errors={}, lines={},
    capacity=fs.getCapacity("/"), free=fs.getFreeSpace("/"), transport="rednet"}
  local ok, err = pcall(cfg.role == "server" and runServer or runClient, cfg, result)
  if not ok then
    result.ok = false
    result.errors[#result.errors + 1] = tostring(err)
  end
  result.free = fs.getFreeSpace("/")
  return result
end

return M
