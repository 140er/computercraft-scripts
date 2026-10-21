local D = dofile("depth-result.lua")
local A = dofile("atomic.lua")
local hours = 2
local started = os.epoch("utc")
local store = A.mount("/"):open("soak.state", function(v)
  return type(v) == "table" and type(v.n) == "number"
end, { class = "bulk", limit = 8192 })
local handle = fs.open("soak-log.jsonl", "w")
handle.close()
local n = 0
while os.epoch("utc") - started < hours * 3600 * 1000 do
  n = n + 1
  local before = os.epoch("utc")
  local saved = store:save({ n = n, at = before })
  local elapsed = os.epoch("utc") - before
  local line = textutils.serializeJSON({
    n = n, saveMs = elapsed, bytes = #textutils.serialize({ n = n, at = before }), saved = saved and true or false,
  })
  handle = fs.open("soak-log.jsonl", "a")
  handle.writeLine(line)
  handle.close()
  sleep(60)
end
local checks = {}
D.check(checks, "soak ran for two hours", os.epoch("utc") - started >= hours * 3600 * 1000, "short run")
D.check(checks, "soak logged save time", n >= 2, tostring(n))
D.finish(checks)
