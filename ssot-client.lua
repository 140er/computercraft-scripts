local M = {}
local A = dofile("atomic.lua")
local S = dofile("ssot.lua")
function M.new(cfg)
  assert(type(cfg.server) == "number" and type(cfg.secret) == "string" and #cfg.secret >= 16, "pair SSOT first")
  local boot = tostring(os.epoch("utc")) .. ":" .. os.getComputerID()
  local pending, busy, moving, stopped = {}, false, false, false
  local path = cfg.counterFile or "ssot.counter"
  local store = A.mount("/"):open(path, function(v)
    return type(v) == "table" and type(v.counter) == "number" and v.counter >= 0 and v.counter % 1 == 0
  end, { class = "control", limit = 8192 })
  local journal = store.value or { counter = 0 }
  local synced = false
  local api = {}
  function api.dispatch(sender, m, protocol)
    if sender ~= cfg.server or protocol ~= "fleetserver" or type(m) ~= "table" or m.v ~= 1
      or m.type ~= "ssot_reply" or m.server ~= cfg.server or type(m.rid) ~= "string"
      or m.auth ~= cfg.secret
      or type(m.ok) ~= "boolean" or not S.bounded(m, 32768)
      or #textutils.serialize(m,{compact=true})>8192 then return false end
    local slot = pending[m.rid]
    if slot and not slot.result then slot.result = m os.queueEvent("ssot_reply", m.rid) return true end
    return false
  end
  function api.call(op, fields)
    if busy then return nil, "SSOT busy" end
    busy = true
    journal.counter = journal.counter + 1
    local ok, err = store:save(journal)
    if not ok then busy = false return nil, tostring(err) end
    local rid = boot .. ":" .. journal.counter
    local m = {}
    for k, v in pairs(fields or {}) do m[k] = v end
    m.type, m.v, m.op, m.rid = "ssot", 1, op, rid
    m.counter, m.boot, m.secret, m.expect = journal.counter, boot, cfg.secret, "ssot_reply"
    if not S.bounded(m, 32768) or #textutils.serialize(m, { compact = true }) > 8192 then
      busy = false return nil, "invalid request"
    end
    local slot = {} pending[rid] = slot
    for _ = 1, 3 do
      rednet.send(cfg.server, m, "fleetserver")
      local timer = os.startTimer(cfg.timeout or 1)
      while not slot.result do
        local event, value = os.pullEvent()
        if event == "timer" and value == timer then break end
      end
      os.cancelTimer(timer)
      if slot.result then break end
    end
    pending[rid], busy = nil, false
    if not slot.result then return nil, "SSOT timeout (stopped)" end
    return slot.result, slot.result.error
  end
  for _, op in ipairs({ "sync", "reserve", "start", "commit", "release", "renew", "scan", "snapshot" }) do
    api[op] = function(fields) return api.call(op, fields) end
  end
  local function resync(pose,previous)
    synced = false
    local fields={pose=pose,previous=previous}
    if previous and journal.move then fields.token,fields.epoch=journal.move.token,journal.move.epoch end
    local r, err = api.call(previous and "calibrate" or "sync",fields)
    if not r or not r.ok then return false, err end
    journal.move = nil
    local ok, why = store:save(journal)
    synced = ok
    return ok, why, r.epoch
  end
  function api.resync(pose)
    if moving then return false,"SSOT movement busy" end
    return resync(pose)
  end
  function api.calibrate(pose,previous)
    if moving then return false,"SSOT movement busy" end
    local ok,why,epoch=resync(pose,previous)
    if ok then stopped=false end
    return ok,why,epoch
  end
  local function move(from, to, execute)
    from, to = A.copy(from), A.copy(to)
    if not synced then
      local ok, why = resync(from)
      if not ok then return false, why end
    end
    local grant, why = api.reserve({ pose = from, to = to })
    if not grant or not grant.ok then return false, why end
    local fields = { pose = from, to = to, token = grant.token, epoch = grant.epoch }
    journal.move = A.copy(fields)
    assert(store:save(journal))
    local started = api.start(fields)
    if not started or not started.ok or type(started.untilAt) ~= "number"
      or started.untilAt <= os.epoch("utc") + 250 then synced = false return false, "start unconfirmed" end
    local moved, err = execute()
    journal.move.observed = moved and to or from
    assert(store:save(journal))
    if moved then
      local committed = api.commit(fields)
      if not committed or not committed.ok then
        synced = false
        error("Physical move completed; SSOT reconciliation required: " .. tostring(committed and committed.error or "timeout"), 0)
      end
    else
      local ok = resync(from)
      if not ok then synced = false return false, "failed move needs reconciliation" end
    end
    journal.move = nil
    assert(store:save(journal))
    return moved, err
  end
  function api.move(from,to,execute)
    if stopped then return false, "SSOT movement stopped; reboot and reconcile" end
    if busy or moving then return false, "SSOT busy" end
    moving=true
    local ok,moved,err=pcall(move,from,to,execute)
    moving=false
    if not ok then stopped=true synced=false error(moved,0) end
    return moved,err
  end
  return api
end
return M
