-- Bounded reference model checked against the unmodified lease module.
local sourcePath, witness = arg[1], arg[2]
local file = assert(io.open(sourcePath, "rb"))
local source = file:read("*a")
file:close()
local factory = assert(load("return function(_ENV)\n" .. source .. "\nend", sourcePath, "t"))()
local steps = { { op = "forward" } }
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end
local function signature(value)
  local out = {}
  for k, v in pairs(value) do out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
  table.sort(out)
  return table.concat(out, ",")
end
local checks, traces = 0, 0
local function run(trace, foreign, batchSize, grace, exhaustive)
  steps = {}
  for i = 1, batchSize do steps[i] = { op = "forward" } end
  local actual = { now = 0, cells = {}, calls = {}, ids = {} }
  local model = { now = 0, seq = 0, durableSeq = 0, cells = {}, calls = {}, ids = {}, uncertain = false }
  local lease
  local function boot()
    local env = setmetatable({
      os = { epoch = function() return actual.now end }, print = function() end,
      rednet = { send = function() return true end },
      SO = { now = function() return actual.now end,
        store = { copy = copy, read = function() return { pos = { x = 0, y = 0, z = 0 } } end,
          store = function(_, valid)
            assert(not actual.disk or valid(actual.disk))
            return {value=copy(actual.disk),save=function(value)
              if actual.failSave then return false,"disk" end
              if not valid(value) then return false,"invalid state" end
              actual.disk=copy(value)
              return true
            end}
          end },
        pair = { key = function() return "paired" end },
        proto = { build = function(_, kind, body) return { kind = kind, body = body } end,
          encode = function(value) return value end },
        mods = { cells = { releaseOwner = function(id) actual.cells[id] = nil end } },
      },
    }, { __index = _G })
    lease = factory(env)
    lease.onReport("mine", function(id, _, results)
      actual.calls[#actual.calls + 1] = id .. (results and ":report" or ":expire")
    end)
  end
  boot()
  local prefix = {}
  local function equal(property, got, want)
    checks = checks + 1
    if got ~= want then
      error("PROPERTY " .. property .. " trace=" .. table.concat(prefix, ",")
        .. " foreign=" .. foreign .. " batch=" .. batchSize .. " grace=" .. grace
        .. " actual=" .. tostring(got) .. " expected=" .. tostring(want), 0)
    end
  end
  local function step(action)
    prefix[#prefix + 1] = action
    if action == "send_a" or action == "send_b" then
      local expected, reason
      if model.uncertain then reason = "pose uncertain"
      elseif model.lost then reason = "lost"
      elseif model.open then reason = "busy"
      elseif model.terminal then reason = "lease outcome pending"
      elseif model.recovering then reason = "restart needs fenced observation"
      else
        model.seq = model.seq + 1
        expected = string.format("2-%.0f-%d", model.now, model.seq)
        if actual.failSave then expected, reason = nil, "disk"
        else
          model.open, model.expires, model.durableSeq, model.restored = expected, model.now+1000, model.seq, false
          model.leaseJournal = model.capabilities and model.journal or nil
          model.proof = nil
          model.cells["mine:2"] = true
        end
      end
      local id, err = lease.send(2, steps, { owner = "mine", ms = 1000 })
      local property = model.uncertain and "uncertainty" or "dispatch"
      equal(property, id, expected)
      equal(property, err, reason)
      actual.ids[action], model.ids[action] = id, expected
      if id then actual.cells["mine:2"] = true end
    elseif action == "restart" or action == "restart2" then
      boot()
      model.lost = model.open ~= nil or model.terminal ~= nil or model.recovering == true
      model.uncertain = model.terminal and model.terminalUncertain or false
      model.seq, model.restored = model.durableSeq, model.lost
      model.journal, model.capabilities, model.proof = nil, false, nil
    elseif action == "forget" then
      local pending = model.open or model.terminal or model.recovering
      local saved = not (pending and actual.failSave)
      local ok = lease.forget(2)
      equal("recovery_forget",ok ~= false,saved)
      if saved and pending then
        model.open, model.terminal, model.recovering, model.restored = nil, nil, false, false
        model.durableSeq = model.seq
        equal("recovery_forget",next(actual.disk.records),nil)
      end
      if saved then model.uncertain, model.lost = true, true end
    elseif action == "expire" or action == "tick_early" then
      actual.now, model.now = action == "tick_early" and 50 or grace, action == "tick_early" and 50 or grace
      lease.tick(actual.now)
      if model.open and (model.now > model.expires + 10000 or model.proof) and not actual.failSave then
        model.calls[#model.calls + 1] = model.open .. ":expire"
        model.terminal, model.terminalUncertain, model.open, model.terminalStatus = model.open, false, nil, "expired"
        model.proof = nil
      end
    elseif action == "fail_save" then actual.failSave=true
    elseif action == "save_ok" then actual.failSave=false
    elseif action == "hello" or action == "hello_changed" or action == "hello_pending" then
      local journal = action == "hello" and "journal" or "changed"
      local pending = action == "hello_pending" and {op="forward"} or nil
      lease.handlers.hello({from=2,body={journal={id=journal,pose={x=0,y=0,z=0,f=0},pending=pending},capabilities={parkBatch=true,setupFence=true}}})
      model.uncertain, model.lost, model.journal, model.capabilities = false, false, journal, true
      if model.restored and model.open and model.leaseJournal and journal ~= model.leaseJournal and not pending then model.proof = true end
    elseif action == "ack" then
      local record = lease.outcome(2)
      if model.terminal then
        equal("restart_ack",record and record.id,model.terminal)
        local ok, err = lease.ackOutcome(record.id)
        equal("restart_ack",ok,not actual.failSave)
        equal("restart_ack",err,actual.failSave and "disk" or nil)
        if not actual.failSave then
          model.recovering, model.terminal = model.terminalStatus == "expired" or model.restored == true, nil
          model.durableSeq = model.seq
        end
      else equal("restart_ack",record,nil) end
    elseif action == "uncertain" then
      lease.handlers.hello({ from = 2, body = { journal = { id = "journal", uncertain = true } } })
      model.uncertain, model.lost, model.journal, model.capabilities = true, false, "journal", false
    else
      local id = actual.ids.send_a or "not-issued"
      local expectedId = model.ids.send_a or "not-issued"
      local sender, results = 2, {}
      for i = 1, batchSize do results[i] = { ok = true } end
      if action == "foreign" then
        if foreign == "wrong-id" then id, expectedId = "foreign", "foreign"
        elseif foreign == "wrong-sender" then sender = 3
        else results = {} end
      end
      lease.handlers["step.report"]({ from = sender, body = { lease = id, results = results } })
      if sender == 2 and expectedId == model.open and #results == batchSize and not actual.failSave then
        model.calls[#model.calls + 1] = model.open .. ":report"
        model.proof = nil
        model.terminal, model.terminalUncertain, model.open, model.uncertain, model.lost, model.terminalStatus = model.open, false, nil, false, model.restored == true, "reported"
      end
    end
    local status = lease.status(2)
    equal((action=="restart" or action=="restart2") and "restart_restore" or "report_integrity", status.open, model.open)
    local outcome=lease.outcome(2)
    equal("restart_ack",outcome and outcome.id,model.terminal)
    equal("uncertainty", not not status.uncertain, model.uncertain)
    local property = (action == "expire" or action == "restart")
      and "reservation_retention" or "report_integrity"
    equal(property, signature(actual.cells), signature(model.cells))
    equal("callback_once", table.concat(actual.calls, ","), table.concat(model.calls, ","))
  end
  if exhaustive then
    local actions = trace
    local used = {}
    local function stateOf()
      for i=1,10 do
        local name, value = debug.getupvalue(lease.send,i)
        if name == "S" then return value end
      end
      error("lease state upvalue missing")
    end
    local function visit(depth)
      if depth > #actions then traces=traces+1 return end
      local state = stateOf()
      local savedActual, savedModel, savedPrefix = copy(actual), copy(model), copy(prefix)
      local savedRows, savedValue, savedSeq, savedBox = copy(state.turtles), copy(state.saved), state.seq, state.box
      local savedLease = lease
      for i, action in ipairs(actions) do
        if not used[i] then
          used[i] = true
          step(action)
          visit(depth+1)
          actual, model, prefix, lease = copy(savedActual), copy(savedModel), copy(savedPrefix), savedLease
          state.turtles, state.saved, state.seq, state.box = copy(savedRows), copy(savedValue), savedSeq, savedBox
          used[i] = nil
        end
      end
    end
    visit(1)
  else
    for _, action in ipairs(trace) do step(action) end
    traces=traces+1
  end
  return actual
end
local witnesses = {
  dispatch = { "send_a", "send_b" },
  report_integrity = { "send_a", "foreign" },
  reservation_retention = { "send_a", "expire" },
  uncertainty = { "uncertain", "send_a" },
  callback_once = { "send_a", "report_a", "report_again" },
  restart_restore = {"send_a","restart"},
  recovery_forget = {"send_a","forget","restart","hello","send_b"},
}
local foreign, batch, grace = (witness or ""):match("^partition:([^:]+):(%d+):(%d+)$")
if foreign then
  run({"send_a","send_b","report_a","report_again","foreign","expire","restart","uncertain"},foreign,tonumber(batch),tonumber(grace),true)
elseif witness == "restarts:1" or witness == "restarts:16" then
  local size=tonumber(witness:match("%d+"))
  run({"send_a","report_a","expire","ack","restart","restart2","hello"},"wrong-id",size,11001,true)
elseif witness == "journal-recovery" then
  for _,trace in ipairs({
    {"hello","send_a","restart","hello_changed","tick_early","ack","restart2","hello","send_b"},
    {"hello","send_a","restart","hello_pending","tick_early","send_b"},
    {"hello","send_a","restart","hello_changed","fail_save","tick_early","save_ok","tick_early","ack"},
  }) do run(trace,"wrong-id",1,11001) end
elseif witness == "recovery" then
  for _,size in ipairs({1,16}) do
    for _,trace in ipairs({
      {"send_a","forget","restart","hello","send_b"},
      {"send_a","report_a","forget","restart","hello","send_b"},
      {"send_a","expire","ack","forget","restart","hello","send_b"},
      {"send_a","fail_save","forget","save_ok","restart","hello","forget","restart2","hello","send_b"},
    }) do run(trace,"wrong-id",size,11001) end
  end
elseif witness == "failures" then
  for _,size in ipairs({1,16}) do
    for _,trace in ipairs({
      {"fail_save","send_a","restart","save_ok","hello","send_b"},
      {"send_a","fail_save","report_a","restart","save_ok","hello","report_a","ack","restart2"},
      {"send_a","fail_save","expire","restart","save_ok","hello","expire","ack","restart2"},
      {"send_a","report_a","fail_save","ack","restart","save_ok","hello","ack","restart2","send_b","report_a"},
      {"send_a","restart","hello","report_a","ack","restart2","hello","send_b","report_a"},
    }) do run(trace,"wrong-id",size,11001) end
  end
elseif witness then
  run(assert(witnesses[witness],"unknown witness"),"wrong-id",1,11001)
else
  error("run through formal/verify_lease.py to enumerate all partitions")
end
print("PASS traces=" .. traces .. " comparisons=" .. checks)
