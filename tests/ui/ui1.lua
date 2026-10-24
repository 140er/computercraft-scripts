local R = dofile('tests/ui/render.lua')
local U = dofile('so-ui.lua')
local function model()
  local m = { time = '21:14', alert = 'ore chest full (drop 3)',
    alerts = {{key='mine:3',text='ore chest full',detail='drop point #3 at 10,64,-2',sub='turtle #3 parked until it is emptied'}},
    okShort='3 ok',lostShort='0 lost',oreShort='+12 / 10 min', log={},
    terminalSubs={'ok','fresh','2.1 MB','see log'}, tiles={} }
  local data = {
    {'TURTLES','3','3 ok, 0 lost','d'}, {'LEASES','2','','b'}, {'ALERTS','1','ore chest full','e'},
    {'ORE TODAY','214','+12','b'}, {'LOGS TODAY','96','','d'}, {'DISK','13%','2.1 of 16 MB','d'},
    {'DISPLAYS','4','all fresh','d'}, {'DROPS','5','1 broken','1'}, {'PAIR','','','9'},
  }
  for i,t in ipairs(data) do m.tiles[i]={label=t[1],value=t[2],sub=t[3],bg=t[4]} end
  return m
end
local function capture(frame,w,h)
  local out = R.capture(w,h)
  for y,row in ipairs(frame.rows) do
    local fg,bg={},{}
    for _,run in ipairs(row.runs or {}) do fg[#fg+1]=string.rep(run[2],run[1]); bg[#bg+1]=string.rep(run[3],run[1]) end
    fg,bg=table.concat(fg),table.concat(bg)
    if not row.runs then fg= #row.fg==1 and string.rep(row.fg,#row.text) or row.fg; bg= #row.bg==1 and string.rep(row.bg,#row.text) or row.bg end
    out.setCursorPos(1,y); out.blit(row.text .. string.rep(' ',#fg-#row.text),fg,bg)
  end
  return out
end
local function server()
  local s = {now=0, values={}, machines={}, saved={roles={['2']='status',['3']='status'}},sends={}}
  local proto = dofile('so-proto.lua')
  local env = setmetatable({SO={now=function() return s.now end,proto=proto,pair={key=function() return string.rep('01',32) end},mods={}}},{__index=_G})
  env.os=setmetatable({epoch=function() return s.now end,getComputerID=function() return 1 end},{__index=os})
  env.SO.proto=assert(loadfile('so-proto.lua','t',env))()
  env.fs={getCapacity=function() return 16000000 end,getFreeSpace=function() return 13900000 end}
  env.SO.mods.state={view=function() return {values=s.values} end,get=function() return s.machines end}
  env.SO.mods.lease={status=function(id) return {open=id==2 and 'lease',lost=id==4} end}
  env.SO.mods.drops={list=function() return {{broken=true},{}} end}
  env.SO.store={store=function() return {value=s.saved,save=function(v) s.saved=v return true end} end}
  env.rednet={send=function(id,wire) s.sends[id]=wire end}
  local d=assert(loadfile('so-mod-display.lua','t',env))()
  local function frame(id,w,h)
    d.handlers.hello({from=id,body={w=w or 57,h=h or 24}})
    local got
    d.handlers['view.get']({from=id},function(_,b) got=b end)
    return got
  end
  local function tap(id,button)
    d.handlers.input({from=id,body={id=button or 'dismiss',x=1,y=1}})
  end
  return d,s,frame,tap
end
return function(test,equal)
  test('UI1 screen strings contain no instruction verbs or return hints',function()
    for _,path in ipairs({'so-ui.lua','so-mod-display.lua','so-mod-panel.lua','so-mod-ar.lua',
        'so-mod-mine.lua','so-mod-lumber.lua','so-mod-drops.lua','so-mod-shop.lua','so-mod-map.lua'}) do
      local file=assert(io.open(path));local source=file:read('*a');file:close()
      for _,text in source:gmatch("(['\"])(.-)%1") do
        text=text:lower()
        for _,verb in ipairs({'press','choose','tap'}) do
          assert(not text:find('%f[%a]'..verb..' '),path..': '..text)
        end
        assert(not text:find('back to ',1,true),path..': '..text)
      end
    end
  end)
  test('UI1 font decodes all nine cells of every spec glyph',function()
    local file=assert(io.open('docs/ui/BIG-TILES-SPEC.md')); local spec=file:read('*a');file:close()
    local count,inversions=0,0
    for ch,line in spec:match('## 4%. Big digit font(.-)## 5%.'):gmatch('\n([0-9%%%-:/]):  ([.# ][^\n]+)') do
      local expected=line:gsub(' ','')
      equal(U.font[ch],expected)
      local rows=U.glyph(ch,'f','d'); local pixels={}
      for y=1,9 do pixels[y]='' end
      for r,row in ipairs(rows) do
        equal(#row.text,3)
        for c=1,3 do
          local bits=row.text:byte(c)-128
          if row.bg:sub(c,c)=='f' then bits=63-bits; inversions=inversions+1 end
          for dy=0,2 do
            for dx=0,1 do
              local y=(r-1)*3+dy+1
              pixels[y]=pixels[y] .. (math.floor(bits/2^(dy*2+dx))%2==1 and '#' or '.')
            end
          end
        end
      end
      equal(pixels[1],'......');equal(pixels[9],'......')
      for y=1,7 do equal(pixels[y+1],expected:sub((y-1)*5+1,y*5)..'.') end
      count=count+1
    end
    equal(count,14);assert(inversions>0)
  end)
  test('UI1 status matches all size fixtures in both layers',function()
    for _,size in ipairs({'M','L','P','XS','T'}) do
      local fixture=R.load('tests/ui/fixtures/status-'..size..'.txt')
      local m=model()
      if size=='L' then m.alert='ore chest full' end
      local got=capture(U.status(m,fixture.w,fixture.h),fixture.w,fixture.h).picture()
      if size=='P' then fixture.h=19;got.h=19 end
      local diff=R.diff(fixture,got)
      assert(#diff==0,size..'\n'..table.concat(diff,'\n'))
    end
  end)
  test('UI1 takeover matches alert fixture',function()
    local m=model();m.takeover=m.alerts[1];m.takeover.count=3
    local diff=R.diff('tests/ui/fixtures/alert-M.txt',capture(U.alert(m,57,24),57,24))
    assert(#diff==0,table.concat(diff,'\n'))
  end)
  test('UI1 contrast respects ink including inverted glyph cells',function()
    for _,size in ipairs({'M','L','P','XS','T'}) do
      local fixture=R.load('tests/ui/fixtures/status-'..size..'.txt')
      local frames={U.status(model(),fixture.w,fixture.h),U.alert(model(),fixture.w,fixture.h)}
      for _,frame in ipairs(frames) do
        local out=capture(frame,fixture.w,fixture.h)
        for _,row in ipairs(out.cells) do for _,cell in ipairs(row) do
          local fg,bg=cell[2],cell[3]
          if cell[1]:byte()>=128 and cell[1]:byte()<=159 and bg=='f' and fg~='0' and fg~='8' then fg,bg=bg,fg end
          assert((bg=='f' or bg=='7' or bg=='c') and (fg=='0' or fg=='8') or
            (bg=='d' or bg=='1' or bg=='e' or bg=='b' or bg=='a' or bg=='9') and fg=='f','contrast '..fg..'/'..bg)
        end end
      end
    end
  end)
  test('UI1 odd sizes and blocks stay inside the canvas',function()
    for _,size in ipairs({{100,38},{36,10},{1,1},{29,12}}) do
      local frame=U.status(model(),unpack(size))
      equal(#frame.rows,size[2]); capture(frame,unpack(size))
      for _,b in ipairs(frame.buttons) do assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=size[1] and b.y+b.h-1<=size[2]) end
      for _,r in ipairs(frame.rows) do local width=0;for _,run in ipairs(r.runs) do width=width+run[1] end;equal(width,size[1]) end
    end
    local c=U.canvas(20,10);c.listRow(2,'ready','d');c.search(2,3,12,'iron','find');c.tile(1,5,12,'LONG','123456','fallback','b')
    local out=capture(c.frame(),20,10).picture()
    assert(out.text[8]:find('123456',1,true));equal(out.bg[3]:sub(2,13),string.rep('0',12))
    equal(U.size(51,19),'T');local cols,rows=U.grid(100,38);equal(#cols,5);equal(rows,4)
  end)
  test('UI1 padded tiles keep titles and full big values inside their rows',function()
    for _,height in ipairs({6,7}) do
      local c=U.canvas(26,20)
      c.tile(1,4,26,'TURTLES','12345','0 ok, 0 lost','d',height)
      local out=capture(c.frame(),26,20).picture()
      assert(out.text[4]:match('^%s*$'))
      assert(out.text[5]:find('TURTLES',1,true))
      assert(out.text[4+height-1]:match('^%s*$'))
      for y=4,4+height-1 do
        equal(out.bg[y]:sub(1,1),'f');equal(out.bg[y]:sub(26),'f')
        assert(out.text[y]:sub(1,2)=='  ')
      end
      local expected=U.canvas(26,20);expected.big(3,6,22,'12345','d')
      local digits=capture(expected.frame(),26,20).picture()
      for y=6,8 do equal(out.text[y],digits.text[y]) end
      if height==7 then assert(out.text[9]:find('0 ok, 0 lost',1,true)) end
    end
    for _,size in ipairs({{26,20},{29,12},{57,24},{100,38},{164,81}}) do
      local f=U.status(model(),size[1],size[2])
      assert(f.rows[1].text=='')
      local text=table.concat((function() local rows={} for _,r in ipairs(f.rows) do rows[#rows+1]=r.text end return rows end)(),'\n')
      assert(text:find('TURTLES',1,true))
      if size[2]>=38 then assert(text:find('3 ok, 0 lost',1,true));assert(text:find('PAIR',1,true)) end
    end
  end)
  test('UI1 gathering reads real sources and leaves unsupported totals stale',function()
    local d,s,frame=server()
    s.machines={['2']={role='worker'},['4']={role='worker'}}
    local got=frame(2)
    equal(got.palette,U.palette);equal(got.scale,0.5)
    local text=capture(got,57,24).picture().text
    assert(text[5]:find('TURTLES',1,true));assert(text[12]:find('ORE TODAY',1,true))
    assert(text[19]:find('BROKEN',1,true));assert(text[12]:find('DISK',1,true))
    assert(d.far(2,true));equal(frame(2).scale,1)
  end)
  test('UI1 roleless machine rows count turtles, open leases and lost workers',function()
    local _,s,frame=server()
    s.machines={
      ['2']={id=2,fuel=812,seen=1000,pose={dim='minecraft:overworld',x=12,y=60,z=-9,facing=0}},
      ['4']={id=4,fuel=640,seen=500,pose={dim='minecraft:overworld',x=0,y=61,z=-1,facing=1}},
      ['9']={id=9,role='display',seen=1000},
    }
    local got=capture(frame(2),57,24)
    local expectedModel=model()
    expectedModel.tiles[1].value='2'
    expectedModel.tiles[1].sub='1 ok, 1 lost'
    expectedModel.tiles[1].bg='e'
    expectedModel.tiles[2].value='1'
    local expected=capture(U.status(expectedModel,57,24),57,24)
    for y=4,8 do
      for x=1,38 do equal(got.cells[y][x],expected.cells[y][x]) end
    end
    assert(got.picture().text[5]:find('TURTLES',1,true))
  end)
  test('UI1 takeover expires at five seconds, dismisses and throttles per session',function()
    local _,s,frame,tap=server()
    s.values['mine.alert']={text='first'}
    local first=frame(2);equal(first.buttons[1].id,'dismiss')
    s.now=4999;equal(frame(2).buttons[1].id,'dismiss')
    s.now=5000;equal(frame(2).buttons[1].id,'alerts')
    s.now=10000;s.values['mine.alert']={text='second'};equal(frame(2).buttons[1].id,'alerts')
    equal(frame(3).buttons[1].id,'dismiss');tap(3);equal(frame(3).buttons[1].id,'alerts')
    s.now=30000;equal(frame(2).buttons[1].id,'alerts')
    s.values['mine.alert']={text='third'};equal(frame(2).buttons[1].id,'dismiss')
    tap(2);equal(frame(2).buttons[1].id,'alerts')
    tap(2,'alerts');equal(frame(2).buttons[1].id,'dismiss');tap(2)
    s.now=100000;equal(frame(2).buttons[1].id,'alerts')
  end)
  test('UI1 subscribed frames retain all rows and expire takeovers on tick',function()
    local d,s,frame,tap=server()
    s.values['mine.alert']={text='fault'}
    frame(2)
    d.handlers['view.sub']({from=2})
    equal(s.sends[2].body.buttons[1].id,'dismiss')
    equal(#s.sends[2].body.rows,24)
    s.now=4999;d.tick(s.now)
    equal(s.sends[2].body.buttons[1].id,'dismiss')
    s.now=5000;d.tick(s.now)
    equal(s.sends[2].body.buttons[1].id,'alerts')
    equal(#s.sends[2].body.rows,24)
    assert(d.far(2,true));d.tick(s.now)
    equal(s.sends[2].body.scale,1);equal(s.sends[2].body.palette,U.palette)
    tap(2,'alerts');equal(s.sends[2].body.buttons[1].id,'dismiss')
    tap(2,'dismiss');equal(s.saved.roles['2'],'status')
    equal(s.sends[2].body.buttons[1].id,'alerts')
  end)
  test('UI1 latest changed alert wins and frames fit the wire budget',function()
    local d,s,frame=server()
    s.values['mine.alert']={text='old'}
    frame(2)
    s.now=30000;s.values['lumber.alert']={text='newest'}
    local got=frame(2)
    assert(capture(got,57,24).picture().text[12]:find('NEWEST',1,true))
    assert(#dofile('so-proto.lua').ser(got)<15000)
    local first=frame(3,15,10)
    frame(2,39,19)
    equal(frame(3,15,10).rev,first.rev)
    s.now=35000
    assert(capture(frame(2),57,24).picture().text[3]:find('newest',1,true))
  end)
  test('UI1 XS cycles tiles and status buttons select their roles',function()
    local _,_,frame,tap=server()
    local a=capture(frame(2,15,10),15,10).picture();tap(2,'next')
    local b=capture(frame(2,15,10),15,10).picture();assert(a.text[4]~=b.text[4])
    for _,role in ipairs({'mining','lumber','shop','generic'}) do
      local d,s,f,t=server();d.screen(role,function() return {rows={{text=role,fg='0',bg='f'}}} end)
      f(2);t(2,role);equal(s.saved.roles['2'],role)
    end
  end)
  test('UI1 old renderers receive size and revisions remain independent',function()
    local d,_,frame=server()
    for _,role in ipairs({'mining','lumber','shop','drops','ar','generic'}) do
      local seen
      d.screen('status',function(w,h) seen={w,h};return {rows={{text=role,fg='0',bg='f'}}} end)
      local a=frame(2,57,24);equal(seen,{57,24});equal(a.rows[1].text,role)
      frame(2,39,19);equal(frame(2,57,24).rev,a.rev)
    end
  end)
  test('UI1 kit installs only on the server',function()
    local f=assert(io.open('install.lua'));local s=f:read('*a');f:close()
    local roles=s:match('local ROLES = (.-)\n}') or s:match('ROLES = (.-)\n}')
    assert(roles:match('server = .-"so%-ui.lua"'))
    assert(not roles:match('worker = ([^}]+)'):find('so-ui.lua',1,true))
    assert(not roles:match('display = ([^}]+)'):find('so-ui.lua',1,true))
  end)
end
