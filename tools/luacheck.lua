package.path = "tools/vendor/luacheck/src/?.lua;tools/vendor/luacheck/src/?/init.lua;" .. package.path
local lint = require("luacheck")
local config = {}
assert(loadfile(".luacheckrc", "t", config))()
local overrides = config.files or {}
config.files = nil
local files = {}
for _, path in ipairs(arg) do files[#files + 1] = path end
if #files == 0 then
  local pipe = assert(io.popen("git ls-files 'so-*.lua' 'worker.lua' 'display.lua'"))
  for path in pipe:lines() do files[#files + 1] = path end
  assert(pipe:close())
end
local errors, warnings = 0, 0
for _, path in ipairs(files) do
  local file = assert(io.open(path, "rb"))
  local source = file:read("*a")
  file:close()
  local options = {}
  for key, value in pairs(config) do options[key] = value end
  options[1] = overrides[path]
  local report = lint.check_strings({ source }, options)[1]
  for _, event in ipairs(report) do
    local fatal = event.code:match("^[01]") ~= nil
    if fatal then errors = errors + 1 else warnings = warnings + 1 end
    print(string.format("%s %s:%d:%d W%s %s", fatal and "ERROR" or "WARN", path,
      event.line or 0, event.column or 0, event.code, lint.get_message(event)))
  end
end
print(string.format("luacheck: %d errors, %d warnings, %d files", errors, warnings, #files))
os.exit(errors > 0 and 1 or 0)
