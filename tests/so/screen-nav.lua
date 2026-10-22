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

local function setup(w, h, kit)
  local net = H.new()
  local server = net.machine({id=1, modem=true})
  install(server, {"so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua",
    "so-plan.lua", "so-mine-plan.lua", "so-lumber-plan.lua", "so-mod-state.lua", "so-mod-display.lua",
    "so-mod-drops.lua", "so-mod-mine.lua", "so-mod-lumber.lua", "so-mod-shop.lua", "so-mod-ar.lua",
    "so-mod-cells.lua", "so-mod-lease.lua"})
  if kit then server.install({"so-ui.lua", "so-mod-panel.lua", "so-mod-daily.lua"}) end
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
  local function button(label, target)
    local picture = frame()
    for _, b in ipairs(picture.buttons) do
      local y = b.y + math.floor((b.h or 1)/2)
      local lines = {}
      for row=b.y,b.y+(b.h or 1)-1 do lines[#lines+1]=(client.screen[row] or ""):sub(b.x,b.x+b.w-1) end
      local text = table.concat(lines,"\n")
      if (not target or b.id==target) and (b.label==label or text:find(label,1,true))
          and b.x>=1 and b.y>=1 and b.y+(b.h or 1)-1<=h and b.x+b.w-1<=w and #label<=b.w then
        assert(text:find(label,1,true), label .. " is overwritten")
        for _, other in ipairs(picture.buttons) do
          if other~=b then
            assert(b.x+b.w<=other.x or other.x+other.w<=b.x or b.y+(b.h or 1)<=other.y
              or other.y+(other.h or 1)<=b.y, label .. " on " .. picture.role .. " overlaps " .. other.id)
          end
        end
        return b
      end
    end
    error("no visible " .. label .. " button on " .. picture.role .. " at " .. w .. "x" .. h)
  end
  local function press(label, target)
    local b = button(label, target)
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
  for _, size in ipairs({{26,20},{29,12},{15,10},{36,10},{39,19},{51,19},{57,24},{82,40},{100,38},{164,81}}) do
    test("Big Tiles visible navigation graph at " .. size[1] .. "x" .. size[2], function()
      local s = setup(size[1],size[2],true)
      local seen = {}
      local function role(name)
        equal(s.frame().role,name)
        assert(s.frame().palette, "Big Tiles kit must be active")
        seen[name] = true
      end
      local function header(text)
        assert(s.frame().rows[2].text:find(text,1,true), "missing " .. text .. " header")
        seen[text] = true
      end
      if size[1]==26 then role("status");s.press("MORE") else role("generic") end
      role("generic");header("DROP")
      s.press("ADD NEW");header("ADD DROP")
      s.press("BACK");header("DROP")
      s.press("BACK");role("status")
      s.press("MORE");role("generic")
      for _, name in ipairs({"mining","lumber"}) do
        s.press(name:upper());role(name)
        s.button("BACK", "status")
        s.press("SETUP");header(name=="mining" and (size[1]<26 and "MINING" or "MINING SETUP") or "LUMBER")
        seen[name .. " setup"] = true
        s.press("BACK", name=="mining" and "mine-back" or "lumber-back")
        s.button("SETUP")
        s.press("BACK", "status");role("status")
        s.press("MORE");role("generic")
      end
      s.server.env.SO.mods.shop.listen.roomsorter_stock(90,{totals={["minecraft:iron_ingot"]=64}})
      s.press("SHOP");role("shop")
      s.press("IRON INGOT");header("SHOP >")
      s.button(size[1]<26 and "16" or "ORDER 16", "order:16:minecraft:iron_ingot")
      s.press("BACK");header("SHOP")
      s.press("BACK");role("status")
      s.press("MORE");s.press("AR");role("ar")
      s.button("TURTLES")
      s.press("BACK");role("status")
      s.press("MORE");s.press("PANEL");role("panel")
      s.press("MORE");role("generic")
      s.press("PANEL");role("panel")
      s.press(size[1]<26 and "ALT" or "ALERTS");header("PANEL")
      s.press("BACK");s.press("PAIR");header("PANEL")
      s.press("BACK");s.press(size[1]<26 and "GLC" or "GLANCE");role("status")
      if size[1]==26 then s.press("PANEL");role("panel");s.press("GLANCE");role("status") end
      for _, name in ipairs({"status","generic","mining","lumber","shop","ar","panel","mining setup","lumber setup","SHOP >","ADD DROP"}) do
        assert(seen[name], "unreached " .. name)
      end
    end)
  end
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
