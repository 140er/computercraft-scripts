local result = { ok = false, errors = {}, capacity = 0, used = 0, deleted = {}, survived = {} }

local function fail(msg)
  result.errors[#result.errors + 1] = tostring(msg)
end

local function check(cond, msg)
  if not cond then fail(msg) end
end

local ok, err = pcall(function()
  local cap = fs.getCapacity("/")
  result.capacity = cap
  check(cap == 1000000, "capacity " .. tostring(cap))
  local function used()
    return cap - fs.getFreeSpace("/")
  end
  local target = math.floor(cap * 0.8)
  local need = target - used()
  if need > 0 then
    local handle = fs.open("pad", "w")
    local chunk = string.rep("x", 4096)
    while need > 0 do
      local n = need
      if n > 4096 then n = 4096 end
      handle.write(n == 4096 and chunk or chunk:sub(1, n))
      need = need - n
      if need % 65536 == 0 then sleep(0) end
    end
    handle.close()
  end
  result.used = used()
  check(result.used >= target, "used " .. tostring(result.used))

  local Host = dofile("storage-host.lua")
  local server, why = Host.create({ enabled = true, fs = fs, now = os.epoch("utc") })
  check(server ~= nil, why)
  if not server then return end
  local ledger = Host.ledger(server)
  check(ledger.state == "warn", "state " .. tostring(ledger.state))
  check(ledger.localTotal == 1000000, "total")
  local offered = Host.prompt(server)
  check(offered.choices[2] and offered.choices[2].label == "Needs storage turtles", "expand label")
  local mapWrite = Host.admit(server, "scan")
  check(mapWrite.ok == false and mapWrite.error == "capacity", "map write " .. tostring(mapWrite.error))
  check(Host.admit(server, "commit").ok == true, "control write")
  check(Host.decline(server).state == "paused", "decline")
  check(Host.admit(server, "observe").error == "capacity", "still paused")
  check(Host.admit(server, "sync").ok == true, "sync while paused")

  local function hash(n)
    return string.format("%064x", n)
  end
  local function section(key, rev, at)
    return { v = 2, key = key, rev = rev, hash = hash(rev), bytes = 100, observedAt = at }
  end
  local now = server.now
  local old = now - 100000
  local keep = "abs|minecraft:overworld|1|4|-2"
  local dropA = "abs|minecraft:overworld|2|4|-2"
  local dropB = "abs|minecraft:overworld|3|4|-2"
  local fresh = "abs|minecraft:overworld|4|4|-2"
  check(Host.putSection(server, section(dropA, 1, old)) ~= nil, "put a")
  check(Host.putSection(server, section(dropB, 2, old)) ~= nil, "put b")
  check(Host.putSection(server, section(keep, 4, old)) ~= nil, "put c")
  check(Host.putSection(server, section(fresh, 3, now)) ~= nil, "put d")
  local preview, previewErr = Host.previewForget(server, 100000)
  check(preview ~= nil, previewErr)
  if not preview then return end
  result.preview = {}
  for i = 1, #preview.items do result.preview[i] = preview.items[i].key end
  local changed = section(keep, 9, old)
  changed.hash = hash(99)
  check(Host.putSection(server, changed) ~= nil, "change")
  local committed, commitErr = Host.commitForget(server, preview)
  check(committed ~= nil, commitErr)
  if not committed then return end
  result.deleted = committed.deleted
  check(#committed.deleted == 2, "deleted count " .. #committed.deleted)
  check(Host.readSection(server, dropA).confidence == "unknown", "a unknown")
  check(Host.readSection(server, dropB).confidence == "unknown", "b unknown")
  local survived = Host.readSection(server, keep)
  result.survived = { key = keep, rev = survived.rev, confidence = survived.confidence }
  check(survived.confidence == "observed" and survived.rev == 9, "changed section")
  check(Host.readSection(server, fresh).confidence == "observed", "fresh section")
  local lines = table.concat(Host.lines(server), "\n")
  check(lines:find("storage turtles", 1, true) ~= nil, lines)
  local prompt = Host.prompt(server)
  check(#prompt.choices == 0, "choice closed after decline")

  local buf = Host.openBuffer(server)
  check(buf.budget == fs.getFreeSpace("/") - 65536, "budget " .. tostring(buf.budget))
  local fit = { id = 1, bytes = buf.budget, name = "minecraft:stone" }
  local accepted, effects = Host.pushObs(server, fit)
  check(accepted == true, "fit")
  local extra = { id = 2, bytes = 1, name = "minecraft:dirt" }
  accepted, effects = Host.pushObs(server, extra)
  check(accepted == false, "full")
  check(extra.name == "minecraft:dirt", "kept by caller")
  check(effects[1].op == "stop_mining" and effects[2].op == "head_home", "stop")
  check(effects[3].panel == true and effects[3].glasses == true and effects[3].chat == true, "notify")
  check(#server.buffer.items == 1, "stored one")
end)

if not ok then fail(err) end
result.ok = ok and #result.errors == 0
local handle = fs.open("sandbox-result.json", "w")
handle.write(textutils.serializeJSON(result))
handle.close()
os.shutdown()
