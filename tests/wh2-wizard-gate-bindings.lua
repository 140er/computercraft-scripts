local M = {}

function M.inspect(cfg)
  local path = "wh2-wizard-gate-prerequisites.json"
  local file = assert(fs.open(path, "r"), "missing gate prerequisite manifest")
  local manifest = textutils.unserializeJSON(file.readAll())
  file.close()
  assert(type(manifest) == "table" and manifest.schema == 1, "invalid gate prerequisite manifest")
  local role = cfg.role == "server" and "server" or "client"
  local missing = {}
  for _, name in ipairs(assert(manifest.roles[role], "missing prerequisite role")) do
    if not fs.exists(name) then missing[#missing + 1] = name end
  end
  return {
    schema=1, role=role, authenticated=false, missing=missing,
    authentication=manifest.authentication, productionBoundaries=manifest.productionBoundaries,
    unsupported=manifest.unboundRuntimeApis,
  }
end

function M.open(cfg)
  local report = M.inspect(cfg)
  local file = assert(fs.open("wizard-prerequisites.json", "w"))
  file.write(textutils.serializeJSON(report))
  file.close()
  if #report.missing > 0 then
    error("Production prerequisites unavailable: " .. table.concat(report.missing, ", "), 0)
  end
  error("Production runtime binding unavailable. " .. table.concat(report.unsupported, " "), 0)
end

return M
