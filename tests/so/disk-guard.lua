local H = dofile("tests/so/harness.lua")

local function install(machine, files)
  machine.install(files)
  for _, name in ipairs({"x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing"}) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local file = assert(io.open(path, "rb"))
    machine.files[path] = file:read("*a")
    file:close()
  end
end

local function setup(w, h, existing)
  local net = existing and existing.net or H.new()
  local server = existing and existing.server or net.machine({id=1, modem=true})
  if not existing then
  install(server, {"so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua",
    "so-plan.lua", "so-mine-plan.lua", "so-lumber-plan.lua", "so-mod-state.lua", "so-mod-display.lua",
    "so-mod-drops.lua", "so-mod-mine.lua", "so-mod-lumber.lua", "so-mod-shop.lua", "so-mod-ar.lua",
    "so-mod-cells.lua", "so-mod-lease.lua"})
  server.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld", x=0, y=64, z=0}})
  server.boot("so-server.lua")
  net.flush()
  assert(not server.error, tostring(server.error))
  end
  local client = net.machine({id=existing and 3 or 2, modem=true, monitor=w==29, width=w, height=h, capacity=1000000})
  install(client, {"display.lua", "so-proto.lua", "so-pair.lua", "so-store.lua"})
  client.env.term.write = function(text)
    local x, y = client.cx or 1, client.cy or 1
    local row = (client.screen[y] or "") .. string.rep(" ", w)
    client.screen[y] = (row:sub(1, x-1) .. text .. row:sub(x+#text)):sub(1, w)
    client.cx = x + #text
  end
  local key = string.rep("a", 64)
  assert(server.env.SO.pair.remember(client.id, key))
  client.files["so-keys"] = H.encode({schema=1, generation=1, value={keys={["1"]=key}}})
  client.boot("display.lua")
  net.flush()
  net.advance(2)
  local function frame()
    assert(not server.error, tostring(server.error))
    assert(not client.error, tostring(client.error))
    for i=#server.sent,1,-1 do
      local packet = server.sent[i]
      if packet.id==client.id and packet.payload.t=="view.frame" then return packet.payload.body end
    end
    error("display received no frame")
  end
  local function button(label)
    local picture = frame()
    for _, b in ipairs(picture.buttons) do
      if b.label==label and b.x>=1 and b.y>=1 and b.y<=h and b.x+b.w-1<=w and #b.label<=b.w then
        assert((client.screen[b.y] or ""):sub(b.x,b.x+#label-1)==label, label .. " is overwritten")
        for _, other in ipairs(picture.buttons) do
          if other~=b and other.y==b.y then
            assert(b.x+b.w<=other.x or other.x+other.w<=b.x, label .. " overlaps another button")
          end
        end
        return b
      end
    end
    error("no visible " .. label .. " button on " .. picture.role .. " at " .. w .. "x" .. h)
  end
  local function press(label)
    local b = button(label)
    client.inbox[#client.inbox+1] = table.pack(w==29 and "monitor_touch" or "mouse_click",
      w==29 and "monitor" or 1, b.x, b.y)
    net.flush()
  end
  local function typeText(text)
    for ch in text:gmatch(".") do client.inbox[#client.inbox+1] = table.pack("char", ch) end
    client.inbox[#client.inbox+1] = table.pack("key", 28)
    net.flush()
  end
  local function assign(role)
    assert(server.env.SO.mods.display.command(client.id .. " " .. role))
    net.advance(1)
  end
  return {net=net, server=server, client=client, frame=frame, button=button, press=press, typeText=typeText, assign=assign}
end

return function(test)
  for _, size in ipairs({{26,20}, {29,12}}) do
    for _, role in ipairs({"mining", "lumber"}) do
      test(role .. " refuses start at 80% and resumes below it on " .. size[1] .. "x" .. size[2], function()
        local s = setup(size[1], size[2])
        s.assign(role)
        if role == "mining" then
          s.typeText("home 0 64 0 n")
        else
          s.typeText("area 0 0 2 2 64")
          s.typeText("add 3 0 65 0 n")
        end
        local key=string.rep("b",64)
        assert(s.server.env.SO.pair.remember(3,key))
        local worker=s.net.machine({id=3,modem=true,turtle=true,x=0,y=65,z=0,fuel=4000,capacity=1000000})
        install(worker,{"worker.lua","so-store.lua","so-pair.lua","so-proto.lua"})
        worker.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
        worker.boot("worker.lua") s.net.flush()
        if role=="mining" then s.typeText("add 3 0 65 0 n")
        else s.typeText("saplings -3 64 0 down") end
        assert(s.server.env.SO.mods.drops.add({id="ready",dim=0,x=-2,y=64,z=0,side="down",kind="any"}))
        s.net.advance(2)
        local path = role == "mining" and "so-data/mine/job" or "so-data/lumber/job"
        local function job()
          return s.server.env.SO.store.store(path, function() return true end).value
        end
        local function fill(ratio)
          s.server.files.ballast = nil
          local used = 0
          for _, bytes in pairs(s.server.files) do used = used + #bytes end
          s.server.files.ballast = string.rep("x", math.floor(s.server.capacity * ratio) - used)
        end
        local function screenHas(text)
          for _, line in pairs(s.client.screen) do if line:find(text, 1, true) then return true end end
          return false
        end
        for _, ratio in ipairs({0.8, 0.9}) do
          fill(ratio)
          s.typeText("start")
          s.net.advance(2)
          assert(not job() or not job().running, "started above disk threshold")
          assert(screenHas("disk >=80%; free space"), "disk refusal is not visible")
          assert(not s.server.env.SO.mods.state.canStart())
          assert(not s.server.env.SO.mods.state.job({name="blocked"}))
        end
        local capture = assert(io.open("tests/evidence/disk-guard/" .. role .. "-" .. size[1] .. "x" .. size[2] .. ".txt", "w"))
        for y=1,size[2] do capture:write((s.client.screen[y] or ""):gsub("%s+$", ""), "\n") end
        capture:close()
        fill(0.79)
        assert(s.server.env.SO.mods.state.canStart())
        s.typeText("start")
        s.net.advance(2)
        assert(job().running, "did not resume below disk threshold")
        assert(not screenHas("disk >=80%; free space"), "stale disk warning")
        assert(s.server.env.SO.mods.state.job({name="accepted"}))
        fill(0.9)
        s.typeText("stop")
        assert(not job().running, "stop refused above threshold")
      end)
    end
  end
end
