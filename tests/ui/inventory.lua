-- B10-U turtleInventory (P-U1-2, design D10): the hello cache, its pure model and the paged
-- inventory page behind the turtle detail. Fixtures come from docs/ui/schematic/other.py and the
-- inventory lines of tests/ui/other-scene.txt.
local U = dofile('so-ui.lua')
local R = dofile('tests/ui/render.lua')

-- Literal paths, so part runs declare every fixture they read.
local FIXTURE = {
  ['inventory-P'] = 'tests/ui/fixtures/inventory-P.txt', ['inventory2-P'] = 'tests/ui/fixtures/inventory2-P.txt',
  ['inventory-XS'] = 'tests/ui/fixtures/inventory-XS.txt', ['inventory3-XS'] = 'tests/ui/fixtures/inventory3-XS.txt',
  ['inventoryempty-S'] = 'tests/ui/fixtures/inventoryempty-S.txt',
  ['inventoryunknown-P'] = 'tests/ui/fixtures/inventoryunknown-P.txt',
  ['inventorystale-M'] = 'tests/ui/fixtures/inventorystale-M.txt', ['turtleinv-S'] = 'tests/ui/fixtures/turtleinv-S.txt',
  ['turtleinvflag-XS'] = 'tests/ui/fixtures/turtleinvflag-XS.txt' }

local function read(path) local f=assert(io.open(path,'rb')) local text=f:read('*a') f:close() return text end

-- The scene's sample: { at, later, list = { {slot,name,count} } } in hello order.
local function scene()
  local s={list={}}
  for line in read('tests/ui/other-scene.txt'):gmatch('[^\n]+') do
    local p={} for w in line:gmatch('%S+') do p[#p+1]=w end
    if p[1]=='inv' and p[2]=='slot' then s.list[#s.list+1]={slot=tonumber(p[3]),name=p[4],count=tonumber(p[5])}
    elseif p[1]=='inv' then s[p[2]]=tonumber(p[3]) end
  end
  return s
end
local SCENE=scene()
local function sample()
  local out={} for i,row in ipairs(SCENE.list) do out[i]={slot=row.slot,name=row.name,count=row.count} end return out
end

local function capture(frame,w,h)
  local out=R.capture(w,h)
  assert(#frame.rows==h)
  for y,row in ipairs(frame.rows) do
    local fg,bg='',''
    if row.runs then
      for _,r in ipairs(row.runs) do fg=fg..string.rep(r[2],r[1]) bg=bg..string.rep(r[3],r[1]) end
    else
      fg=#row.fg==1 and string.rep(row.fg,w) or row.fg
      bg=#row.bg==1 and string.rep(row.bg,w) or row.bg
    end
    out.setCursorPos(1,y) out.blit(row.text..string.rep(' ',w-#row.text),fg,bg)
  end
  for i,b in ipairs(frame.buttons) do
    assert(b.x>=1 and b.y>=1 and b.w>0 and b.x+b.w-1<=w and b.y+b.h-1<=h,'button '..b.id)
    for j,o in ipairs(frame.buttons) do if i~=j then
      assert(b.x+b.w<=o.x or o.x+o.w<=b.x or b.y+b.h<=o.y or o.y+o.h<=b.y,'overlapping buttons')
    end end
  end
  return out,table.concat(out.picture().text,'\n')
end

-- Mining with turtle #2 (its job row carries an adapter-made inv) and display 9 on the mining role.
local function setup(w,h,cfg)
  local s={now=100000,sent={},saves=0,commands={}}
  s.mine={home={x=0,y=64,z=0,facing=0},homeSet=true,bottom=60,length=48,mode='thorough',ores={},
    dim='minecraft:overworld',running=true,progress={done=0,nextBranch=2},turtles={
      ['2']={pose={x=12,y=60,z=-5,facing=1},state='mining',branch=0,fuel=420,
        inv={{slot=1,name='minecraft:diamond',count=14}}}}}
  local store=dofile('so-store.lua')
  local env=setmetatable({},{__index=_G})
  env.os=setmetatable({epoch=function() return s.now end,getComputerID=function() return 1 end},{__index=os})
  env.SO={now=function() return s.now end,pair={key=function() return string.rep('01',32) end},mods={},
    store={copy=store.copy,read=function(path) return path=='so-server.cfg' and cfg or {} end,store=function(path)
      return {value=path=='so-data/mine/job' and s.mine or {roles={}},save=function() s.saves=s.saves+1 return true end}
    end}}
  env.SO.proto=assert(loadfile('so-proto.lua','t',env))()
  env.rednet={send=function(id) s.sent[id]=(s.sent[id] or 0)+1 end}
  env.SO.mods.state={get=function() return {['2']={role='worker',seen=97000},['3']={role='worker',seen=99000}} end}
  env.SO.mods.lease={onReport=function() end,status=function(id) return {open='lease-'..id} end}
  local d=assert(loadfile('so-mod-display.lua','t',env))()
  env.SO.mods.display=d
  local mine=assert(loadfile('so-mod-mine.lua','t',env))()
  env.SO.mods.mine=mine mine.tick(s.now)
  d.tick(s.now)
  d.handlers.hello({from=9,body={w=w,h=h}})
  assert(d.assign(9,'mining'))
  local screen=d.screen('mining')
  local input=screen.input
  screen.input=function(e) if e.text then s.commands[#s.commands+1]=e.text end return input(e) end
  for i=1,60 do local k,v=debug.getupvalue(d.tick,i) if k=='D' then s.D=v break end if not k then break end end
  s.frame=function() local frame d.handlers['view.get']({from=9},function(_,body) frame=body end) return frame end
  s.text=function() local _,text=capture(s.frame(),w,h) return text end
  s.ids=function() local out={} for _,b in ipairs(s.frame().buttons) do out[b.id]=b end return out end
  s.press=function(id)
    local b=assert(s.ids()[id],'missing drawn button '..id)
    d.handlers.input({from=9,body={id=id,x=b.x,y=b.y}})
  end
  s.hello=function(inv,journal,id)
    d.handlers.hello({from=id or 2,body={role='turtle',inv=inv,journal=journal==nil and {id='2-0',seq=4} or journal}})
  end
  s.model=function(id) return s.D.invModel(tostring(id or 2),s.now) end
  s.display,s.w,s.h=d,w,h
  return s
end
local ON={turtleInventory=true}

return function(test,equal)
  test('B10-U with turtleInventory off the detail page keeps the job row inventory and no target',function()
    local s=setup(26,20,{})
    s.hello(sample())
    equal(next(s.D.inv),nil,'no sample cached with the flag off')
    s.press('turtle:2')
    local text=s.text()
    assert(text:find('1/16 \194\183 14',1,true),text)
    assert(not s.ids()['turtle-inventory'] and not text:find('unknown',1,true))
  end)

  test('B10-U an adapter-made row.inv is never a sample: no hello reads unknown',function()
    local s=setup(26,20,ON)
    s.press('turtle:2')
    local text=s.text()
    assert(text:find('unknown',1,true) and not text:find('1/16',1,true),text)
    assert(s.ids()['turtle-inventory'],'the inventory leader is a target')
    s.press('turtle-inventory')
    text=s.text()
    assert(text:find('INVENTORY #2',1,true) and text:find('unknown',1,true),text)
    assert(not text:find('empty',1,true) and not text:find('01',1,true),'unknown invents no slots')
  end)

  test('B10-U missing inv is unknown and a valid empty array is known empty',function()
    local s=setup(26,20,ON)
    s.hello(nil)
    equal(s.model().known,false)
    s.hello({})
    local m=s.model()
    equal(m.known,true) equal(next(m.slots),nil) equal(m.at,s.now)
    s.press('turtle:2')
    assert(s.text():find('0/16 \194\183 0',1,true))
    s.press('turtle-inventory')
    local text=s.text()
    assert(text:find('0/16',1,true) and text:find('01 empty',1,true) and not text:find('unknown',1,true),text)
  end)

  test('B10-U malformed samples are rejected whole and keep the last valid sample and its time',function()
    local bad={
      {{slot=1,name='minecraft:stone',count=1},{slot=1,name='minecraft:dirt',count=2}},
      {{slot=17,name='minecraft:stone',count=1}},
      {{slot=0,name='minecraft:stone',count=1}},
      {{slot=1.5,name='minecraft:stone',count=1}},
      {{slot=1,name='minecraft:stone',count=0}},
      {{slot=1,name='minecraft:stone',count=65}},
      {{slot=1,name='minecraft:stone',count=1,nbt='x'}},
      {{slot=1,name='stone',count=1}},
      {{slot=1,name='Minecraft:Stone',count=1}},
      {{slot=1,name='minecraft:'..string.rep('a',119),count=1}},
      {{slot=1,name=7,count=1}},
      {[1]={slot=1,name='minecraft:stone',count=1},[3]={slot=3,name='minecraft:stone',count=1}},
      {{slot=1,name='minecraft:stone',count=1},'minecraft:dirt'},
      {x={slot=1,name='minecraft:stone',count=1}},
      'minecraft:stone',
    }
    local seventeen={} for i=1,17 do seventeen[i]={slot=(i-1)%16+1,name='minecraft:stone',count=1} end
    bad[#bad+1]=seventeen
    for i,inv in ipairs(bad) do
      local s=setup(26,20,ON)
      s.hello(inv)
      equal(s.model().known,false,'malformed sample '..i..' accepted')
    end
    local s=setup(26,20,ON)
    s.hello(sample())
    local at=s.model().at
    s.now=s.now+30000
    for _,inv in ipairs(bad) do s.hello(inv) end
    s.hello(nil)
    local m=s.model()
    equal(m.at,at,'an invalid hello refreshed the time')
    equal(m.slots[1].name,'minecraft:diamond')
    -- 128 bytes is the longest id.
    s.hello({{slot=3,name='minecraft:'..string.rep('a',118),count=64}})
    equal(s.model().slots[3].count,64)
  end)

  test('B10-U a journal change discards the cached sample, and stale after 120 s',function()
    local s=setup(26,20,ON)
    s.hello(sample())
    s.hello(nil,{id='2-1'})
    equal(s.model().known,false,'the old journal sample survived')
    s.hello(sample(),{id='2-1'})
    s.hello({{slot=1,name='minecraft:stone',count=99}},{id='2-2'})
    equal(s.model().known,false,'a malformed sample under a new journal kept the old one')
    s.hello(sample(),{})
    equal(s.model().known,false,'a hello without a journal id is no sample')
    s.hello(sample(),{id=string.rep('j',65)})
    equal(s.model().known,false)
    s.hello(sample(),{id='2-3'})
    s.now=s.now+120000
    equal(s.model().stale,false)
    s.now=s.now+1
    equal(s.model().stale,true)
    s.display.tick(s.now)
    s.press('turtle:2')
    local inventory=s.ids()['turtle-inventory']
    local _,text=capture(s.frame(),26,20)
    assert(text:find('6/16 \194\183 126',1,true),text)
    local out=capture(s.frame(),26,20)
    equal(out.cells[inventory.y][24][2],'1','a stale leader is amber')
    s.press('turtle-inventory')
    assert(s.text():find('stale 2m',1,true),s.text())
  end)

  test('B10-U forget and restart discard the sample; a new hello repopulates it',function()
    local s=setup(26,20,ON)
    s.hello(sample())
    s.hello(sample(),nil,3)
    s.display.forget(2)
    equal(s.model().known,false)
    equal(s.model(3).known,true,'forget dropped another worker')
    s.hello(sample())
    equal(s.model().known,true)
    local fresh=setup(26,20,ON)
    equal(fresh.model().known,false,'a restart starts without samples')
  end)

  for _,size in ipairs({{15,10},{26,20},{29,12},{57,24}}) do
    local w,h=size[1],size[2]
    test('B10-U every slot is reachable at '..w..'x'..h..' and BACK returns without commands',function()
      local s=setup(w,h,ON)
      s.hello(sample())
      local _,source=capture(s.frame(),w,h)
      assert(source:find('MINING',1,true),source)
      s.press('turtle:2')
      local saves,sent=s.saves,s.sent[2]
      s.press('turtle-inventory')
      local seen={}
      for _=1,16 do
        local _,text=capture(s.frame(),w,h)
        for slot in text:gmatch('\n (%d%d) ') do seen[tonumber(slot)]=true end
        if not s.ids()['inventory-next'] then break end
        s.press('inventory-next')
        local _,after=capture(s.frame(),w,h)
        if after==text then break end
      end
      for slot=1,16 do assert(seen[slot],'slot '..slot..' unreachable at '..w..'x'..h) end
      -- Paging back from the last page reaches page 1.
      while s.ids()['inventory-prev'] do
        local _,before=capture(s.frame(),w,h)
        s.press('inventory-prev')
        local _,after=capture(s.frame(),w,h)
        if after==before then break end
      end
      assert(s.text():find('\n 01 ',1,true),'prev did not return to page 1')
      s.press('inventory-back')
      local text=s.text()
      assert(text:find('TURTLE #2',1,true) and s.ids()['turtle-inventory'],text)
      s.press('turtle-back')
      local _,back=capture(s.frame(),w,h)
      equal(back,source,'BACK did not restore the source page')
      equal(#s.commands,0) equal(s.saves,saves,'inventory paging saved') equal(s.sent[2],sent,'a worker got a message')
    end)
  end

  test('B10-U paging clamps after a resize and BACK resets to the detail page',function()
    local s=setup(15,10,ON)
    s.hello(sample())
    s.press('turtle:2') s.press('turtle-inventory')
    s.press('inventory-next') s.press('inventory-next') s.press('inventory-next')
    local _,text=capture(s.frame(),15,10)
    assert(text:find('16 torch',1,true),text)
    s.display.handlers.hello({from=9,body={w=26,h=20}})
    s.w,s.h=26,20
    _,text=capture(s.frame(),26,20)
    assert(text:find('2/2',1,true) and text:find('16 torch',1,true),text)
    s.press('inventory-prev')
    _,text=capture(s.frame(),26,20)
    assert(text:find('1/2',1,true) and text:find('01 diamond',1,true),text)
    s.press('inventory-back') s.press('turtle-inventory')
    _,text=capture(s.frame(),26,20)
    assert(text:find('1/2',1,true),'the page did not start at 1')
  end)

  test('B10-U at 15x10 a retry flag and progress leave the inventory leader reachable',function()
    local row={role='mining',state='mining',pose={x=12,y=60,z=-5,facing=1},fuel=42,lease='lease-2',
      step='forward',ore=14,seen=97000,branch=0,done=12,total=48,
      error='path blocked by bedrock below the branch',retry=130000}
    local inv={id='2',known=true,stale=false,at=100000,slots={}}
    local frame=U.turtle.render(15,10,{id='2'},row,100000,inv)
    local hit
    for _,b in ipairs(frame.buttons) do if b.id=='turtle-inventory' then hit=b end end
    assert(hit,'no inventory leader at 15x10 under a retry flag')
    local _,text=capture(frame,15,10)
    assert(text:find('retry 30s',1,true),text)
    -- Without the model the flag keeps its three rows.
    _,text=capture(U.turtle.render(15,10,{id='2'},row,100000),15,10)
    assert(not text:find('inventory',1,true),text)
  end)

  test('B10-U a hello with a missing or invalid journal id keeps the cached sample',function()
    local s=setup(26,20,ON)
    s.hello(sample())
    local at=s.model().at
    s.now=s.now+5000
    for _,journal in ipairs({false,{},{id=7},{id=''},{id=string.rep('j',65)}}) do
      s.hello({{slot=4,name='minecraft:dirt',count=1}},journal)
      local m=s.model()
      equal(m.known,true,'an invalid journal dropped the sample')
      equal(m.at,at) equal(m.slots[1].name,'minecraft:diamond') equal(m.slots[4],nil)
    end
    s.hello(nil,{id='2-9'})
    equal(s.model().known,false,'a valid different journal keeps the old sample')
  end)

  test('B10-U inventory BACK only fires inside its drawn rectangle',function()
    local s=setup(26,20,ON)
    s.hello(sample())
    s.press('turtle:2') s.press('turtle-inventory')
    local back=s.ids()['inventory-back']
    assert(back.x>1)
    s.display.handlers.input({from=9,body={id='inventory-back',x=1,y=20}})
    assert(s.text():find('INVENTORY #2',1,true),'a tap at 1,h closed the inventory page')
    s.press('inventory-back')
    assert(s.text():find('TURTLE #2',1,true))
  end)

  test('B10-U the inventory screens match the schematic fixtures',function()
    local T=U.turtle
    local slots={} for _,row in ipairs(SCENE.list) do slots[row.slot]={name=row.name,count=row.count} end
    local function model(kind)
      if kind=='unknown' then return {id='2',known=false,stale=false,slots={}} end
      return {id='2',known=true,stale=kind=='stale',at=SCENE.at,slots=kind=='empty' and {} or slots}
    end
    local cases={
      {'inventory-P',26,20,'known',1},{'inventory2-P',26,20,'known',2},{'inventory-XS',15,10,'known',1},
      {'inventory3-XS',15,10,'known',3},{'inventoryempty-S',29,12,'empty',1},
      {'inventoryunknown-P',26,20,'unknown',1},{'inventorystale-M',57,24,'stale',1}}
    for _,c in ipairs(cases) do
      local now=c[4]=='stale' and SCENE.later or SCENE.at
      local frame=T.inventory(c[2],c[3],{id='2',page='inventory',inventoryPage=c[5]},model(c[4]),now)
      local out=capture(frame,c[2],c[3])
      local diff=R.diff(FIXTURE[c[1]],out)
      assert(#diff==0,c[1]..'\n'..table.concat(diff,'\n'))
    end
    local row={role='mining',state='mining',pose={x=12,y=60,z=-5,facing=1},fuel=42,
      inv={{slot=1,count=14}},lease='lease-2',step='forward',ore=14,seen=97000,branch=0,done=12,total=48}
    local out=capture(T.render(29,12,{id='2'},row,100000,model('unknown')),29,12)
    local diff=R.diff(FIXTURE['turtleinv-S'],out)
    assert(#diff==0,table.concat(diff,'\n'))
    row.error,row.retry='path blocked by bedrock below the branch',130000
    out=capture(T.render(15,10,{id='2'},row,100000,model('known')),15,10)
    diff=R.diff(FIXTURE['turtleinvflag-XS'],out)
    assert(#diff==0,table.concat(diff,'\n'))
  end)

  test('B10-U schematic generator reproduces the inventory fixtures',function()
    local started,pipe=pcall(io.popen,'pwd')
    local root=started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1,1)~='/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('B10-U schematic generator','needs host processes, a POSIX shell and python3')
    end
    local dir=os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '"..dir.."'"))
    local names={} for name in pairs(FIXTURE) do names[#names+1]=name end
    table.sort(names)
    assert(os.execute("python3 -I '"..root.."/docs/ui/schematic/screens.py' --fixtures '"..dir.."' "..table.concat(names,' ').." > /dev/null"))
    for _,name in ipairs(names) do equal(read(dir..'/'..name..'.txt'),read(FIXTURE[name]),name) end
    assert(os.execute("rm -r '"..dir.."'"))
  end)
end
