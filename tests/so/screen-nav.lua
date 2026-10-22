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

local function setup(w, h)
  local net = H.new()
  local server = net.machine({id=1, modem=true})
  install(server, {"so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua",
    "so-plan.lua", "so-mine-plan.lua", "so-lumber-plan.lua", "so-mod-state.lua", "so-mod-display.lua",
    "so-mod-drops.lua", "so-mod-mine.lua", "so-mod-lumber.lua", "so-mod-shop.lua", "so-mod-ar.lua",
    "so-mod-cells.lua", "so-mod-lease.lua"})
  server.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld", x=0, y=64, z=0}})
  server.boot("so-server.lua")
  net.flush()
  assert(not server.error, tostring(server.error))
  local client = net.machine({id=2, modem=true, monitor=w==29, width=w, height=h, capacity=1000000})
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
  return {net=net, server=server, client=client, frame=frame, button=button, press=press, typeText=typeText}
end

return function(test, equal)
  for _, size in ipairs({{26,20}, {29,12}}) do
    test("drop editor remains clickable at " .. size[1] .. "x" .. size[2], function()
      local s = setup(size[1], size[2])
      local function draft()
        for _, row in ipairs(s.frame().rows) do
          if row.text:match("^draft ") then return row.text end
        end
        error("drop draft is not visible")
      end
      local before = draft()
      s.press("kind")
      assert(draft()~=before, "visible kind button did not update the drop draft")
      equal(s.frame().role, "generic")
    end)
    for _, role in ipairs({"mining", "lumber", "shop", "status", "ar"}) do
      test("visible " .. role .. " navigation at " .. size[1] .. "x" .. size[2], function()
        local s = setup(size[1], size[2])
        for i=1,20 do
          assert(s.server.env.SO.mods.drops.add({id="drop" .. i, dim=0, x=i, y=64, z=0, side="down", kind="ore"}))
          s.server.env.SO.mods.state.emit("nav" .. i, {text=string.rep("long content ", 5)})
        end
        local totals = {}
        for i=1,20 do totals["minecraft:item_" .. i] = i end
        s.server.env.SO.mods.shop.listen.roomsorter_stock(90, {totals=totals})
        s.net.advance(1)
        equal(s.frame().role, "generic")
        s.press(role)
        equal(s.frame().role, role)
        if role=="mining" then
          for i=10,29 do
            s.typeText("add " .. i .. " " .. i .. " 64 0 n")
            s.net.advance(0.25)
          end
        end
        s.button("generic")
        s.press("generic")
        equal(s.frame().role, "generic")
        s.button(role)
        local drops = false
        for _, row in ipairs(s.frame().rows) do if row.text=="drops" then drops=true end end
        assert(drops, "drop editor is not reachable")
      end)
    end
  end
end
