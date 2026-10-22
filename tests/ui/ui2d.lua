local H = dofile('tests/so/harness.lua')
local R = dofile('tests/ui/render.lua')
local function boot()
  local m = H.new().machine({id=1,capacity=16000000})
  m.install({'so-store.lua','so-ui.lua','so-mod-drops.lua','so-mod-ar.lua','so-mod-display.lua'})
  local e=m.env
  e.SO={mods={},store=e.dofile('so-store.lua'),proto={ser=H.encode},pair={key=function() return 'key' end}}
  local screens={}
  e.SO.mods.display={screen=function(role,render,input) screens[role]={render=render,input=input} end}
  local drops=e.dofile('so-mod-drops.lua');local ar=e.dofile('so-mod-ar.lua')
  e.peripheral.find=function() return {} end
  drops.tick();ar.tick(0)
  local function state(fn)
    for i=1,10 do local k,v=debug.getupvalue(fn,i);if k=='S' or k=='A' then return v end end
  end
  return drops,ar,screens,state(screens.generic.render),state(screens.ar.render),e
end
local function capture(frame,w,h)
  local out=R.capture(w,h)
  for y,row in ipairs(frame.rows) do
    local fg,bg={},{}
    for _,r in ipairs(row.runs or {}) do fg[#fg+1]=string.rep(r[2],r[1]);bg[#bg+1]=string.rep(r[3],r[1]) end
    fg,bg=table.concat(fg),table.concat(bg)
    out.setCursorPos(1,y);out.blit(row.text..string.rep(' ',#fg-#row.text),fg,bg)
  end
  return out
end
local function mock()
  local points={}
  for i,p in ipairs({{'ore',10,64,-2,'front'},{'fuel',12,64,-2,'front'},{'wood',-4,64,10,'front'},
    {'saplings',-6,64,10,'front'},{'any',0,64,4,'down'}}) do
    points[i]={id='p'..i,kind=p[1],x=p[2],y=p[3],z=p[4],side=p[5],fails=i==5 and 3 or 0}
  end
  return {points=points,selected='p5',draft={},page=1}
end
return function(test,equal)
  test('UI2d drops and AR match M mockups cell by cell',function()
    local _,_,_,s,a=boot()
    assert(s.layout and a.layout,'pure layouts')
    equal(R.diff('tests/ui/fixtures/drops-M.txt',capture(s.layout(mock(),57,24),57,24)),{})
    equal(R.diff('tests/ui/fixtures/ar-M.txt',capture(a.layout({count=1,layers={turtles=true,leases=true,drops=false,alerts=true}},57,24),57,24)),{})
  end)
  test('UI2d selected drop actions and draft editor preserve stored points',function()
    local d,_,screens=boot();local ui=screens.generic
    for i=1,2 do assert(d.add({id='p'..i,kind='ore',dim=0,x=i,y=64,z=0,side='front'}));for _=1,3 do d.note('p'..i) end end
    ui.render(57,24);ui.input({id='fix'});assert(not d.list()[1].broken);assert(d.list()[2].broken)
    local fixed=ui.render(57,24);assert(capture(fixed,57,24).picture().text[12]:find('FIX #1',1,true))
    ui.input({id='select:p2'});ui.input({id='fix'});assert(not d.list()[2].broken)
    ui.input({id='remove'});equal(#d.list(),1);equal(d.list()[1].id,'p1')
    ui.input({id='new'});local f=ui.render(15,10);local found={};for _,b in ipairs(f.buttons) do found[b.id]=true end
    for _,id in ipairs({'kind','side','dim+','dim-','x+','x-','y+','y-','z+','z-','add','list'}) do assert(found[id],id) end
    ui.input({id='kind'});ui.input({id='side'});ui.input({id='x+'});ui.input({id='add'})
    equal(#d.list(),2);equal(d.list()[2].x,1);equal(d.list()[2].side,'down');equal(d.list()[2].kind,'junk')
  end)
  test('UI2d drop paging exposes all points without overlapping controls',function()
    local d,_,screens=boot();local ui=screens.generic
    for i=1,64 do assert(d.add({id='p'..i,kind='ore',dim=0,x=i,y=64,z=0,side='front'})) end
    local seen={}
    for _=1,32 do
      local f=ui.render(15,10)
      local cells={}
      for _,b in ipairs(f.buttons) do
        local id=b.id:match('^select:(.+)$');if id then seen[id]=true end
        for y=b.y,b.y+b.h-1 do for x=b.x,b.x+b.w-1 do
          local key=x..','..y;assert(not cells[key],'overlapping buttons');cells[key]=b.id
        end end
      end
      ui.input({id='next'})
    end
    local n=0;for _ in pairs(seen) do n=n+1 end;equal(n,64)
    ui.render(57,24);ui.input({id='prev'})
    local first=ui.render(57,24).buttons[1].id;equal(first,'select:p40')
    ui.input({id='select:p64'});ui.input({id='remove'});equal(#d.list(),63)
  end)
  test('UI2d AR tile toggles once and survives reload',function()
    local _,_,screens,_,_,e=boot();local n=0;local store=e.SO.store.store
    e.SO.store.store=function(...) local b=store(...);local save=b.save;b.save=function(v) n=n+1;return save(v) end;return b end
    local ar=e.dofile('so-mod-ar.lua');ar.tick(0);screens.ar.input({id='drops'});equal(n,1)
    local reloaded=e.dofile('so-mod-ar.lua');reloaded.tick(0)
    assert(capture(screens.ar.render(57,24),57,24).picture().text[7]:find('layer off',1,true))
  end)
  test('UI2d layouts fit all sizes and respect contrast',function()
    local _,_,screens,s,a=boot();assert(s.layout and a.layout,'pure layouts')
    for _,size in ipairs({{26,20},{39,19},{57,24},{15,10},{100,38},{36,10}}) do
      local w,h=unpack(size)
      screens.generic.input({id='new'});local draft=screens.generic.render(w,h);screens.generic.input({id='list'})
      for _,frame in ipairs({draft,s.layout(mock(),w,h),a.layout({count=1,layers={turtles=true,leases=false,drops=true,alerts=false}},w,h)}) do
        equal(#frame.rows,h)
        for _,b in ipairs(frame.buttons) do assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h) end
        for _,row in ipairs(capture(frame,w,h).cells) do for _,cell in ipairs(row) do
          local fg,bg=cell[2],cell[3]
          if cell[1]:byte()>=128 and cell[1]:byte()<=159 and bg=='f' and fg~='0' and fg~='8' then fg,bg=bg,fg end
          assert((bg=='f' or bg=='7' or bg=='c') and (fg=='0' or fg=='8') or
            (bg=='d' or bg=='1' or bg=='e' or bg=='b' or bg=='a' or bg=='9') and fg=='f','contrast '..fg..'/'..bg)
        end end
      end
    end
  end)
  test('UI2d status returns from every role and generic keeps header clear',function()
    local _,_,screens,_,_,e=boot();local display=e.dofile('so-mod-display.lua');e.SO.mods.display=display
    for _,role in ipairs({'mining','lumber','shop','ar','generic'}) do
      display.screen(role,screens[role] and screens[role].render or function() return {rows={},buttons={}} end,screens[role] and screens[role].input)
    end
    local function frame() local f;display.handlers['view.get']({from=2},function(_,v) f=v end);return f end
    local function tap(id) display.handlers.input({from=2,body={id=id,x=1,y=1}}) end
    display.handlers.hello({from=2,body={w=57,h=24}})
    for _,role in ipairs({'mining','lumber','shop','ar'}) do tap('generic');local nav={};for _,b in ipairs(frame().buttons) do nav[b.id]=true end;assert(nav[role],role);tap(role);equal(frame().role,role);tap('status');equal(frame().role,'status') end
    tap('generic');tap('list');local f=frame();assert(f.rows[1].text:find('DROP POINTS',1,true))
    local found={};for _,b in ipairs(f.buttons) do found[b.id]=true;assert(b.y>1) end
    assert(found.status and found.new);tap('status');equal(frame().role,'status');tap('generic')
    display.screen('generic',function() return {rows={},buttons={}} end);f=frame();found={};for _,b in ipairs(f.buttons) do found[b.id]=true end
    assert(found.ar and found.lumber,'legacy fallback')
  end)
end
