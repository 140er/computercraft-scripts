local setup = dofile("tests/so/minor-ui-fixture.lua")
local F = dofile("tests/so/dug-fixture.lua")

return function(test, equal)
  for _, size in ipairs({{26,20},{29,12}}) do
    for _, role in ipairs({"generic","status","mining","lumber","shop","ar"}) do
      for _, choice in ipairs({"allow","keep"}) do
        test("dug consent: banner at most 3 rows with drawn "..choice.." on "..role.." at "..size[1].."x"..size[2], function()
          local s=setup(size[1],size[2],function(server)
            server.opts.directories=true
            F.seed(server,500)
          end)
          s.assign(role)
          local cells=s.server.env.SO.mods.cells
          local before=cells.counts().dug
          local request=assert(cells.retirement())
          equal(request.status,"pending")
          local text={}
          for _, row in ipairs(s.frame().rows) do text[#text+1]=row.text end
          local message=table.concat(text," ")
          assert(message:find(request.text,1,true),message)
          assert(s.button("allow").y <= 3, "banner exceeds 3 rows")
          assert(s.button("keep").y <= 3, "banner exceeds 3 rows")
          s.button("allow") s.button("keep")
          s.press(choice)
          equal(cells.retirement().status,choice=="allow" and "allowed" or "kept")
          if choice=="allow" then assert(cells.counts().dug < before)
          else equal(cells.counts().dug,before) end
          local after={}
          for _, row in ipairs(s.frame().rows) do after[#after+1]=row.text end
          local confirmation=table.concat(after," ")
          assert(confirmation:find(choice=="keep" and "Kept." or "Forgot marks",1,true),confirmation)
          local used=0
          for _, bytes in pairs(s.client.files) do used=used+#bytes end
          assert(used<1000000,"display exceeded 1 MB")
        end)
      end
    end
  end

  test("dug consent: only the current drawn button coordinates can authorize retirement",function()
    local s=setup(29,12,function(server) server.opts.directories=true F.seed(server,500) end)
    local cells=s.server.env.SO.mods.cells
    local b=s.button("allow")
    local before=cells.counts().dug
    local function input(id,x,y)
      s.server.env.SO.mods.display.handlers.input({from=s.client.id,body={id=id,x=x,y=y}})
    end
    input(b.id,b.x,b.y-1)
    equal(cells.counts().dug,before)
    input(b.id.."stale",b.x,b.y)
    equal(cells.counts().dug,before)
    s.press("keep")
    input(b.id,b.x,b.y)
    equal(cells.counts().dug,before)
  end)

  test("dug consent: all displays see the same decision and AR keeps the pending alert",function()
    local drawn={}
    local ar={ clear=function() end, update=function() end, delete=function(id) drawn[id]=nil end,
      drawText2D=function(id,color,x,y,text) drawn[id]=text end,
      drawLine3D=function() end, drawText3D=function() end }
    local s=setup(26,20,function(server)
      server.opts.directories=true F.seed(server,500)
      local find=server.env.peripheral.find
      server.env.peripheral.find=function(kind) if kind=="ar_controller" then return ar end return find(kind) end
    end)
    equal(drawn["alert:dug-storage"],s.server.env.SO.mods.cells.retirement().text)
    s.net.advance(301)
    equal(drawn["alert:dug-storage"],s.server.env.SO.mods.cells.retirement().text)
    local display=s.server.env.SO.mods.display
    display.handlers.hello({from=3,body={w=29,h=11}})
    display.handlers["view.sub"]({from=3})
    s.press("keep")
    s.net.advance(1)
    local frame
    display.handlers["view.get"]({from=3},function(_,picture) frame=picture end)
    assert(frame.rows[1].text:find("Kept.",1,true))
    assert(drawn["alert:dug-storage"]:find("Kept.",1,true))
  end)
end
