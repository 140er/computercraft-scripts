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
  local function assign(role)
    local ok, text = server.env.SO.mods.display.command(client.id .. " " .. role)
    assert(ok, text)
    net.advance(1)
  end
  return {net=net, server=server, client=client, frame=frame, button=button, press=press, typeText=typeText, assign=assign}
end

-- Roles come from the server command; every page inside a role keeps its drawn controls.
local function noLinks(s)
  for _, b in ipairs(s.frame().buttons) do
    for _, id in ipairs({"status", "generic", "map", "map-back"}) do assert(b.id ~= id, "cross-role button " .. id) end
  end
end

return function(test, equal)
  for _, size in ipairs({{26,20},{29,12},{15,10},{36,10},{39,19},{51,19},{57,24},{82,40},{100,38},{164,81}}) do
    test("Big Tiles in-role pages at " .. size[1] .. "x" .. size[2], function()
      local s = setup(size[1],size[2],true)
      local seen = {}
      local function role(name)
        equal(s.frame().role,name)
        assert(s.frame().palette, "Big Tiles kit must be active")
        noLinks(s)
        seen[name] = true
      end
      -- Route A screens put the header on row 1, Big Tiles on row 2.
      local function header(text)
        local rows = s.frame().rows
        assert((rows[1].text .. "\n" .. rows[2].text):find(text,1,true), "missing " .. text .. " header")
        seen[text] = true
      end
      role(size[1]==26 and "pocket" or "unassigned")
      s.assign("drops");role("generic");header("DROP")
      s.press("ADD","new");header("ADD DROP")
      s.press("BACK");header("DROP")
      -- Job tabs need 24 columns; the 15-wide monitor shows the overview only.
      local main = size[1] >= 39 and "overview" or "main"
      for _, name in ipairs({"mining","lumber"}) do
        s.assign(name);role(name);header(name:upper())
        if size[1] >= 24 then
          s.press("setup","tab:setup");header(name:upper())
          assert(s.button("setup","tab:setup").y == 1)
          seen[name .. " setup"] = true
          s.press(main,"tab:" .. main)
          s.button("setup","tab:setup");role(name)
        else
          seen[name .. " setup"] = true
        end
      end
      s.server.env.SO.mods.shop.listen.roomsorter_stock(90,{totals={["minecraft:iron_ingot"]=64}})
      s.assign("shop");role("shop")
      -- Route A shop: the item opens beside the list on wide screens and as a page on narrow ones.
      s.press("IRON INGOT", "item:minecraft:iron_ingot")
      s.button("16", "order:16:minecraft:iron_ingot");seen["IRON INGOT"] = true
      s.press(size[1]>=52 and "\215" or "back", "items");role("shop")
      assert(s.frame().rows[1].text:find("low",1,true), "missing shop tabs")
      s.assign("ar");role("ar")
      s.button("turtles", "turtles") -- route A: the whole layer row is the toggle
      s.assign("panel");role("panel")
      s.press("ALERTS");header("PANEL")
      s.press("BACK");s.press("PAIR");header("PANEL")
      s.press("BACK");role("panel")
      s.assign("status");role("status")
      if size[1]==26 then
        s.assign("-");role("pocket")
        s.press("JOBS");assert(s.frame().rows[3].text:find("MINING",1,true));role("pocket")
        s.press("FLEET");assert(s.frame().rows[3].text:find("TURTLES",1,true));role("pocket")
      end
      for _, name in ipairs({"status","generic","mining","lumber","shop","ar","panel","mining setup","lumber setup","IRON INGOT","ADD DROP"}) do
        assert(seen[name], "unreached " .. name)
      end
    end)
  end
  for _, size in ipairs({{26,20}, {29,12}}) do
    test("drop editor remains clickable at " .. size[1] .. "x" .. size[2], function()
      local s = setup(size[1], size[2])
      equal(s.frame().role, "unassigned")
      s.assign("drops")
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
      test("kit-free " .. role .. " keeps its role through every visible button at " .. size[1] .. "x" .. size[2], function()
        local s = setup(size[1], size[2])
        for i=1,20 do
          assert(s.server.env.SO.mods.drops.add({id="drop" .. i, dim=0, x=i, y=64, z=0, side="down", kind="ore"}))
          s.server.env.SO.mods.state.emit("nav" .. i, {text=string.rep("long content ", 5)})
        end
        local totals = {}
        for i=1,20 do totals["minecraft:item_" .. i] = i end
        s.server.env.SO.mods.shop.listen.roomsorter_stock(90, {totals=totals})
        s.net.advance(1)
        s.assign(role)
        equal(s.frame().role, role)
        if role=="mining" then
          for i=10,29 do
            s.typeText("add " .. i .. " " .. i .. " 64 0 n")
            s.net.advance(0.25)
          end
        end
        local ids = {}
        for _, b in ipairs(s.frame().buttons) do ids[#ids+1] = b end
        for _, b in ipairs(ids) do
          s.client.inbox[#s.client.inbox+1] = table.pack(size[1]==29 and "monitor_touch" or "mouse_click",
            size[1]==29 and "monitor" or 1, b.x, b.y)
          s.net.flush()
          equal(s.frame().role, role)
        end
        noLinks(s)
      end)
    end
  end
end
