local H = dofile("tests/so/harness.lua")
local R = dofile("tests/ui/render.lua")
local T = {}

T.setup = function()
  local s = {now=1000000, sends={}}
  local env = setmetatable({
    os={epoch=function() return s.now end},
    rednet={send=function(id, body, protocol)
      s.sends[#s.sends+1]={id=id,body=body,protocol=protocol}
    end,broadcast=function() end},
    SO={now=function() return s.now end,mods={display={screen=function(_,render,input) s.render,s.input=render,input end}}},
  },{__index=_G})
  s.mod=assert(loadfile("so-mod-shop.lua","t",env))()
  s.mod.tick(s.now)
  return s
end

T.stock = function()
  local totals = {}
  for _,name in ipairs({"apple","bread","carrot","cooked_beef","potato","wheat",
    "coal","diamond","emerald","gold_ingot","iron_ingot","iron_ore","lapis_lazuli","raw_iron","redstone",
    "acacia_log","birch_log","oak_log","oak_planks","oak_sapling","spruce_log","stick",
    "brick","cobblestone","dirt","glass","gravel","obsidian","sand","stone","white_wool",
    "bow","diamond_pickaxe","iron_axe","iron_shovel","iron_sword","shears",
    "ender_pearl","feather","leather"}) do
    totals["minecraft:"..name]=41+#name
  end
  return totals
end

T.text = function(frame)
  local lines={}
  for _,row in ipairs(frame.rows) do lines[#lines+1]=row.text end
  return table.concat(lines,"\n")
end

T.capture = function(frame,w,h)
  local out=R.capture(w,h)
  assert(#frame.rows==h)
  assert(frame.rows[2].runs[2] and frame.rows[2].runs[2][3]=="a","shop header overwritten")
  for y,row in ipairs(frame.rows) do
    local fg,bg={},{}
    for _,run in ipairs(row.runs) do
      fg[#fg+1]=string.rep(run[2],run[1]);bg[#bg+1]=string.rep(run[3],run[1])
    end
    fg,bg=table.concat(fg),table.concat(bg)
    assert(#fg==w and #bg==w and #row.text<=w)
    out.setCursorPos(1,y);out.blit(row.text..string.rep(" ",w-#row.text),fg,bg)
  end
  for i,b in ipairs(frame.buttons) do
    assert(b.x>=1 and b.y>=1 and b.w>0 and b.h>0 and b.x+b.w-1<=w and b.y+b.h-1<=h,b.id)
    local drawn=false
    for y=b.y,b.y+b.h-1 do
      if frame.rows[y].text:sub(b.x,b.x+b.w-1):find("%S") then drawn=true end
    end
    assert(drawn,"undrawn button "..b.id)
    for j=i+1,#frame.buttons do
      local other=frame.buttons[j]
      assert(b.x+b.w<=other.x or other.x+other.w<=b.x or b.y+b.h<=other.y or other.y+other.h<=b.y,
        "overlap "..b.id.." "..other.id)
    end
  end
  return out
end

T.run = function(test,equal)
  for _,size in ipairs({{29,12},{26,20},{57,24},{100,38}}) do
    local w,h=unpack(size)
    test("touch shop browse and one order at "..w.."x"..h,function()
      local s=T.setup()
      s.mod.listen.roomsorter_stock(90,{totals=T.stock()})
      local a,b={id=2,keyboard=false},{id=3,keyboard=false}
      local function frame(session)
        local f=s.render(w,h,session or a)
        T.capture(f,w,h)
        return f
      end
      local function press(id,session)
        session=session or a
        for _,button in ipairs(frame(session).buttons) do
          if button.id==id then
            s.input({id=id,x=button.x,y=button.y,session=session})
            return
          end
        end
        error("missing button "..id)
      end
      local function items()
        local names={}
        for _,button in ipairs(frame().buttons) do
          local name=button.id:match("^item:(.*)$")
          if name then names[#names+1]=name end
        end
        return names
      end
      local other=H.encode(frame(b))
      press("cat:wood")
      for _,name in ipairs(items()) do
        assert(name:find("log") or name:find("planks") or name:find("sapling") or name:find("stick"),name)
      end
      press("sort:name")
      equal(items()[1],"minecraft:acacia_log")
      press("sub:planks")
      equal(items(),{"minecraft:oak_planks"})
      press("sub:all");press("back");press("all")
      local first=H.encode(frame())
      if #items()<40 then press("next") end
      assert(#items()==40 or H.encode(frame())~=first,"page did not change")
      press("back");press("cat:ores");press("sub:ingot");press("sort:name")
      local item=items()[1]
      equal(item,"minecraft:gold_ingot")
      press("item:"..item)
      local id="order:16:"..item
      press(id)
      for i=1,3 do frame() end
      equal(#s.sends,1);equal(s.sends[1].body.cmd,"order");equal(s.sends[1].body.text,item)
      equal(s.sends[1].body.n,16);equal(s.sends[1].id,90);equal(s.sends[1].protocol,"roomsorter")
      assert(T.text(frame()):find("Order: sent",1,true))
      s.mod.listen.roomsorter(90,{rid=s.sends[1].body.rid,"Getting 16 gold ingot..."})
      assert(T.text(frame()):find("Order: sent",1,true))
      equal(H.encode(frame(b)),other,"another display changed")
      s.mod.listen.roomsorter(90,{rid=s.sends[1].body.rid,"Delivered 16 gold ingot"})
      assert(T.text(frame()):find("Order: delivered",1,true))
      equal(H.encode(frame(b)),other)
      press("items")
      equal(items()[1],"minecraft:gold_ingot")
    end)
  end
  for _,size in ipairs({{26,20},{29,12},{100,38}}) do
    test("touch shop client sends one roomsorter order at "..size[1].."x"..size[2],function()
      local setup=dofile("tests/so/minor-ui-fixture.lua")
      local s=setup(size[1],size[2],function(server) server.install({"so-ui.lua"}) end,size[1]~=26)
      s.server.env.SO.mods.shop.listen.roomsorter_stock(90,{totals=T.stock()})
      local display=s.server.env.SO.mods.display
      display.handlers.hello({from=3,body={w=size[1],h=size[2],fullH=size[2],keyboard=false}})
      assert(display.assign(3,"shop"))
      local function other()
        local frame
        display.handlers["view.get"]({from=3},function(_,body) frame=body end)
        return H.encode(frame)
      end
      local before=other()
      for _,id in ipairs({"generic","shop","status"}) do display.handlers.input({from=2,body={id=id,x=1,y=1}}) end
      s.net.flush();equal(s.frame().role,size[1]==26 and "pocket" or "unassigned")
      assert(display.assign(2,"shop"));s.net.advance(1);equal(s.frame().role,"shop")
      s.press("ORES");s.press("INGOT")
      s.press("Iron Ingot");s.press("16")
      local orders={}
      for _,packet in ipairs(s.server.sent) do
        if packet.protocol=="roomsorter" and packet.payload.cmd=="order" then orders[#orders+1]=packet end
      end
      equal(#orders,1);equal(orders[1].id,90);equal(orders[1].payload.n,16)
      equal(orders[1].payload.text,"minecraft:iron_ingot")
      equal(other(),before)
      s.press("BACK");equal(s.frame().role,"shop")
      s.press("BACK");equal(s.frame().role,"shop")
      for _,b in ipairs(s.frame().buttons) do assert(b.id~="status" and b.id~="generic") end
      local used=0
      for _,source in pairs(s.client.files) do used=used+#source end
      assert(used<1000000)
    end)
  end
  test("touch shop reports failures missing room and stale stock",function()
    local s=T.setup();local session={id=2}
    assert(T.text(s.render(29,12,session)):find("Storage room not found",1,true))
    s.mod.listen.roomsorter_stock(90,{totals={['minecraft:iron_ingot']=64}})
    local function order()
      s.input({id="item:minecraft:iron_ingot",session=session})
      s.input({id="order:16:minecraft:iron_ingot",session=session})
    end
    order()
    s.mod.listen.roomsorter(91,{rid=1,"Delivered 16"})
    assert(T.text(s.render(29,12,session)):find("Order: sent",1,true))
    s.mod.listen.roomsorter(90,{rid=1,"Not in storage."})
    assert(T.text(s.render(29,12,session)):find("Order: failed",1,true))
    order();s.now=s.now+120001;s.mod.tick(s.now)
    assert(T.text(s.render(29,12,session)):find("failed, timed out",1,true))
    assert(T.text(s.render(29,12,session)):find("STALE STOCK",1,true))
    s.input({id="items",session=session})
    assert(T.text(s.render(29,12,session)):find("STALE STOCK",1,true))
    s.now=s.now+180000;s.mod.tick(s.now)
    assert(T.text(s.render(29,12,session)):find("Storage room not found",1,true))
    s.mod.listen.roomsorter_stock(91,{totals={['minecraft:iron_ingot']=16}})
    assert(not T.text(s.render(29,12,session)):find("STALE STOCK",1,true))
  end)
end
return T
