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
  assert(server.env.SO.mods.display.assign(client.id, "drops"))
  net.advance(1)
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
    test("paged drop editor and typed input at " .. size[1] .. "x" .. size[2], function()
      local s = setup(size[1], size[2])
      local drops = s.server.env.SO.mods.drops
      local function check()
        for _, b in ipairs(s.frame().buttons) do
          assert(b.w == #b.label and b.x + b.w - 1 <= size[1] and b.y < size[2])
          assert((s.client.screen[b.y] or ""):sub(b.x,b.x+b.w-1)==b.label, "button is overwritten")
          for _, other in ipairs(s.frame().buttons) do
            if other~=b and other.y==b.y then
              assert(b.x+b.w<=other.x or other.x+other.w<=b.x, "buttons overlap")
            end
          end
        end
        for _, label in ipairs({"prev", "next",
            "kind", "side", "add", "dim+", "dim-", "x+", "x-", "y+", "y-", "z+", "z-"}) do s.button(label) end
        for _, b in ipairs(s.frame().buttons) do
          for _, role in ipairs({"mining", "lumber", "shop", "status", "ar", "generic"}) do assert(b.id ~= role, role) end
        end
      end
      check()
      s.typeText("1250 72 -900")
      s.press("add")
      equal(#drops.list(), 1)
      equal({drops.list()[1].x, drops.list()[1].y, drops.list()[1].z}, {1250,72,-900})
      s.typeText("-1 -1200 70 100")
      s.press("side")
      s.press("add")
      equal(drops.list()[2].dim, -1)
      equal(drops.list()[2].side, "down")
      s.typeText("add fuel 1300 64 -910 front 1")
      equal(#drops.list(), 3)
      equal(drops.list()[3].kind, "fuel")
      equal(drops.list()[3].dim, 1)
      for _, text in ipairs({"add bad 1 2 3", "1 2 nope", "0 1.5 2 3", "add ore 1 2 3 up 0", "1 2"}) do
        s.typeText(text)
        equal(#drops.list(), 3, "bad command added a point")
        local message = s.frame().rows[#s.frame().rows].text
        assert(message:find("bad") or message:find("integers") or message:find("use"), message)
      end
      s.press("add")
      equal(#drops.list(), 3, "invalid input changed the draft")
      for i=4,20 do assert(drops.add({id="point" .. i, dim=0, x=i, y=64, z=0, side="front", kind="ore"})) end
      s.net.advance(1)
      local seen = {}
      for page=1,20 do
        check()
        for _, b in ipairs(s.frame().buttons) do
          local id = b.id:match("^fix:(.+)$")
          if id then seen[id]=true end
        end
        s.press("next")
      end
      local count=0
      for _ in pairs(seen) do count=count+1 end
      equal(count,20,"some points cannot be reached")
      s.press("prev")
      check()
      local picture=s.frame()
      local file=assert(io.open("tests/evidence/drop-editor/" .. size[1] .. "x" .. size[2] .. ".txt", "w"))
      file:write("Mock display client, " .. size[1] .. "x" .. size[2] .. "; bottom row reserved for input\n")
      for y=1,size[2] do file:write(string.format("%02d |%-" .. size[1] .. "s|\n",y,s.client.screen[y] or "")) end
      file:close()
      local target
      for _, b in ipairs(picture.buttons) do if b.label=="fix" then target=b.id:sub(5) break end end
      for i=1,3 do assert(drops.note(target,nil)) end
      s.press("fix")
      for _, p in ipairs(drops.list()) do if p.id==target then equal(p.broken,false) end end
      s.press("remove")
      equal(#drops.list(),19)
      check()
    end)
  end
  test("drop paging is independent between pocket and monitor", function()
    local monitor = setup(29,12)
    local pocket = setup(26,20,monitor)
    for i=1,20 do assert(monitor.server.env.SO.mods.drops.add({id="p" .. i,
      dim=0,x=i,y=64,z=0,side="front",kind="ore"})) end
    monitor.net.advance(1)
    for i=1,19 do
      pocket.press("prev")
      monitor.press("next")
    end
    local found=false
    for _, b in ipairs(monitor.frame().buttons) do if b.id=="remove:p20" then found=true end end
    assert(found,"monitor cannot reach last point while pocket is subscribed")
    monitor.press("remove")
    equal(#monitor.server.env.SO.mods.drops.list(),19)
    pocket.press("next")
    pocket.button("remove")
  end)

end
