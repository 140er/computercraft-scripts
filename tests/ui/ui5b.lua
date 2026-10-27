local H = dofile('tests/so/harness.lua')
return function(test, equal)
  test('UI5b assignment switches only the target display once and the drop list links nowhere', function()
    local m = H.new().machine({id=1,capacity=16000000})
    m.install({'so-store.lua','so-ui.lua','so-mod-drops.lua','so-mod-display.lua'})
    local e = m.env
    m.files['so-server.cfg']=H.encode({displayAck=false,turtleInventory=false,workerPark=false})
    e.SO = { now = function() return e.os.epoch("utc") end,mods={},store=e.dofile('so-store.lua'),proto={ser=H.encode},pair={key=function() return 'key' end}}
    local saves = 0
    local store = e.SO.store.store
    e.SO.store.store = function(path, ...)
      local box = store(path, ...)
      local save = box.save
      box.save = function(value)
        if path == 'so-display' then saves = saves+1 end
        return save(value)
      end
      return box
    end
    local display = e.dofile('so-mod-display.lua')
    e.SO.mods.display = display
    local drops = e.dofile('so-mod-drops.lua'); drops.tick()
    local U=e.dofile('so-ui.lua')
    local calls = {}
    for _, role in ipairs({'mining','lumber','shop','ar','panel','build'}) do
      display.screen(role, function(w,h) local c=U.canvas(w,h);c.button(1,h,w,'MORE','generic','7',1);return c.frame() end,
        function() calls[role] = (calls[role] or 0)+1 end)
    end
    local function frame(id)
      local result
      display.handlers['view.get']({from=id},function(_,body) result=body end)
      return result
    end
    local function tap(id, button)
      local f=frame(id);local x,y=1,1
      for _,b in ipairs(f.buttons) do if b.id==button then x,y=b.x,b.y break end end
      display.handlers.input({from=id,body={id=button,x=x,y=y}})
    end
    display.handlers.hello({from=2,body={w=57,h=24}})
    display.handlers.hello({from=3,body={w=57,h=24}})
    assert(display.assign(2,'generic'))
    local found = {}
    for _, b in ipairs(frame(2).buttons) do found[b.id]=b; assert(b.y > 1, 'header injection') end
    for _, role in ipairs({'mining','lumber','shop','ar','panel','status','map','build','health','disk'}) do assert(not found[role],role) end
    for _, role in ipairs({'mining','lumber','shop','ar','panel','build'}) do
      local before = saves
      tap(2,role)
      equal(saves,before)
      assert(display.assign(2,role))
      equal(frame(2).role,role)
      equal(frame(3).role,'unassigned')
      equal(saves,before+1)
      equal(calls[role] or 0,0)
      equal({display.assign(2,role)},{true,'display 2: '..role})
      equal(saves,before+1,'same role saves nothing')
    end
    equal({display.command('99 mining')},{false,'no display 99'})
    equal({display.command('2 nope')},{false,'roles: status pocket mining lumber shop drops ar panel map health attention alerts events errors disk build'})
    equal({display.command('2')},{false,'use <id> <role> or <id> -'})
    equal({display.command('2 map')},{false,'map not loaded'})
    equal({display.command(' 2  -  ')},{true,'display 2: cleared'})
    equal(frame(2).role,'unassigned')
    local render, input
    e.SO.mods.display = {screen=function(_, r, i) render,input=r,i end}
    local editor = e.dofile('so-mod-drops.lua'); editor.tick()
    input({id='new'})
    found = {}
    for _, b in ipairs(render(57,24).buttons) do found[b.id]=true end
    assert(found.add and found.list)
    for _, role in ipairs({'mining','lumber','shop','ar','panel','build'}) do assert(not found[role],role) end
  end)
end
