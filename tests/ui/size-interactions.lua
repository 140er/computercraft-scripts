local S = dofile('tests/ui/scene.lua')
local boot = S.private(dofile('tests/ui/ra3-ar.lua'), 'boot')
local inventory = S.private(dofile('tests/ui/inventory.lua'), 'setup')
local sample = S.private(dofile('tests/ui/inventory.lua'), 'sample')
local sizes = {{15,10},{26,20},{29,12},{39,19},{51,19},{57,24},{80,30},{100,38},{164,81},{37,17},{53,23}}
return function(test, equal)
  test('UB-28 one drawn AR tap toggles and saves once at every baseline size', function()
    for _,size in ipairs(sizes) do
      local w,h=size[1],size[2]
      local b,router=boot(),S.new()
      local frame=b.screens.ar.render(w,h,{})
      local before=b.saves()
      local state=b.A.layers.turtles
      router.D.monitor={name='coverage',frame=frame}
      router.D.localDraw=function(_,event) b.screens.ar.input(event) end
      local button
      for _,candidate in ipairs(frame.buttons) do if candidate.id=='turtles' then button=candidate end end
      assert(button,'layer is reachable')
      router.D.localTouch('coverage',button.x,button.y)
      equal(b.A.layers.turtles,not state)
      equal(b.saves(),before+1)
      router.D.localTouch('coverage',w+1,h+1)
      equal(b.saves(),before+1)
    end
  end)
  test('UB-28 every inventory slot and BACK remain reachable at every baseline size', function()
    for _,size in ipairs(sizes) do
      local w,h=size[1],size[2]
      local s=inventory(w,h,{turtleInventory=true})
      s.hello(sample())
      s.press('turtle:2') s.press('turtle-inventory')
      local seen={}
      local saves,sent=s.saves,s.sent[2]
      for _=1,16 do
        local picture=S.capture(s.frame(),w,h).picture()
        for _,line in ipairs(picture.text) do
          local slot=line:match('^ (%d%d) ')
          if slot then seen[tonumber(slot)]=true end
        end
        if not s.ids()['inventory-next'] then break end
        s.press('inventory-next')
      end
      for slot=1,16 do assert(seen[slot],'unreachable slot '..slot..' at '..w..'x'..h) end
      s.press('inventory-back')
      assert(s.ids()['turtle-back'],'BACK returns to detail')
      equal(s.saves,saves) equal(s.sent[2],sent)
    end
  end)
  test('UB-28 local input keeps fullH and legacy height distinct', function()
    local s=S.new()
    for _,size in ipairs(sizes) do
      local w,h=size[1],size[2]
      for _,full in ipairs({true,false}) do
        s.d.handlers.hello({from=91,body={w=w,h=h-1,fullH=full and h or nil,keyboard=true}})
        equal(s.D.sessions[91].h,full and h or h-1)
      end
    end
  end)
  test('UB-28 contracts reject missing controls, a no-op and a doubled real action', function()
    local A=dofile('tests/ui/size-adapters.lua')
    local actions=dofile('tests/ui/size-actions.lua')
    local frame,input,session=A.render('ar','scene',37,17)
    local button
    for _,b in ipairs(frame.buttons) do if b.id=='turtles' then button=b end end
    assert(button,'required layer control')
    for _,broken in ipairs({function() end,function(e) input(e) input(e) end}) do
      local ok=pcall(actions.tap,frame,broken,session,A.context,S.new(),'turtles',button.x,button.y)
      assert(not ok,'interaction contract accepted a broken handler')
    end
    actions.tap(frame,input,session,A.context,S.new(),'turtles',button.x,button.y)
    for i,b in ipairs(frame.buttons) do if b.id=='turtles' then table.remove(frame.buttons,i) break end end
    local ok,err=pcall(actions.required,frame,{turtles=true},{turtles=true})
    assert(not ok and tostring(err):find('missing required control turtles',1,true),'required inventory accepted a missing layer control')
  end)
  test('UB-28 turtle PARK requires one real mining command', function()
    local A=dofile('tests/ui/size-adapters.lua')
    local actions=dofile('tests/ui/size-actions.lua')
    for _,size in ipairs(sizes) do
      A.reset()
      local frame,input,session=A.render('turtle','scene',size[1],size[2])
      local context=A.context
      local screen=context.d.screen('mining')
      local original=screen.input
      local park
      for _,b in ipairs(frame.buttons) do if b.id=='turtle-park' then park=b end end
      assert(park,'required PARK control')
      for _,broken in ipairs({function() end,function(e) original(e) original(e) end}) do
        screen.input=broken
        local ok=pcall(actions.tap,frame,input,session,context,S.new(),'turtle-park',park.x,park.y)
        assert(not ok,'PARK accepted a missing or duplicate command')
      end
      screen.input=original
      actions.tap(frame,input,session,context,S.new(),'turtle-park',park.x,park.y)
    end
  end)

  test('UB-28 enabled NEXT rejects a no-op or a double page advance', function()
    local A=dofile('tests/ui/size-adapters.lua')
    local actions=dofile('tests/ui/size-actions.lua')
    local frame,input,session=A.render('errors-detail','scene',15,10)
    local context=A.context
    local function nextButton(f)
      for _,b in ipairs(f.buttons) do if b.id=='next' then return b end end
    end
    local button=assert(nextButton(frame),'required enabled NEXT')
    for _,broken in ipairs({function() end,function(e) input(e) input(e) end}) do
      local ok=pcall(actions.tap,frame,broken,session,context,S.new(),'next',button.x,button.y)
      assert(not ok,'enabled NEXT accepted no advance or two advances')
    end
    actions.tap(frame,input,session,context,S.new(),'next',button.x,button.y)
    local view=session.visibility.errors
    for _=1,100 do
      if not view.errorNext then break end
      input({id='next',session=session})
      frame=context.screens.errors.render(15,10,session)
    end
    assert(not view.errorNext,'error detail paging did not terminate')
    button=assert(nextButton(frame),'required muted NEXT beside PREV')
    actions.tap(frame,input,session,context,S.new(),'next',button.x,button.y,true)
    local ok=pcall(actions.tap,frame,function() view.errorPage=view.errorPage+1 end,session,context,S.new(),'next',button.x,button.y,true)
    assert(not ok,'muted NEXT accepted a page advance')
  end)

  test('UB-28 builder and pocket pagers require exactly one page advance', function()
    local A=dofile('tests/ui/size-adapters.lua')
    local actions=dofile('tests/ui/size-actions.lua')
    for _,case in ipairs({{'build-picker',29,12},{'pocket-shop',15,10}}) do
      A.reset()
      local frame,input,session=A.render(case[1],'scene',case[2],case[3])
      local context=A.context
      local button
      for _,b in ipairs(frame.buttons) do if b.id=='next' then button=b end end
      assert(button,'required enabled NEXT for '..case[1])
      for _,broken in ipairs({function() end,function(e) input(e) input(e) end}) do
        local ok=pcall(actions.tap,frame,broken,session,context,S.new(),'next',button.x,button.y)
        assert(not ok,case[1]..' accepted no advance or two advances')
      end
      actions.tap(frame,input,session,context,S.new(),'next',button.x,button.y)
    end
  end)

end
