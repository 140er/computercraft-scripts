local result={ok=false,roles={},boundaries={},transport={requests=0,bytes=0},faults={}}
local function read(path)
  local h=assert(fs.open(path,"r"),"Missing "..path)
  local text=h.readAll()
  h.close()
  return text
end
local function write(path,text)
  local h=assert(fs.open(path,"w"))
  h.write(text)
  h.close()
end
local function save()
  write("ar-install-result.json",textutils.serializeJSON(result))
end
local function hash(code)
  local h=5381
  for i=1,#code do
    h=(h*33+code:byte(i))%4294967296
    if i%32768==0 then sleep(0) end
  end
  return string.format("%08x",h)
end
local function run()
  assert(os.getComputerID()==4,"Installer probe requires disposable computer 4")
  assert(fs.getCapacity("/")==4000000,"Installer probe requires the 4 MB disk")
  http=nil
  _G.http=nil
  local modem=assert(peripheral.find("modem",function(_,m) return m.isWireless() end),"Wireless modem missing")
  rednet.open(peripheral.getName(modem))
  local server=rednet.lookup("fleetserver","server")
  assert(server==0,"Expected production cache server 0")
  result.server=server
  local nativeSend,nativeReceive=rednet.send,rednet.receive
  rednet.send=function(peer,message,protocol)
    if protocol=="fleetserver" and type(message)=="table" and message.type=="get" then
      assert(peer==0,"File request went to another server")
      result.transport.requests=result.transport.requests+1
    end
    return nativeSend(peer,message,protocol)
  end
  rednet.receive=function(...)
    local peer,message,protocol=nativeReceive(...)
    if peer==0 and type(message)=="table" and message.type=="file" then
      result.transport.bytes=result.transport.bytes+#(message.code or "")
    end
    return peer,message,protocol
  end
  local updater=assert(loadfile("update.lua","t",_ENV))("--module")
  local expectedManifest=assert(loadfile("bundle-manifest.lua","t",{}))()
  result.expectedVersion=expectedManifest.version
  local installer=read("install.lua")
  local roles={}
  local positions={}
  for start,id in installer:gmatch('()  { id = "([^"]+)"') do positions[#positions+1]={start=start,id=id} end
  for i,p in ipairs(positions) do
    local entry=installer:sub(p.start,(positions[i+1] and positions[i+1].start-1) or #installer)
    local files=assert(entry:match("files = (%b{})"),"Missing role files for "..p.id)
    roles[#roles+1]={id=p.id,files=assert(load("return "..files,"=role-files","t",{}))()}
  end
  assert(#roles>=20 and roles[5].id=="roomclient","Installer role registry changed unexpectedly")
  local function verify(files)
    local seen={}
    local function check(file)
      if seen[file] then return end
      seen[file]=true
      assert(expectedManifest.files[file]==hash(read(file):gsub("\r\n","\n")),"Installed hash mismatch for "..file)
      for _,dep in ipairs(updater.dependencies[file] or {}) do check(dep) end
    end
    for _,file in ipairs(files) do check(file) end
    check("install.lua") check("update.lua")
    local manifest=assert(loadfile("bundle-manifest.lua","t",{}))()
    assert(manifest.version==expectedManifest.version,"Installed another release")
    assert(not fs.exists(".fleet-update-journal"),"Transaction journal remains")
    for _,file in ipairs(updater.known) do
      assert(not fs.exists(file..".fleet-stage") and not fs.exists(file..".fleet-backup"),"Transaction files remain")
    end
    return seen
  end
  for _,role in ipairs(roles) do
    for _,file in ipairs(updater.known) do
      assert(file:match("^[%w%-]+%.lua$"),"Refusing non-root script removal")
      if file~="install.lua" and file~="update.lua" and fs.exists(file) then fs.delete(file) end
    end
    assert(load(installer,"=install.lua","t",_ENV))(role.id,"quick")
    local files=verify(role.files)
    local n=0
    for _ in pairs(files) do n=n+1 end
    result.roles[#result.roles+1]={role=role.id,ok=true,files=n,free=fs.getFreeSpace("/")}
    if role.id=="store" then
      assert(assert(loadfile("store-role.lua","t",_ENV))()==false,"Warehouse stub unexpectedly started")
      local value,message=dofile("role-adapter.lua").warehouse()
      assert(value==nil and message:find("unavailable",1,true))
      result.boundaries.warehouse={available=false,expected=true,message=message}
    elseif role.id=="vworld" or role.id=="pro" then
      assert(assert(loadfile("view-role.lua","t",_ENV))(role.id)==false,"View stub unexpectedly started")
      local value,message=dofile("role-adapter.lua").view(role.id)
      assert(value==false and message:find("unavailable",1,true))
      result.boundaries[role.id]={available=false,expected=true,message=message}
    end
    save()
    sleep(0)
  end
  assert(updater.apply({"ar-role.lua"}))
  verify({"ar-role.lua"})
  local value,message=dofile("role-adapter.lua").recharge()
  assert(value==false and message:find("unavailable",1,true))
  result.boundaries.recharge={available=false,expected=true,message=message}
  local oldHub=read("hub.lua")
  local observedReceive=rednet.receive
  rednet.receive=function(...)
    local peer,packet,protocol=observedReceive(...)
    if peer==0 and type(packet)=="table" and packet.type=="file" and packet.file=="hub.lua" then
      packet.hash="injected-bad-hash"
    end
    return peer,packet,protocol
  end
  local accepted,why=updater.apply({"hub.lua"})
  rednet.receive=observedReceive
  assert(not accepted and read("hub.lua")==oldHub,"Bad native cache response changed installed code")
  result.faults.cacheHash={ok=true,injection="Hash changed after receipt from the real server",message=tostring(why)}
  write("hub.lua","return 'native rollback sentinel'\n")
  local nativeMove=fs.move
  local injected=false
  fs.move=function(from,to)
    if from=="hub.lua.fleet-stage" and to=="hub.lua" and not injected then
      injected=true
      error("Injected promotion failure")
    end
    return nativeMove(from,to)
  end
  accepted,why=updater.apply({"hub.lua"})
  fs.move=nativeMove
  assert(injected and not accepted and read("hub.lua")=="return 'native rollback sentinel'\n","Native disk rollback failed")
  assert(not fs.exists(".fleet-update-journal"),"Rollback journal remains")
  result.faults.commit={ok=true,injection="One fs.move exception on the native disk",message=tostring(why)}
  assert(updater.apply({"hub.lua"}))
  verify({"ar-role.lua"})
  assert(result.transport.requests>0 and result.transport.bytes>0,"No native cached transfer was observed")
  result.ok=true
  result.coverage="Every current named role installed from production cache over native rednet. Entrypoint execution is limited to unavailable adapters."
end
local ok,err=pcall(run)
if not ok then result.ok=false result.error=tostring(err) end
save()
