local fixture=dofile("tests/so/build-world-fixture.lua")
return function(test,equal)
  -- The job and setup cells are compared with the route A fixtures in tests/ui/ra2-other.lua.
  for _,size in ipairs({{26,20},{29,12}}) do
    -- Roles change only by assignment; the Build screen's own controls work through drawn buttons.
    test("builder drawn buttons work on an assigned build display at "..size[1].."x"..size[2],function()
      local f=fixture(size[1],size[2])
      assert(f.server.env.SO.mods.display.assign(3,"build")) f.advance(1)
      equal(f.frame().role,"build")
      f.press("setup","tab:setup") f.press("floor","shape-next") equal(f.job().shape,"walls")
      f.press("job","tab:job") f.press("START") assert(f.job().alert:find("configure",1,true))
      f.press("STOP") equal(f.frame().role,"build")
    end)
  end
end
