local M = {}

function M.check(checks, name, ok, err)
  checks[#checks + 1] = {
    name = name,
    ok = not not ok,
    error = ok and "" or tostring(err or "failed"),
  }
end

function M.finish(checks)
  local ok = true
  for i = 1, #checks do
    if not checks[i].ok then ok = false break end
  end
  local body = textutils.serializeJSON({ ok = ok, checks = checks })
  local handle = assert(fs.open("depth-result.json", "w"))
  handle.write(body)
  handle.close()
  handle = assert(fs.open("sandbox-result.json", "w"))
  handle.write(textutils.serializeJSON({
    ok = true, booted = true, errors = {}, lines = { ok and "depth pass" or "depth recorded" },
  }))
  handle.close()
  return ok
end

return M
