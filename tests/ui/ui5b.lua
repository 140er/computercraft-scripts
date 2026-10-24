local H = dofile('tests/so/harness.lua')
return function(test, equal)
  test('UI5b MORE navigation switches only the tapped display once', function()
    local m = H.new().machine({id=1,capacity=16000000})
    m.install({'so-store.lua','so-ui.lua','so-mod-drops.lua','so-mod-display.lua'})
    local e = m.env
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
    for i, role in ipairs({'mining','lumber','shop','ar','panel','build'}) do
      tap(2,'generic')
      local found = {}
      for _, b in ipairs(frame(2).buttons) do found[b.id]=b end
      for _, button in ipairs(frame(2).buttons) do assert(button.y > 1, 'header injection') end
      local b = assert(found[role],role)
      equal({b.x,b.y,b.w,b.h},({{1,22,9,3},{11,22,8,3},{20,22,9,3},{30,22,9,3},{40,22,8,3},{49,22,9,3}})[i])
      local before = saves
      tap(2,role)
      equal(frame(2).role,role)
      equal(frame(3).role,'generic')
      equal(saves,before+1)
      equal(calls[role] or 0,0)
    end
    local render, input
    e.SO.mods.display = {screen=function(_, r, i) render,input=r,i end}
    local editor = e.dofile('so-mod-drops.lua'); editor.tick()
    input({id='new'})
    local found = {}
    for _, b in ipairs(render(57,24).buttons) do found[b.id]=true end
    assert(found.add and found.list)
    for _, role in ipairs({'mining','lumber','shop','ar','panel','build'}) do assert(not found[role],role) end
  end)
end
