local root=assert(arg[1],"pass the sandbox run directory")
local function read(path)
  local h=io.open(root .. "/" .. path,"r")
  if not h then return end
  local bytes=h:read("*a") h:close()
  return bytes
end
local function state(path)
  local bytes=read(path)
  if not bytes then return end
  local parsed=assert(load("return " .. bytes,path,"t",{}))()
  return parsed.value or parsed
end
for id=0,5 do
  local disk="computer/" .. id .. "/"
  print("Computer " .. id)
  print((read(disk .. "sandbox-result.json") or "no result"):sub(1,1000))
  local client=state(disk .. "h3.client")
  if client then
    print("counter",client.counter,"revision",client.revision,"mutations",client.mutations,
      "pending",client.pending and client.pending.phase)
  end
end
local s=state("computer/0/ssot.state")
if s then
  print("Server epoch",s.epoch,"revision",s.rev)
  for id,c in pairs(s.clients) do print("Client",id,"counter",c.counter) end
else print("No durable SSOT state") end
local coordinator=state("computer/5/h3.coordinator")
print("Coordinator stage",coordinator and coordinator.stage)
local fleet=state("computer/0/server.state")
for _,entry in ipairs(fleet and fleet.log or {}) do
  if entry.kind:find("error") then print(entry.kind,entry.text) end
end
for _,path in ipairs({"stdout.log","stderr.log"}) do
  local bytes=read(path)
  print(path,bytes and bytes:sub(-6000) or "missing")
end
