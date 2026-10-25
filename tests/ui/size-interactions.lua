local S = dofile('tests/ui/scene.lua')
local R = dofile('tests/ui/render.lua')
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
  test('UB-28 local input height and compact frame fallback retain the expected cells', function()
    local s=S.new()
    local U=dofile('so-ui.lua')
    for _,size in ipairs(sizes) do
      local w,h=size[1],size[2]
      s.d.handlers.hello({from=91,body={w=w,h=h-1,fullH=h,keyboard=true}})
      local session=s.D.sessions[91]
      equal(session.h,h)
      s.D.model=s.D.gather()
      local frame=s.D.compose('status',w,h,session)
      equal(#frame.rows,h)
      local diff=R.diff(S.capture(U.status(s.D.gather(),w,h),w,h).picture(),S.capture(frame,w,h))
      equal(diff,{})
    end
    local model=s.D.gather()
    model.turtles={}
    for i=1,40 do model.turtles[i]={id=i,state='mining',where='b10',x=184,y=-58,z=-369,fuel=412,ore=10,ago=1000} end
    model.events={}
    for i=1,30 do model.events[i]={time='21:14',text='a long lane wait after returning from the mining branch',tone='1'} end
    s.D.model=model
    s.D.budget=#s.env.SO.proto.ser(s.D.fit(U.status(model,164,81),164,81))-1
    local frame=s.D.statusFrame({alertSeen={}},164,81,s.now)
    model.tight=true
    local expected=U.status(model,164,81)
    equal(R.diff(S.capture(expected,164,81).picture(),S.capture(frame,164,81)),{})
    assert(#s.env.SO.proto.ser(s.D.fit(frame,164,81))<16384,'compact frame budget')
  end)
end
