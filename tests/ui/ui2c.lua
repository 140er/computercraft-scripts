local R = dofile("tests/ui/render.lua")
local function setup(kit)
  local s = { now = 76440000, sends = {} }
  local env = setmetatable({
    fs = { exists = function() return kit ~= false end },
    os = { epoch = function() return s.now end },
    rednet = {
      send = function(id, body, protocol) s.sends[#s.sends + 1] = {id=id,body=body,protocol=protocol} end,
      broadcast = function() end,
    },
    SO = { now = function() return s.now end, mods = { display = { screen = function(_, render, input) s.render, s.input = render, input end } } },
  }, { __index = _G })
  local mod = assert(loadfile("so-mod-shop.lua", "t", env))()
  mod.tick(s.now)
  for i = 1, 20 do
    local name, value = debug.getupvalue(s.render, i)
    if name == "S" then s.state = value break end
  end
  return s, mod
end
local function capture(frame, w, h)
  local out = R.capture(w,h)
  assert(#frame.rows == h)
  for y,row in ipairs(frame.rows) do
    local fg,bg = {},{}
    for _,run in ipairs(row.runs) do
      fg[#fg+1] = string.rep(run[2],run[1]); bg[#bg+1] = string.rep(run[3],run[1])
    end
    fg,bg = table.concat(fg),table.concat(bg)
    assert(#fg == w and #row.text <= w)
    out.setCursorPos(1,y); out.blit(row.text .. string.rep(" ",w-#row.text),fg,bg)
  end
  for _,b in ipairs(frame.buttons) do
    assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+b.h-1<=h)
  end
  return out
end
local function model()
  local m = { found=true, time="21:14", search="iron", page=1,
    order="Order: sent 16", items={} }
  for _,v in ipairs({
    {"iron_ingot",1240,"^ +60/h","b"},{"iron_ore",312,"- steady","b"},
    {"raw_iron",48,"v -20/h","1"},{"iron_block",27,"- steady","b"},
    {"iron_nugget",5,"v low","1"},{"iron_bars",0,"empty","e"},
  }) do
    m.items[#m.items+1]={name=v[1],label=v[1]:gsub("_"," "):upper(),count=v[2],sub=v[3],bg=v[4],detail="^ +60 per hour"}
  end
  for i=7,18 do m.items[i]={name="iron_"..i,label="IRON "..i,count=0,sub="empty",bg="e"} end
  return m
end
return function(test, equal)
  test("UI2c shop and order pages match the touch M fixtures",function()
    local s = setup()
    assert(s.state.layout, "missing pure shop layout")
    local m=model()
    local diff=R.diff("tests/ui/fixtures/shop-M.txt",capture(s.state.layout(m,57,24),57,24))
    assert(#diff==0,table.concat(diff,"\n"))
    m.selected=m.items[1];m.order="Order: delivered"
    diff=R.diff("tests/ui/fixtures/shoporder-M.txt",capture(s.state.layout(m,57,24),57,24))
    assert(#diff==0,table.concat(diff,"\n"))
  end)
  test("UI2c touch fixtures match at compact pocket and large sizes",function()
    local s=setup()
    for _,case in ipairs({{29,12,"tests/ui/fixtures/shop-compact.txt"},{26,20,"tests/ui/fixtures/shop-pocket.txt"},{100,38,"tests/ui/fixtures/shop-large.txt"}}) do
      local diff=R.diff(case[3],capture(s.state.layout(model(),case[1],case[2]),case[1],case[2]))
      assert(#diff==0,table.concat(diff,"\n"))
    end
  end)
  test("UI2c one order tap sends once and renders send nothing",function()
    for _,amount in ipairs({1,16,64}) do
      local s,mod=setup()
      mod.listen.roomsorter_stock(9,{totals={["minecraft:iron_ingot"]=1240}})
      s.render(57,24)
      s.input({id="item:minecraft:iron_ingot"})
      local frame=s.render(57,24)
      local button
      for _,b in ipairs(frame.buttons) do if b.id=="order:"..amount..":minecraft:iron_ingot" then button=b end end
      assert(button and button.h==5,"missing tall order button")
      s.input({id=button.id})
      for i=1,3 do s.render(57,24) end
      equal(#s.sends,1);equal(s.sends[1].body.cmd,"order")
      equal(s.sends[1].body.text,"minecraft:iron_ingot");equal(s.sends[1].body.n,amount)
      equal(s.sends[1].id,9);equal(s.sends[1].protocol,"roomsorter")
      s.input({id="items"});assert(not s.state.gather().selected)
    end
  end)
  test("UI2c direct orders use stock and name ranking without changing display state",function()
    local s,mod=setup()
    mod.order("iron",16);equal(#s.sends,0)
    mod.listen.roomsorter_stock(9,{totals={iron_b=64,iron_a=64,iron_c=16,gold=1000}})
    s.render(57,24,{id=2})
    s.input({text="gold",from=2})
    s.input({id="item:gold",from=2})
    local before=s.state.gather(2)
    mod.order("IRON",16)
    equal(#s.sends,1);equal(s.sends[1].body.text,"iron_a")
    local after=s.state.gather(2)
    equal(after,before)
    for _,case in ipairs({{"missing",16},{"iron",2},{false,16}}) do mod.order(unpack(case)) end
    equal(#s.sends,1)
  end)
  test("UI2c paging visits every item once and clamps at both ends",function()
    local s,mod=setup();local totals={}
    for i=1,19 do totals["iron_"..i]=i end
    mod.listen.roomsorter_stock(9,{totals=totals})
    local seen={}
    for page=1,4 do
      local frame=s.render(57,24);local count=0
      for _,b in ipairs(frame.buttons) do
        local name=b.id:match("^item:(.+)$")
        if name then assert(not seen[name]);seen[name]=true;count=count+1 end
      end
      equal(count,page==4 and 1 or 6)
      s.input({id="next"})
    end
    equal(s.state.gather().page,4)
    for i=1,5 do s.input({id="prev"});s.render(57,24) end
    equal(s.state.gather().page,1)
    s.input({id="next"});s.input({text="IRON 1"});s.render(57,24)
    equal(s.state.gather().page,1);equal(#s.state.gather().items,11)
    s.input({id="clear"});equal(s.state.gather().search,"");equal(#s.state.gather().items,19)
  end)
  test("UI2c all sizes keep both pages inside bounds with readable contrast",function()
    local s=setup()
    for _,size in ipairs({{26,20},{39,19},{57,24},{15,10},{100,38},{36,10},{1,1}}) do
      local m=model()
      for i=19,121 do m.items[i]={name="iron_"..i,label="IRON "..i,count=0,sub="empty",bg="e"} end
      for page=1,2 do
        if page==2 then m.selected=m.items[1] end
        local frame=s.state.layout(m,unpack(size))
        local out=capture(frame,unpack(size))
        if size[1]>=15 then
          if size[2]>10 and size[2]<16 then assert(out.picture().text[size[2]-1]:find("Order:",1,true)) end
          local buttons={}
          for _,b in ipairs(frame.buttons) do buttons[b.id]=true end
          if page==2 then
            for _,amount in ipairs({1,16,64}) do assert(buttons["order:"..amount..":iron_ingot"]) end
            assert(buttons.items)
          else assert(buttons.prev and buttons.next and buttons.page and buttons.letters and buttons.status) end
        end
        for _,row in ipairs(out.cells) do for _,cell in ipairs(row) do
          local fg,bg=cell[2],cell[3]
          if cell[1]:byte()>=128 and cell[1]:byte()<=159 and bg=="f" and fg~="0" and fg~="8" then fg,bg=bg,fg end
          assert((bg=="f" or bg=="7" or bg=="c") and (fg=="0" or fg=="8") or
            (bg=="d" or bg=="1" or bg=="e" or bg=="b" or bg=="a" or bg=="9" or bg=="0") and fg=="f",
            "contrast "..fg.."/"..bg)
        end end
      end
    end
  end)
  test("UI2c gathering uses stock and history and keeps discovery visible",function()
    local s,mod=setup()
    local missing=capture(s.render(57,24),57,24).picture()
    assert(table.concat(missing.text,"\n"):find("Storage room not found",1,true))
    mod.listen.roomsorter_stock(9,{totals={iron_ingot=1240,raw_iron=48,iron_nugget=5,iron_bars=0}})
    s.state.history={iron_ingot={1181},raw_iron={68},iron_nugget={6}}
    for _,name in ipairs({"iron_ingot","raw_iron","iron_nugget"}) do
      for i=2,60 do s.state.history[name][i]=s.state.history[name][1] end
    end
    local m=s.state.gather()
    equal(m.items[1].label,"IRON INGOT");equal(m.items[1].sub,"^ +60/h")
    equal(m.items[2].sub,"v -20/h");equal(m.items[2].bg,"1")
    equal(m.items[3].sub,"v low");equal(m.items[4].bg,"e")
  end)
end
