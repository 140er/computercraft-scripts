local Ledger = dofile("storage-ledger.lua")
local Buffer = dofile("storage-buffer.lua")
local View = dofile("storage-view.lua")
local Dep = dofile("lib/stubs/h4c_dep.lua")

local M = {}

local function usage(host)
  return Dep.h4a.usage(host.fs)
end

function M.create(opts)
  opts = opts or {}
  local policy, err = Ledger.parsePolicy(opts.policy or Ledger.defaults())
  if not policy then return nil, err end
  return {
    enabled = opts.enabled == nil or opts.enabled == true,
    policy = policy,
    fs = opts.fs or {
      getCapacity = function() return "unlimited" end,
      getFreeSpace = function() return "unlimited" end,
    },
    sections = Dep.h4b1.new(),
    pinned = opts.pinned or {},
    decision = { v = 1, choice = false, at = 0 },
    samples = {},
    now = opts.now or 0,
    seq = 0,
    preview = false,
    buffer = false,
  }
end

function M.ledger(host)
  local reading, err = usage(host)
  if not reading then return nil, err end
  local ledger, why = Ledger.ledger(host.policy, reading, host.decision, host.samples, host.now)
  if not ledger then return nil, why end
  if not host.enabled then ledger.state = "ok" end
  return ledger
end

function M.admit(host, op)
  local ledger, err = M.ledger(host)
  if not ledger then
    if host.enabled then return { ok = false, error = err } end
    return { ok = true }
  end
  return Ledger.admit(host.enabled, ledger, Dep.h4a.kind(op))
end

local function choose(host, choice)
  if not host.enabled then return nil, "storage ledger is off" end
  host.decision = { v = 1, choice = choice, at = host.now }
  return M.ledger(host)
end

function M.decline(host) return choose(host, "decline") end
function M.expand(host) return choose(host, "expand") end

function M.note(host)
  local reading, err = usage(host)
  if not reading then return nil, err end
  Ledger.note(host.samples, host.now, reading.unlimited and 0 or reading.used)
  return M.ledger(host)
end

function M.putSection(host, raw)
  local section, err = Ledger.parseSection(raw)
  if not section then return nil, err end
  Dep.h4b1.put(host.sections, section)
  return section
end

function M.readSection(host, key)
  return Dep.h4b1.read(host.sections, key)
end

function M.previewForget(host, olderThanMs)
  if not host.enabled then return nil, "storage ledger is off" end
  local list = Dep.h4b1.list(host.sections)
  local rev = 0
  for i = 1, #list do if list[i].rev > rev then rev = list[i].rev end end
  local age = olderThanMs
  if age == nil then age = host.policy.forgetOlderThanMs end
  if age == false or age == nil then return nil, "age required" end
  host.seq = host.seq + 1
  local pinned = Dep.h5.pinnedKeys(host.pinned, host.now)
  local preview, err = Ledger.preview(list, host.now, age, rev, host.seq, pinned)
  if not preview then
    host.seq = host.seq - 1
    return nil, err
  end
  host.preview = preview
  return preview
end

function M.commitForget(host, preview)
  if not host.enabled then return nil, "storage ledger is off" end
  local list = Dep.h4b1.list(host.sections)
  local pinned = Dep.h5.pinnedKeys(host.pinned, host.now)
  local plan, err = Ledger.commit(preview, list, pinned, host.now)
  if not plan then return nil, err end
  local deleted, skipped = {}, {}
  for i = 1, #plan.skipped do skipped[i] = plan.skipped[i] end
  for i = 1, #plan.delete do
    local item = plan.delete[i]
    if Dep.h4b1.forget(host.sections, item.key, item.rev, item.hash) == "deleted" then
      deleted[#deleted + 1] = item.key
    else
      skipped[#skipped + 1] = { key = item.key, reason = "mismatch" }
    end
  end
  local ledger = M.ledger(host)
  if ledger and ledger.state == "ok" then
    host.decision = { v = 1, choice = false, at = host.now }
  end
  return { v = 1, deleted = deleted, skipped = skipped }
end

function M.openBuffer(host, reserve)
  if host.buffer then return host.buffer end
  local reading, err = usage(host)
  if not reading then return nil, err end
  local free = reading.unlimited and "unlimited" or reading.free
  host.buffer = Buffer.open(free, reserve or host.policy.controlReserve)
  return host.buffer
end

function M.pushObs(host, obs)
  if not host.buffer then
    local buf, err = M.openBuffer(host)
    if not buf then return nil, err end
  end
  return Buffer.push(host.buffer, obs)
end

function M.loadBuffer(host, raw)
  local reading, err = usage(host)
  if not reading then return nil, err end
  local free = reading.unlimited and "unlimited" or reading.free
  local buf, why = Buffer.read(raw, free, host.policy.controlReserve)
  if not buf then return nil, why end
  host.buffer = buf
  return buf
end

function M.prompt(host)
  local ledger = M.ledger(host)
  return View.prompt(ledger, host.enabled)
end

function M.lines(host)
  return View.lines(M.ledger(host), host.preview, host.enabled)
end

function M.due(lastAt, now)
  return View.due(lastAt, now)
end

return M
