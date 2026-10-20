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
function M.config(config,controllers)
  config=config or {enabled=false}
  assert(type(config)=="table" and (config.enabled==nil or type(config.enabled)=="boolean"),"Invalid wh2 configuration")
  assert(config.operators==nil or type(config.operators)=="table","Invalid wh2 operators")
  assert(config.enrolledRoles==nil or type(config.enrolledRoles)=="table","Invalid enrolled fleet roles")
  local roles={miner=true,store=true,crafter=true,factory=true,hub=true,server=true,panel=true,other=true}
  for name,entries in pairs({operators=config.operators or {},enrolledRoles=config.enrolledRoles or {}}) do
    local count=0
    for id,value in pairs(entries) do
      local number=type(id)=="string" and tonumber(id)
      assert(number and number%1==0 and number>=0 and number<=2147483647 and tostring(number)==id,"Invalid wh2 computer key")
      assert(name=="operators" and value==true or name=="enrolledRoles" and roles[value],"Invalid wh2 role or operator")
      assert(not controllers or controllers[id],"Pair wh2 computers before enrollment")
      count=count+1 assert(count<=32,"Wh2 enrollment limit")
    end
  end
  if config.recipeHubId~=nil then
    local id=config.recipeHubId
    assert(type(id)=="number" and id%1==0 and id>=0 and id<=2147483647,"Invalid recipe hub ID")
    assert(not controllers or controllers[tostring(id)],"Pair the recipe hub before enrollment")
  end
  return config
end
local function loadOptional(path)
  if fs and not fs.exists(path) then return nil end
  local ok, module = pcall(dofile, path)
  if ok and type(module)=="table" and type(module.run)=="function" and type(module.valid)=="function" then return module end
end
function M.open(config, poseValidator)
  config = M.config(config)
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
        return dofile("wh2-locations.lua").read(state,message.body,poseValidator,context.now)
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
