local root = arg[1]
local cmd = arg[2]
local role = arg[3]
local manifest = assert(loadfile(root .. "/bundle-manifest.lua"))()

local NEVER = {
  server = true, hub = true, miner = true, store = true,
  roomclient = true, roomsorter = true, lumber = true, panel = true,
}

local ROLES = {
  server = { kind = "computer", secs = 12, install = { "server", "install" } },
  hub = { kind = "computer", secs = 12, install = { "hub", "install" } },
  miner = { kind = "turtle", secs = 12, install = { "miner", "setup", "0", "64", "0", "north" } },
  store = { kind = "turtle", secs = 12, install = { "store", "install" } },
  roomclient = { kind = "computer", secs = 22, install = { "roomsorter", "install", "client" } },
  roomsorter = { kind = "turtle", secs = 12, install = { "roomsorter", "install" } },
  lumber = { kind = "turtle", secs = 12, install = { "lumber", "setup", "48" } },
  panel = { kind = "computer", secs = 12, install = { "panel", "install" } },
}

local ORDER = { "server", "hub", "miner", "store", "roomclient", "roomsorter", "lumber", "panel" }

local function startup_words(spec)
  local words = {}
  if type(spec.startup) ~= "table" then return words end
  for _, word in ipairs(spec.startup) do words[#words + 1] = word end
  return words
end

if cmd == "roles" then
  for _, id in ipairs(ORDER) do print(id) end
  return
end

if cmd == "doctor" then
  local failed = false
  for _, id in ipairs(ORDER) do
    local spec = manifest.roles[id]
    local plan = ROLES[id]
    if not spec or type(spec.files) ~= "table" or #spec.files == 0 then
      io.stderr:write("missing manifest role " .. id .. "\n")
      failed = true
    elseif type(spec.startup) ~= "table" or #spec.startup == 0 then
      io.stderr:write("missing startup for " .. id .. "\n")
      failed = true
    else
      for _, file in ipairs(spec.files) do
        local f = io.open(root .. "/" .. file, "rb")
        if not f then
          io.stderr:write("missing file " .. id .. " " .. file .. "\n")
          failed = true
        else
          f:close()
        end
      end
      io.write(string.format("%s files=%d startup=%s install=%s\n",
        id, #spec.files, table.concat(startup_words(spec), " "), table.concat(plan.install, " ")))
    end
  end
  if failed then os.exit(1) end
  return
end

local spec = manifest.roles[role]
local plan = ROLES[role]
if not spec or not plan then
  io.stderr:write("unknown role " .. tostring(role) .. "\n")
  os.exit(1)
end

if cmd == "files" then
  for _, file in ipairs(spec.files) do print(file) end
elseif cmd == "startup" then
  for _, word in ipairs(startup_words(spec)) do print(word) end
elseif cmd == "install" then
  for _, word in ipairs(plan.install) do print(word) end
elseif cmd == "kind" then
  print(plan.kind)
elseif cmd == "secs" then
  print(plan.secs)
elseif cmd == "exempt" then
  print(NEVER[role] and "no" or "yes")
else
  io.stderr:write("unknown command " .. tostring(cmd) .. "\n")
  os.exit(1)
end
