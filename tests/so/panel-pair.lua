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
              or other.y+(other.h or 1)<=b.y, label .. " overlaps another button")
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

local U = dofile("so-ui.lua")

-- Both PAIR pages draw the code in route A line digits: the pocket's rows 5-11 from column 2, 3 cells
-- wide and 1 apart; the 29x12 panel's rows 3-7 from column 4, 3 cells wide and 1 apart.
local function readLineCode(s, x0, y0, dh)
  local code = ""
  for i=1,6 do
    local x, found = x0+(i-1)*4
    for digit=0,9 do
      local c = U.canvas(3,dh)
      c.digits(1,1,tostring(digit),"0",3,dh,1)
      local rows, matches = c.frame().rows, true
      for row=1,dh do
        local want = ((rows[row].text or "") .. "   "):sub(1,3)
        if (s.client.screen[row+y0-1] or ""):sub(x,x+2) ~= want then matches=false end
      end
      if matches then assert(not found,"ambiguous digit");found=tostring(digit) end
    end
    assert(found,"missing line digit")
    code=code..found
  end
  return code
end

local function readCode(s, w)
  if w == 26 then return readLineCode(s, 2, 5, 7) end
  return readLineCode(s, 4, 3, 5)
end

-- The code's countdown: the m:ss after the teal tick row, on either PAIR page.
local function countdown(s)
  for _, row in ipairs(s.frame().rows) do
    local left = (row.text or ""):match("[|\183]+ (%d+:%d%d)")
    if left then return left end
  end
end

local function newClient(s, id, code)
  local client = s.net.machine({id=id, modem=true, width=26, height=20, capacity=1000000})
  install(client,{"display.lua","so-proto.lua","so-pair.lua","so-store.lua"})
  client.boot("display.lua")
  s.net.flush()
  for digit in code:gmatch(".") do client.env.os.queueEvent("char",digit) end
  s.net.flush()
  assert(not client.error,tostring(client.error))
  return client
end

-- A pocket has PAIR in its own tab bar; any other display gets the panel role from the server.
local function openPanel(s)
  if s.frame().role=="pocket" then return end
  assert(s.server.env.SO.mods.display.command(s.client.id.." panel"))
  s.net.advance(1)
end

return function(test, equal)
  for _,size in ipairs({{26,20},{29,12}}) do
    local w,h = table.unpack(size)
    test("panel pairing button, big digits and single use at "..w.."x"..h,function()
      local s=setup(w,h,true)
      openPanel(s)
      s.press("PAIR");s.press("NEW CODE")
      local code=readCode(s,w)
      equal(code,s.server.env.SO.pair.pending())
      equal(s.server.env.SO.terminal.code,code)
      equal(s.server.env.SO.terminal.mode,"code")
      local expires=s.server.env.SO.terminal.expires
      s.net.advance(2)
      assert((countdown(s,w) or ""):find("4:58",1,true))
      s.press("NEW CODE")
      equal(readCode(s,w),code)
      equal(s.server.env.SO.terminal.expires,expires)
      local joined=newClient(s,3,code)
      assert(s.server.env.SO.pair.key(joined.id),"client did not pair")
      for _,packet in ipairs(joined.sent) do assert(packet.payload.t~="pair","NEW CODE client used legacy pair") end
      equal(s.server.env.SO.pair.pending(),nil)
      s.net.advance(2)
      assert(not countdown(s,w))
      local late=newClient(s,4,code)
      s.net.advance(8)
      equal(s.server.env.SO.pair.key(late.id),nil)
      s.button("NEW CODE")
      local used=0
      for _,bytes in pairs(joined.files) do used=used+#bytes end
      assert(used<1000000,"client disk limit")
    end)
    test("panel expiry and code privacy at "..w.."x"..h,function()
      local s=setup(w,h,true)
      openPanel(s)
      s.press("PAIR");s.press("NEW CODE")
      local code=readCode(s,w)
      local pair=s.server.env.SO.pair
      equal(s.server.env.SO.pairCode(99),nil)
      assert(pair.remember(5,string.rep("b",64)))
      equal(s.server.env.SO.pairCode(5),nil)
      local display=s.server.env.SO.mods.display
      display.handlers.hello({from=5,body={w=w,h=h}})
      if w~=26 then assert(display.assign(5,"panel")) end
      -- Taps count only on controls drawn in the frame this display was sent.
      for _,id in ipairs({w==26 and "tab:pair" or "pair","pair-code"}) do
        local f
        display.handlers["view.get"]({from=5},function(_,body) f=body end)
        local drawn
        for _,b in ipairs(f.buttons) do if b.id==id then drawn=b break end end
        assert(drawn,"missing displayed control "..id)
        display.handlers.input({from=5,body={id=id,x=drawn.x,y=drawn.y}})
      end
      local other
      display.handlers["view.get"]({from=5},function(_,body) other=body end)
      for row=w==26 and 5 or 4,w==26 and 7 or 6 do assert(other.rows[row].text~=s.frame().rows[row].text,"code leaked") end
      local proto=s.server.env.SO.proto
      for _,packet in ipairs(s.server.sent) do
        if packet.payload.t=="view.frame" then
          assert(packet.id~=nil,"broadcast frame")
          assert(proto.macOk(pair.key(packet.id),packet.payload),"unsigned frame")
        end
      end
      s.net.advance(300)
      equal(pair.pending(),nil)
      assert(not countdown(s,w))
      equal(s.server.env.SO.terminal.mode,"normal")
      s.press("NEW CODE")
      assert(pair.pending(),"new invitation after expiry")
      equal(#readCode(s,w),6)
    end)
  end
  test("panel pairing fixtures",function()
    local R=dofile("tests/ui/render.lua")
    local sys=dofile("tests/ui/scene.lua").system()
    local env=setmetatable({SO={now=function() return 0 end,mods={},pair={key=function() return true end,
      pending=function() return sys.code end},pairCode=function() end},
      os={epoch=function() return 0 end}}, {__index=_G})
    local panel=assert(loadfile("so-mod-panel.lua","t",env))()
    local render
    env.SO.mods.display={screen=function(role,fn) if role=="panel" and fn then render=fn end end}
    panel.tick(0)
    for _,size in ipairs({
      {26,20,{[false]="tests/ui/fixtures/panelpair-P.txt",[true]="tests/ui/fixtures/panelcode-P.txt"}},
      {29,12,{[false]="tests/ui/fixtures/panelpair-S.txt",[true]="tests/ui/fixtures/panelcode-S.txt"}},
    }) do
      local w,h,fixtures=table.unpack(size)
      for _,pending in ipairs({false,true}) do
        local session={id=2,panel={page="pair"}}
        if pending then session.panel.invitation={code=sys.code,expires=sys.left} end
        local frame=render(w,h,session)
        local out=R.capture(w,h)
        for y,row in ipairs(frame.rows) do
          local fg,bg={},{}
          for _,run in ipairs(row.runs) do
            fg[#fg+1]=string.rep(run[2],run[1]);bg[#bg+1]=string.rep(run[3],run[1])
          end
          fg,bg=table.concat(fg),table.concat(bg)
          out.setCursorPos(1,y);out.blit(row.text..string.rep(" ",#fg-#row.text),fg,bg)
        end
        local differences=R.diff(fixtures[pending],out)
        assert(#differences==0,table.concat(differences,"\n"))
      end
    end
  end)
  test("repeat panel requests preserve the bad attempt limit",function()
    local s=setup(26,20,true)
    openPanel(s)
      s.press("PAIR");s.press("NEW CODE")
    for i=1,10 do
      local env=newClient(s,8+i,"abcdef").env
      local proto=assert(env.dofile("so-proto.lua"))
      env.rednet.send(1,proto.build(string.rep("cd",32),"pair",{pub=string.rep("ef",32)}),"so");s.net.flush()
      if i<10 then s.press("NEW CODE");assert(s.server.env.SO.pair.pending(),"burned early") end
    end
    equal(s.server.env.SO.pair.pending(),nil)
    s.net.advance(2)
    assert(not countdown(s))
  end)
end
