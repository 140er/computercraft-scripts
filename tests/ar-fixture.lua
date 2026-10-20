local F = {}
function F.install(draw)
  local m = dofile("tests/mocks.lua").new(true)
  local find, name = peripheral.find, peripheral.getName
  local update = m.ar.update
  m.ar.update = function()
    update()
    if draw then
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.white)
      term.clear()
      local width,height = term.getSize()
      local rectangles={}
      for _,element in pairs(m.elements) do
        if element.method=="drawRect2D" then rectangles[#rectangles+1]=element end
      end
      table.sort(rectangles,function(a,b)
        local x,y=a.args,b.args
        return (x[5]-x[3])*(x[6]-x[4])>(y[5]-y[3])*(y[6]-y[4])
      end)
      for _,element in ipairs(rectangles) do
        if element.method == "drawRect2D" then
          local a=element.args
          local rgb=a[2]%16777216
          local color=rgb==0x2EA043 and colors.green or (rgb==0xF85149 and colors.red or
            (rgb==0xD29922 and colors.yellow or (rgb==0x11161D and colors.black or colors.gray)))
          term.setBackgroundColor(color)
          local x1,x2=math.max(1,math.floor(a[3]/6)+1),math.min(width,math.floor(a[5]/6)+1)
          local y1,y2=math.max(1,math.floor(a[4]/9)+1),math.min(height,math.floor(a[6]/9)+1)
          for y=y1,y2 do
            if x2>=x1 then term.setCursorPos(x1,y) term.write(string.rep(" ",x2-x1+1)) end
          end
        end
      end
      term.setBackgroundColor(colors.black)
      for _,element in pairs(m.elements) do
        if element.method == "drawText2D" then
          local a = element.args
          local x,y = math.floor(a[3]/6)+1,math.floor(a[4]/9)+1
          if x>=1 and y>=1 and x<=width and y<=height then
            term.setCursorPos(x,y)
            term.write(a[5]:sub(1,width-x+1))
          end
        end
      end
    end
  end
  peripheral.find = function(kind,...)
    if kind == "ar_controller" then return m.attached and m.ar or nil end
    return find(kind,...)
  end
  peripheral.getName = function(device)
    if device==m.ar then return "emulated_ar" end
    return name(device)
  end
  return m
end
function F.snapshot()
  return {
    turtles = {
      {id=1,kind="miner",name="Miner north",x=4,y=64,z=8,dim="minecraft:overworld",fuel=8400,maxFuel=10000,status="Mining"},
      {id=2,kind="miner",name="Miner east",x=12,y=62,z=2,dim="minecraft:overworld",fuel=140,maxFuel=10000,status="Returning"},
      {id=3,kind="miner",name="Miner west",x=-8,y=60,z=4,dim="minecraft:overworld",fuel=6200,maxFuel=10000,status="Mining"},
    },
    world_map = {
      {x=4,y=63,z=9,dim="minecraft:overworld",name="minecraft:diamond_ore",state="solid"},
      {x=5,y=63,z=9,dim="minecraft:overworld",name="minecraft:iron_ore",state="solid"},
      {x=4,y=64,z=7,dim="minecraft:overworld",state="AIR"},
    },
    anchors = {{name="Charging",x=0,y=64,z=0,dim="minecraft:overworld"}},
  }
end
return F
