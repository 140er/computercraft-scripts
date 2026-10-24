local setup = dofile("tests/so/minor-ui-fixture.lua")
local R = dofile("tests/ui/render.lua")
local destination = assert(arg[1], "fixture destination")
for _,size in ipairs({{26,20},{29,12}}) do
  local w,h = size[1],size[2]
  local s = setup(w,h,function(server)
    server.install({"so-ui.lua","so-errors.lua","so-mod-health.lua","so-mod-panel.lua"})
  end)
  local so = s.server.env.SO
  so.error("tick fixture failed")
  so.mods.state.emit("mine.alert",{text="ore chest full"})
  so.mods.state.emit("mine.ore",{count=3,name="minecraft:diamond"})
  assert(so.mods.drops.add({id="ore",kind="ore",side="front",dim=0,x=1,y=64,z=0}))
  for _=1,3 do so.mods.drops.note("ore",nil) end
  s.net.advance(6)
  for _,role in ipairs({"health","attention","alerts","events","errors"}) do
    local frame = so.mods.display.screen(role).render(w,h,{})
    local out = R.capture(w,h)
    for y,row in ipairs(frame.rows) do
      local fg,bg="",""
      for _,run in ipairs(row.runs) do
        fg,bg=fg..string.rep(run[2],run[1]),bg..string.rep(run[3],run[1])
      end
      out.setCursorPos(1,y)
      out.blit(row.text..string.rep(" ",w-#row.text),fg,bg)
    end
    local picture=out.picture()
    local file=assert(io.open(destination.."/"..role.."-"..w.."x"..h..".txt","wb"))
    file:write(w.."x"..h.." "..role:upper().."\n")
    for _,rows in ipairs({picture.text,picture.bg}) do for _,line in ipairs(rows) do file:write(line.."\n") end end
    file:close()
  end
end
