local H = dofile("tests/so/harness.lua")
local root, count = arg[1] or ".", tonumber(arg[2]) or 1000
local profile = arg[3] == "profile"
local realTextutils
if arg[5] then
  realTextutils = setmetatable({}, {__index=_G})
  realTextutils.dofile = function()
    return function(name)
      if name == "cc.expect" then return dofile(arg[5] .. "/rom/modules/main/cc/expect.lua") end
      assert(name == "cc.strings", name)
      return {}
    end
  end
  assert(loadfile(arg[5] .. "/rom/apis/textutils.lua", "t", realTextutils))()
end

for _, mode in ipairs({"append", "emit"}) do
  local net = H.new()
  local m = net.machine({id=1, directories=true})
  if realTextutils then m.env.textutils = realTextutils end
  for _, name in ipairs({"so-store.lua", "so-log.lua", "so-mod-state.lua"}) do
    local f = assert(io.open(root .. "/" .. name))
    m.files[name] = f:read("*a")
    f:close()
  end
  m.env.SO = {now=function() return net.time end, mods={}, breathe=function() end}
  m.spawn([[SO.store=dofile("so-store.lua")
    log=dofile("so-log.lua").open(SO.store)
    state=dofile("so-mod-state.lua")]])
  assert(not m.error, m.error)
  local bytes, writes, reads, serialBytes, peak = 0, 0, 0, 0, 0
  local open, serialize = m.env.fs.open, m.env.textutils.serialize
  m.env.fs.open = function(path, how)
    local handle = open(path, how)
    if not handle then return nil end
    if how == "w" then
      local write = handle.write
      handle.write = function(text)
        bytes, writes = bytes + #text, writes + 1
        write(text)
        if profile then
          local used = 0
          for name, data in pairs(m.files) do
            if name:match("^so%-data/") then used = used + #data end
          end
          peak = math.max(peak, used)
        end
      end
    elseif profile then
      local read = handle.readAll
      handle.readAll = function() local text = read() reads = reads + #text return text end
    end
    return handle
  end
  if profile then
    m.env.textutils.serialize = function(...)
      local text = serialize(...)
      serialBytes = serialBytes + #text
      return text
    end
  end
  m.env.COUNT, m.env.MODE = count, mode
  collectgarbage("collect")
  local start = os.clock()
  m.spawn([[for i=1,COUNT do
    local data={id=2, count=i, name="minecraft:diamond", detail=string.rep("x",160)}
    if MODE=="append" then assert(log.append({kind="mine.ore",at=1700000000000,gameAt=1700000000000,data=data}))
    else assert(state.emit("mine.ore",data)) end
  end]])
  assert(not m.error, m.error)
  local elapsed = (os.clock()-start)*1000
  local measured = string.format("%s\t%s\t%d\t%d\t%.3f\t%.6f\t%d\t%d\t%d\t%d",
    root,mode,count,bytes,bytes/count,elapsed/count,writes,reads,serialBytes,peak)
  m.env.fs.open, m.env.textutils.serialize = open, serialize
  if arg[4] then
    for _, name in ipairs({"so-store.lua", "so-log.lua"}) do
      local f = assert(io.open(arg[4] .. "/" .. name))
      m.files[name] = f:read("*a")
      f:close()
    end
  end
  m.spawn([[recovered=dofile("so-log.lua").open(dofile("so-store.lua"))]])
  net.flush()
  assert(not m.error, m.error)
  local events = m.env.recovered.events()
  assert(#events==count, "recovery count")
  for i, ev in ipairs(events) do assert(ev.seq==i and ev.data.count==i, "recovery data") end
  m.spawn([[assert(recovered.append({kind="legacy-tail",data={count=COUNT+1}}))]])
  assert(not m.error, m.error)
  for _, name in ipairs({"so-store.lua", "so-log.lua"}) do
    local f = assert(io.open(root .. "/" .. name))
    m.files[name] = f:read("*a")
    f:close()
  end
  m.spawn([[recovered=dofile("so-log.lua").open(dofile("so-store.lua"))]])
  net.flush()
  assert(not m.error, m.error)
  assert(#m.env.recovered.events()==count+1, "rollback append missing")
  print(measured)
end
