local H = dofile('tests/so/harness.lua')
local R = dofile('tests/ui/render.lua')
local function boot()
  local m = H.new().machine({id=1,capacity=16000000})
  m.install({'so-store.lua','so-ui.lua','so-mod-drops.lua','so-mod-ar.lua','so-mod-display.lua'})
  local e=m.env
  e.SO={ now = function() return e.os.epoch("utc") end,mods={},store=e.dofile('so-store.lua'),proto={ser=H.encode},pair={key=function() return 'key' end}}
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
-- The route A rule for coloured glyphs (docs/ui/SCHEMATIC-SPEC.md, section 3).
local function contrast(out)
  for _,row in ipairs(out.cells) do for _,cell in ipairs(row) do
    local ch,fg,bg=cell[1],cell[2],cell[3]
    local ok=ch==' ' or (bg=='f' or bg=='7') and (('0389d1eba2'):find(fg,1,true) or fg=='c' and ('-|+\183\166'):find(ch,1,true))
      or bg=='c' and (fg=='0' or fg=='3') or not ('f7c'):find(bg,1,true) and fg=='f'
    assert(ok,'contrast '..fg..'/'..bg..' '..ch)
  end end
end
-- Five points, the last one broken.
local function points(d)
  for i,p in ipairs({{'ore',10,64,-2,'front'},{'fuel',12,64,-2,'front'},{'wood',-4,64,10,'front'},
    {'storage',-6,64,10,'front'},{'any',0,64,4,'down'}}) do
    assert(d.add({id='p'..i,kind=p[1],dim=0,x=p[2],y=p[3],z=p[4],side=p[5]}))
  end
  for _=1,3 do d.note('p5') end
end
local function tapper(ui) return function(session,id) ui.input({id=id,session=session,from=session.id}) end end
local function saves(s)
  local n,save={count=0},s.box.save
  s.box.save=function(v) n.count=n.count+1 return save(v) end
  return n
end
return function(test,equal)
  test('UI2d drop drafts stay per display through ADD and BACK; NEW after ADD starts from the selection',function()
    local d,_,screens,s=boot();local ui=screens.generic;local tap=tapper(ui)
    assert(d.add({id='p1',kind='ore',dim=0,x=1,y=64,z=0,side='front',room=true}))
    local a,b={id=7},{id=8}
    tap(a,'new');tap(a,'x+');tap(a,'x+')
    tap(b,'new');tap(b,'z+')
    -- Each editor starts from p1 with its room mark; nudges on one display leave the other alone.
    equal({s.views[7].draft.x,s.views[7].draft.z,s.views[7].draft.room},{3,0,true})
    equal({s.views[8].draft.x,s.views[8].draft.z,s.views[8].draft.room},{1,1,true})
    tap(a,'list');tap(a,'new');equal(s.views[7].draft.x,3)
    tap(b,'add');equal(#d.list(),2);equal({d.list()[2].x,d.list()[2].z,d.list()[2].room},{1,1,true})
    equal(s.views[7].draft.x,3)
    tap(b,'list');tap(b,'select:p1');tap(b,'new');equal({s.views[8].draft.x,s.views[8].draft.z},{1,0})
  end)
  test('UI2d a drop draft idle for five minutes is dropped and nothing is saved',function()
    local d,_,screens,s,_,e=boot();local ui=screens.generic;local tap=tapper(ui)
    local clock=1000;e.SO.now=function() return clock end
    assert(d.add({id='p1',kind='ore',dim=0,x=1,y=64,z=0,side='front'}))
    local n=saves(s)
    local a,b={id=7},{id=8}
    tap(a,'new');tap(a,'x+');tap(b,'new');tap(b,'y+')
    clock=clock+200000;tap(b,'y+')
    clock=clock+99999;d.tick();assert(s.views[7].draft)
    clock=clock+1;d.tick()
    equal({s.views[7].draft,s.views[7].editing},{nil,false})
    assert(capture(ui.render(57,24,a),57,24).picture().text[1]:find('DROP POINTS',1,true))
    equal(s.views[8].draft.y,66)
    clock=clock+200000;d.tick();equal(s.views[8].draft,nil)
    equal({n.count,#d.list(),d.list()[1].x,d.list()[1].y},{0,1,1,64})
    -- NEW after the discard starts from the selection again.
    tap(a,'new');equal(s.views[7].draft.x,1)
  end)
  test('UI2d drop REMOVE arms on the first tap and removes on the second',function()
    local d,_,screens,_,_,e=boot();local ui=screens.generic;local tap=tapper(ui)
    local clock=1000;e.SO.now=function() return clock end
    for i=1,3 do assert(d.add({id='p'..i,kind='ore',dim=0,x=i,y=64,z=0,side='front'})) end
    local a,b={id=7},{id=8}
    tap(a,'select:p2');tap(a,'remove');equal(#d.list(),3)
    local row=capture(ui.render(57,24,a),57,24).picture().text[23]
    assert(row:find('CONFIRM',1,true) and not row:find('REMOVE',1,true),row)
    assert(capture(ui.render(57,24,b),57,24).picture().text[23]:find('REMOVE 1',1,true),'armed per display')
    -- A tap elsewhere disarms; another display's taps do not.
    tap(a,'select:p3');tap(a,'remove');tap(b,'select:p1');tap(a,'remove')
    equal({#d.list(),d.list()[1].id,d.list()[2].id},{2,'p1','p2'})
    tap(a,'select:p2');tap(a,'remove');tap(a,'select:p2');tap(a,'remove');equal(#d.list(),2)
    -- The arm lapses after five seconds.
    tap(a,'select:p2');tap(a,'remove');clock=clock+5001;tap(a,'remove');equal(#d.list(),2)
    assert(capture(ui.render(57,24,a),57,24).picture().text[23]:find('CONFIRM',1,true))
    clock=clock+6000;assert(capture(ui.render(57,24,a),57,24).picture().text[23]:find('REMOVE 2',1,true))
    tap(a,'remove');tap(a,'remove');equal({#d.list(),d.list()[1].id},{1,'p1'})
  end)
  test('UI2d EDIT keeps the id, saves once, keeps verified only in place and rolls back a failed save',function()
    local d,_,screens,s=boot();local ui=screens.generic;local tap=tapper(ui)
    assert(d.add({id='p1',kind='ore',dim=0,x=1,y=64,z=0,side='front'}))
    assert(d.add({id='p2',kind='fuel',dim=0,x=2,y=64,z=0,side='front'}))
    s.points[2].verified,s.points[2].fails={at=5,block='minecraft:chest'},1
    local n=saves(s);local a={id=7}
    tap(a,'select:p2')
    assert(capture(ui.render(57,24,a),57,24).picture().text[23]:find('EDIT 2',1,true))
    tap(a,'fix')
    local text=capture(ui.render(57,24,a),57,24).picture().text
    assert(text[1]:find('EDIT POINT 2',1,true) and text[23]:find('SAVE',1,true) and not text[23]:find('ADD',1,true),text[1])
    -- Kind only (fuel to ore): one save, same id, verified state and strikes kept.
    tap(a,'kind');tap(a,'save')
    equal({n.count,#d.list(),d.list()[2].id,d.list()[2].kind,s.points[2].fails},{1,2,'p2','ore',1})
    equal(d.list()[2].verified,{at=5,block='minecraft:chest'})
    assert(capture(ui.render(57,24,a),57,24).picture().text[22]:find('point saved',1,true))
    -- Point 2's y and kind (ore to junk): one row with the new kind, unverified, no strikes.
    tap(a,'edit');tap(a,'y+');tap(a,'kind');tap(a,'save')
    equal({n.count,#d.list(),d.list()[2].id,d.list()[2].y,d.list()[2].kind,d.list()[2].verified,s.points[2].fails},
      {2,2,'p2',65,'junk',nil,0})
    -- A failed save restores the list and keeps the editor open.
    tap(a,'edit');tap(a,'x+');local save=s.box.save;s.box.save=function() return false,'disk full' end
    tap(a,'save');s.box.save=save
    equal({#d.list(),d.list()[2].x,s.views[7].editing},{2,2,true})
    -- A place another point holds is refused.
    tap(a,'x-');tap(a,'x-');tap(a,'y-');for _=1,5 do tap(a,'kind') end;tap(a,'save')
    equal({s.message,#d.list(),d.list()[2].x},{'id exists',2,2})
    -- NEW from the edit starts a fresh draft at the selection, not the edit.
    tap(a,'list');tap(a,'new');equal({s.views[7].edit,s.views[7].draft.x,s.views[7].draft.y},{nil,2,65})
    assert(capture(ui.render(57,24,a),57,24).picture().text[1]:find('ADD DROP POINT',1,true))
  end)
  test('UI2d ADD after EDIT checks the current place and never reuses a moved point id',function()
    local d,_,screens,s=boot();local ui=screens.generic;local tap=tapper(ui)
    local a={id=7}
    tap(a,'new');tap(a,'x+');tap(a,'add')
    local first='0_1_64_0_front_ore'
    equal({#d.list(),d.list()[1].id},{1,first})
    -- EDIT moves the point to x 2; it keeps the id made for x 1.
    tap(a,'list');tap(a,'select:'..first);ui.render(57,24,a);tap(a,'fix');tap(a,'x+');tap(a,'save')
    equal({#d.list(),d.list()[1].id,d.list()[1].x},{1,first,2})
    -- ADD at x 2 is the edited point: refused, no duplicate under a new id.
    tap(a,'list');tap(a,'new');equal(s.views[7].draft.x,2);tap(a,'add')
    equal({s.message,#d.list()},{'id exists',1})
    tap(a,'x-');tap(a,'add')
    -- ADD at x 1 is a new point; x 1's own id is taken, so it gets the next free one.
    equal({s.message,#d.list(),d.list()[2].id,d.list()[2].x},{'point added',2,first..'_2',1})
    tap(a,'add');equal({s.message,#d.list()},{'id exists',2})
    -- A typed add of the edited point's place still reads as added and adds nothing.
    ui.input({text='add ore 2 64 0',session=a,from=7});equal({s.message,#d.list()},{'point added',2})
  end)
  test('UI2d EDIT and an armed REMOVE match their fixtures',function()
    local s3=dofile('tests/ui/s3.lua');local drops
    for i=1,40 do local k,v=debug.getupvalue(s3,i);if k=='drops' then drops=v end end
    local t=assert(drops,'s3 drops')()
    local id=t.S.points[2].id
    for i,c in ipairs({{'dropsedit-M',57,24,'edit'},{'dropsedit-P',26,20,'edit'},{'dropsremove-P',26,20,'remove'},
        {'dropsremove-XS',15,10,'remove'}}) do
      local session={id=20+i}
      t.tap(session,'select:'..id);t.tap(session,c[4])
      equal(R.diff('tests/ui/fixtures/'..c[1]..'.txt',capture(t.render(c[2],c[3],session),c[2],c[3])),{})
    end
    equal({t.saves,#t.mod.list()},{0,#t.S.points})
    local started,pipe=pcall(io.popen,'pwd')
    local root=started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1,1)~='/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('UI2d drops generator','needs host processes, a POSIX shell and python3')
    end
    local dir=os.tmpname();os.remove(dir)
    assert(os.execute("python3 -I '"..root.."/docs/ui/schematic/screens.py' --fixtures '"..dir.."' dropsedit-M dropsedit-P dropsremove-P dropsremove-XS > /dev/null"))
    for _,name in ipairs({'dropsedit-M','dropsedit-P','dropsremove-P','dropsremove-XS'}) do
      local f1,f2=assert(io.open(dir..'/'..name..'.txt','rb')),assert(io.open('tests/ui/fixtures/'..name..'.txt','rb'))
      equal(f1:read('*a'),f2:read('*a'));f1:close();f2:close()
    end
    assert(os.execute("rm -r '"..dir.."'"))
  end)
  test('UI2d drops select the broken point and AR matches its M mockup cell by cell',function()
    local d,_,screens,s,a=boot();points(d)
    assert(s.layout and a.layout,'pure layouts')
    local text=capture(screens.generic.render(57,24),57,24).picture().text
    assert(text[8]:find('5  any',1,true) and text[10]:find('! 5 any broken',1,true),text[10])
    assert(text[23]:find('FIX 5',1,true) and text[23]:find('REMOVE 5',1,true) and text[23]:find('ADD',1,true),text[23])
    equal(R.diff('tests/ui/fixtures/ar-M.txt',capture(a.layout({count=1,layers={turtles=true,leases=true,drops=false,alerts=true}},57,24),57,24)),{})
  end)
  test('UI2d selected drop actions and draft editor preserve stored points',function()
    local d,_,screens=boot();local ui=screens.generic
    for i=1,2 do assert(d.add({id='p'..i,kind='ore',dim=0,x=i,y=64,z=0,side='front'}));for _=1,3 do d.note('p'..i) end end
    ui.render(57,24);ui.input({id='fix'});assert(not d.list()[1].broken);assert(d.list()[2].broken)
    local fixed=ui.render(57,24);assert(capture(fixed,57,24).picture().text[23]:find('EDIT 1',1,true))
    ui.input({id='select:p2'});ui.input({id='fix'});assert(not d.list()[2].broken)
    ui.input({id='remove'});equal(#d.list(),2);ui.input({id='remove'});equal(#d.list(),1);equal(d.list()[1].id,'p1')
    ui.input({id='new'});local f=ui.render(15,10);local found={};for _,b in ipairs(f.buttons) do found[b.id]=true end
    for _,id in ipairs({'kind','side','dim+','dim-','x+','x-','y+','y-','z+','z-','add','list'}) do assert(found[id],id) end
    ui.input({id='kind'});ui.input({id='side'});ui.input({id='x+'});ui.input({id='add'})
    -- ADD starts the draft at the selected point (p1 at x 1).
    equal(#d.list(),2);equal(d.list()[2].x,2);equal(d.list()[2].side,'down');equal(d.list()[2].kind,'junk')
  end)
  test('UI2d drop paging exposes all points without overlapping controls',function()
    local d,_,screens=boot();local ui=screens.generic
    for i=1,64 do assert(d.add({id='p'..i,kind='ore',dim=0,x=i,y=64,z=0,side='front'})) end
    local seen={}
    for _=1,64 do
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
    local first
    for _,b in ipairs(ui.render(57,24).buttons) do first=first or b.id:match('^select:') and b.id end
    equal(first,'select:p37')
    ui.input({id='select:p64'});ui.input({id='remove'});ui.input({id='remove'});equal(#d.list(),63)
  end)
  test('UI2d AR row toggles once and survives reload',function()
    local _,_,screens,_,_,e=boot();local n=0;local store=e.SO.store.store
    e.SO.store.store=function(...) local b=store(...);local save=b.save;b.save=function(v) n=n+1;return save(v) end;return b end
    local ar=e.dofile('so-mod-ar.lua');ar.tick(0);screens.ar.input({id='drops'});equal(n,1)
    local reloaded=e.dofile('so-mod-ar.lua');reloaded.tick(0)
    -- Route A: the drops row (row 9 at 57x24) reads [off]; tests/ui/ra3-ar.lua has the fixtures.
    assert(capture(screens.ar.render(57,24),57,24).picture().text[9]:find('[off]',1,true))
  end)
  test('UI2d layouts fit all sizes and respect contrast',function()
    local d,_,screens,s,a=boot();points(d);assert(s.layout and a.layout,'pure layouts')
    for _,size in ipairs({{26,20},{39,19},{57,24},{15,10},{100,38},{36,10},{29,12}}) do
      local w,h=unpack(size)
      screens.generic.input({id='new'});local draft=screens.generic.render(w,h);screens.generic.input({id='list'})
      for _,frame in ipairs({draft,screens.generic.render(w,h)}) do
        equal(#frame.rows,h)
        for _,b in ipairs(frame.buttons) do assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h) end
        contrast(capture(frame,w,h))
      end
      local frame=a.layout({count=1,layers={turtles=true,leases=false,drops=true,alerts=false}},w,h)
      equal(#frame.rows,h)
      for _,b in ipairs(frame.buttons) do assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h) end
      contrast(capture(frame,w,h))
    end
  end)
  test('UI2d taps keep each role and the drop list draws no links',function()
    local _,_,screens,_,_,e=boot();local display=e.dofile('so-mod-display.lua');e.SO.mods.display=display
    local U=e.dofile('so-ui.lua')
    for _,role in ipairs({'mining','lumber','shop','ar','generic'}) do
      display.screen(role,screens[role] and screens[role].render or function(w,h) local c=U.canvas(w,h);c.button(1,h,w,'BACK','status','7',1);return c.frame() end,screens[role] and screens[role].input)
    end
    local function frame() local f;display.handlers['view.get']({from=2},function(_,v) f=v end);return f end
    local function tap(id)
      local f=frame();local x,y=1,1
      for _,b in ipairs(f.buttons) do if b.id==id then x,y=b.x,b.y break end end
      display.handlers.input({from=2,body={id=id,x=x,y=y}})
    end
    display.handlers.hello({from=2,body={w=57,h=24}})
    equal(frame().role,'unassigned')
    for _,role in ipairs({'mining','lumber','shop','ar','generic'}) do
      assert(display.assign(2,role))
      for _,id in ipairs({'status','generic','mining','lumber','shop','ar','panel','map','map-back'}) do tap(id);equal(frame().role,role) end
    end
    assert(display.assign(2,'drops'));tap('list');local f=frame();assert(f.rows[1].text:find('DROP POINTS',1,true))
    local found={};for _,b in ipairs(f.buttons) do found[b.id]=true;assert(b.y>1) end
    assert(found.new and not found.status and not found.mining and not found.panel and not found.map)
  end)
end
