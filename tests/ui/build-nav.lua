local fixture=dofile("tests/so/build-world-fixture.lua")
return function(test,equal)
  test("builder job and setup match generated fixtures",function()
    local f=dofile("tests/so/build-fixture.lua")()
    local R=dofile("tests/ui/render.lua")
    for _,case in ipairs({{26,20,"tests/ui/fixtures/build-26x20.txt","tests/ui/fixtures/buildsetup-26x20.txt"},
      {29,12,"tests/ui/fixtures/build-29x12.txt","tests/ui/fixtures/buildsetup-29x12.txt"}}) do
      for i=1,2 do
        local session={buildSetup=i==2}
        local frame=f.render(case[1],case[2],session)
        local out=R.capture(case[1],case[2])
        for y,row in ipairs(frame.rows) do
          local fg,bg="",""
          for _,run in ipairs(row.runs) do fg=fg..string.rep(run[2],run[1]) bg=bg..string.rep(run[3],run[1]) end
          out.setCursorPos(1,y) out.blit(row.text..string.rep(" ",#fg-#row.text),fg,bg)
        end
        equal(R.diff(case[i+2],out),{})
      end
    end
  end)
  for _,size in ipairs({{26,20},{29,12}}) do
    -- Roles change only by assignment; the Build screen's own controls work through drawn buttons.
    test("builder drawn buttons work on an assigned build display at "..size[1].."x"..size[2],function()
      local f=fixture(size[1],size[2])
      assert(f.server.env.SO.mods.display.assign(3,"build")) f.advance(1)
      equal(f.frame().role,"build")
      f.press("SETUP") f.press("FLOOR","shape-next") equal(f.job().shape,"walls")
      f.press("BACK","build-back") f.press("START") assert(f.job().alert:find("configure",1,true))
      f.press("STOP") f.press("BACK","status") equal(f.frame().role,"build")
    end)
  end
end
