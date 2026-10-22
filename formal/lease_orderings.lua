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
local function run(trace, foreign, batchSize, grace)
  steps = {}
  for i = 1, batchSize do steps[i] = { op = "forward" } end
  local actual = { now = 0, cells = {}, calls = {}, ids = {} }
  local model = { now = 0, seq = 0, cells = {}, calls = {}, ids = {}, uncertain = false }
  local lease
  local function boot()
    local env = setmetatable({
      os = { epoch = function() return actual.now end }, print = function() end,
      rednet = { send = function() return true end },
      SO = { now = function() return actual.now end,
        store = { copy = copy, read = function() return { pos = { x = 0, y = 0, z = 0 } } end },
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
  for _, action in ipairs(trace) do
    prefix[#prefix + 1] = action
    if action == "send_a" or action == "send_b" then
      local expected, reason
      if model.uncertain then reason = "pose uncertain"
      elseif model.open then reason = "busy"
      else
        model.seq = model.seq + 1
        expected = string.format("2-%.0f-%d", model.now, model.seq)
        model.open, model.expires = expected, model.now + 1000
        model.cells[expected] = true
      end
      local id, err = lease.send(2, steps, { owner = "mine", ms = 1000 })
      local property = model.uncertain and "uncertainty" or "dispatch"
      equal(property, id, expected)
      equal(property, err, reason)
      actual.ids[action], model.ids[action] = id, expected
      if id then actual.cells[id] = true end
    elseif action == "restart" then
      boot()
      model.open, model.expires, model.seq, model.uncertain = nil, nil, 0, false
    elseif action == "expire" then
      actual.now, model.now = grace, grace
      lease.tick(actual.now)
      if model.open and model.now > model.expires + 10000 then
        model.calls[#model.calls + 1] = model.open .. ":expire"
        model.open = nil
      end
    elseif action == "uncertain" then
      lease.handlers.hello({ from = 2, body = { journal = { id = "journal", uncertain = true } } })
      model.uncertain = true
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
      if sender == 2 and expectedId == model.open and #results == batchSize then
        model.cells[model.open] = nil
        model.calls[#model.calls + 1] = model.open .. ":report"
        model.open, model.uncertain = nil, false
      end
    end
    local status = lease.status(2)
    equal("report_integrity", status.open, model.open)
    equal("uncertainty", not not status.uncertain, model.uncertain)
    local property = (action == "expire" or action == "restart")
      and "reservation_retention" or "report_integrity"
    equal(property, signature(actual.cells), signature(model.cells))
    equal("callback_once", table.concat(actual.calls, ","), table.concat(model.calls, ","))
  end
  traces = traces + 1
  return actual
end
local witnesses = {
  dispatch = { "send_a", "send_b" },
  report_integrity = { "send_a", "foreign" },
  reservation_retention = { "send_a", "expire" },
  uncertainty = { "uncertain", "send_a" },
  callback_once = { "send_a", "report_a", "report_again" },
}
if witness then
  run(assert(witnesses[witness], "unknown witness"), "wrong-id", 1, 11001)
else
  local actions = { "send_a", "send_b", "report_a", "report_again", "foreign", "expire", "restart", "uncertain" }
  local trace, used = {}, {}
  local function visit(depth)
    if depth > #actions then
      for _, foreign in ipairs({ "wrong-id", "wrong-sender", "malformed" }) do
        for _, batchSize in ipairs({ 1, 16 }) do
          for _, grace in ipairs({ 11000, 11001 }) do run(trace, foreign, batchSize, grace) end
        end
      end
      return
    end
    for i, action in ipairs(actions) do
      if not used[i] then
        used[i], trace[depth] = true, action
        visit(depth + 1)
        used[i] = nil
      end
    end
  end
  visit(1)
  local collision = run({ "send_a", "restart", "send_b", "report_a" }, "wrong-id", 1, 11001)
  assert(collision.ids.send_a == collision.ids.send_b and #collision.calls == 1)
  print("FINDING restart-id-reuse at fixed clock send_a=" .. collision.ids.send_a
    .. " restart send_b=" .. collision.ids.send_b .. " old_report_a closes send_b")
end
print("PASS traces=" .. traces .. " comparisons=" .. checks)
