local H = dofile("tests/so/harness.lua")
local setup = dofile("tests/so/minor-ui-fixture.lua")

return function(test, equal)
  test("generic frames keep revisions per client size and page", function()
    local net = H.new()
    net.time = 0
    local m = net.machine({id=1})
    m.install({"so-store.lua", "so-mod-display.lua"})
    m.env.SO = {mods={}, store=m.env.dofile("so-store.lua"), pair={key=function() return "key" end},
      proto={ser=H.encode, build=function(_, _, body) return body end, encode=function(body) return body end}}
    local d = m.env.dofile("so-mod-display.lua")
    local pages = {[2]=1, [3]=2}
    d.screen("generic", function(w, h, id)
      return {rows={{text=w .. "x" .. h .. " page " .. pages[id]}}, buttons={}}
    end, function() end)
    for id=2,3 do
      d.handlers.hello({from=id, body={w=id==2 and 26 or 29, h=id==2 and 19 or 11}})
      d.handlers["view.sub"]({from=id})
    end
    local count = #m.sent
    d.tick(1000) d.tick(2000) d.tick(3000)
    equal(#m.sent, count, "unchanged clients must wait for the frame gap")
    pages[2]=3
    d.tick(3001)
    equal(#m.sent, count+1)
    equal(m.sent[#m.sent].id, 2)
    d.tick(4000)
    equal(#m.sent, count+2, "other client gets its keepalive")
  end)

  for _, size in ipairs({{26,20}, {29,12}}) do
    test("shop search clears through drawn controls at " .. size[1] .. "x" .. size[2], function()
      local s = setup(size[1], size[2])
      s.server.env.SO.mods.shop.listen.roomsorter_stock(90, {totals={stone=40, dirt=10}})
      s.press("shop")
      s.typeText("stone")
      assert(s.frame().rows[2].text:find("stone", 1, true))
      s.press("clear")
      equal(s.frame().rows[2].text, "Search: ")
      for _, reset in ipairs({" ", "*"}) do
        s.typeText("stone") s.typeText(reset)
        equal(s.frame().rows[2].text, "Search: ")
      end
      s.press("16")
      local found
      for _, packet in ipairs(s.server.sent) do
        if packet.protocol=="roomsorter" and packet.payload.cmd=="order" then found=packet.payload end
      end
      assert(found and found.n==16, "drawn order button must send an order")
    end)
  end

  test("shop searches belong to each display and dead rooms are rediscovered", function()
    local net = H.new()
    net.time = 0
    local m = net.machine({id=1})
    m.install({"so-mod-shop.lua"})
    local render, input
    m.env.SO={mods={display={screen=function(_, r, i) render,input=r,i end}}}
    local shop=m.env.dofile("so-mod-shop.lua")
    shop.tick(0)
    shop.listen.roomsorter_stock(90, {totals={stone=40,dirt=10}})
    input({from=2,text="stone"}) input({from=3,text="dirt"})
    equal(render(26,19,2).rows[2].text,"Search: stone")
    equal(render(29,11,3).rows[2].text,"Search: dirt")
    net.time=300000
    shop.tick(net.time)
    assert(render(26,19,2).rows[3].text:find("not found",1,true))
    shop.listen.dns(91,{sType="lookup response",sProtocol="roomsorter"})
    net.time=310000
    shop.tick(net.time)
    equal(m.sent[#m.sent].id,91)
    shop.listen.roomsorter_stock(90,{totals={wrong=100}})
    shop.listen.roomsorter(91,{rid=m.sent[#m.sent].payload.rid,totals={stone=2}})
    assert(render(26,19,2).rows[3].text:find("stone",1,true))
  end)

  test("shop DNS answers do not substitute for stock and valid stock renews discovery", function()
    local net=H.new()
    net.time=0
    local m=net.machine({id=1})
    m.install({"so-mod-shop.lua"})
    local render
    m.env.SO={mods={display={screen=function(_, r) render=r end}}}
    local shop=m.env.dofile("so-mod-shop.lua")
    shop.tick(0)
    shop.listen.dns(90,{sType="lookup response",sProtocol="roomsorter"})
    net.time=299000
    shop.tick(net.time)
    assert(not render(26,19,2).rows[3])
    net.time=300000
    shop.tick(net.time)
    assert(render(26,19,2).rows[3].text:find("not found",1,true))
    shop.listen.roomsorter_stock(91,{totals={stone=1}})
    net.time=599000
    shop.listen.roomsorter_stock(91,{totals={stone=2}})
    shop.tick(net.time)
    net.time=600000
    shop.tick(net.time)
    assert(render(26,19,2).rows[3].text:find("stone",1,true))
  end)

  test("AR clears old boot elements once and expires retained alerts", function()
    local net=H.new()
    local m=net.machine({id=1})
    m.install({"so-store.lua","so-mod-ar.lua"})
    local elements, clears={},0
    elements.old=true
    local values={["mine.alert"]={text="hold"}}
    local entries={{seq=1,at=0,kind="mine.alert"}}
    local ar={clear=function() elements={} clears=clears+1 end,
      delete=function(id) elements[id]=nil end, update=function() end,
      drawText2D=function(id) elements[id]=true end}
    m.env.peripheral.find=function() return ar end
    m.env.SO={store=m.env.dofile("so-store.lua"),proto={ser=H.encode},mods={state={
      get=function() return {} end,view=function() return {values=values} end,
      history={page=function(q)
        local out={}
        for _, ev in ipairs(entries) do if ev.seq>q.from then out[#out+1]=ev end end
        return {entries=out}
      end}}}}
    local mod=m.env.dofile("so-mod-ar.lua")
    mod.tick(1000)
    equal(elements.old,nil) equal(clears,1)
    assert(elements["alert:mine.alert"])
    mod.tick(300000)
    equal(elements["alert:mine.alert"],nil)
    mod.tick(301000)
    equal(elements["alert:mine.alert"],nil,"retained snapshot must not revive an alert")
    entries[2]={seq=2,at=302000,kind="mine.alert"}
    mod.tick(302000)
    assert(elements["alert:mine.alert"],"repeated alert must refresh its expiry")
    equal(clears,1)
    values["mine.alert"]=nil
    mod.tick(303000)
    equal(elements["alert:mine.alert"],nil,"removed state clears the drawn alert")
    values["mine.alert"]={text="old snapshot"}
    entries[3]={seq=3,at=0,kind="mine.alert"}
    mod=m.env.dofile("so-mod-ar.lua")
    mod.tick(304000)
    equal(elements["alert:mine.alert"],nil,"old history must stay expired after boot")
    ar.clear=nil
    mod=m.env.dofile("so-mod-ar.lua")
    assert(pcall(mod.tick,305000),"controller without clear remains supported")
  end)
end
