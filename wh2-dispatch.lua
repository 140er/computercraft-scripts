local M = {}
local owners = {
  fleet = "wh2-fleet.lua", settings = "wh2-fleet.lua",
  locations = "wh2-layout.lua", rooms = "wh2-layout.lua", slots = "wh2-layout.lua",
  classes = "wh2-wizard.lua", questions = "wh2-wizard.lua", crafts = "wh2-craft.lua",
}
local operations = {
  ["wh2-report"] = "wh2-fleet.lua", ["wh2-settings"] = "wh2-fleet.lua",
  ["wh2-layout"] = "wh2-layout.lua", ["wh2-class"] = "wh2-wizard.lua",
  ["wh2-unknown"] = "wh2-wizard.lua", ["wh2-recipe"] = "wh2-craft.lua",
  ["wh2-craft"] = "wh2-craft.lua",
}
local function failure(code, message) return {wh2=1,ok=false,code=code,error=message} end
local function loadOptional(path)
  if fs and not fs.exists(path) then return nil end
  local ok, module = pcall(dofile, path)
  if ok and type(module)=="table" and type(module.run)=="function" and type(module.valid)=="function" then return module end
end
function M.open(config, poseValidator)
  config = config or {enabled=false}
  local modules = {}
  for _, path in pairs(owners) do if not modules[path] then modules[path]=loadOptional(path) or false end end
  local api = {}
  function api.valid(value)
    if value==nil then return true end
    if type(value)~="table" or value.schema~=1 then return false end
    for name,path in pairs({fleet="wh2-fleet.lua",layout="wh2-layout.lua",wizard="wh2-wizard.lua",craft="wh2-craft.lua"}) do
      if modules[path] and value[name]~=nil and not modules[path].valid(value[name],poseValidator) then return false end
    end
    return true
  end
  function api.run(state, sender, message, context)
    if config.enabled~=true then return failure("disabled","Warehouse v2 is disabled") end
    if type(message.body)~="table" or message.body.wh2~=1 then return failure("invalid","Invalid warehouse v2 body") end
    local path = message.op=="wh2-get" and owners[message.body.topic] or operations[message.op]
    if not path then return failure("invalid","Unknown warehouse v2 operation or topic") end
    local module = modules[path]
    if not module then
      if message.op=="wh2-get" and message.body.topic=="locations" then
        return dofile("wh2-locations.lua").read(state,message.body,poseValidator)
      end
      if message.op=="wh2-get" and message.body.topic=="classes" then
        return {wh2=1,ok=true,revision=tostring(state.wh2 and state.wh2.layout and state.wh2.layout.revision or 0)..":0",records={},cursor=0}
      end
      return failure("unavailable","The requested warehouse v2 module is not installed")
    end
    context.config,context.pose = config,poseValidator
    return module.run(state,sender,message,context)
  end
  return api
end
return M
