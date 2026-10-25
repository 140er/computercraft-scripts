local H = dofile("tests/so/harness.lua")
local midnight = {
  1792360800000, 1792447200000, 1792533600000, 1792620000000, 1792706400000,
  1792792800000, 1792879200000, 1792969200000, 1793055600000,
}
local function fixture(at, files, old)
  local n = H.new()
  local m = n.machine({id=1,directories=true,capacity=16000000})
  m.install({"so-store.lua","so-ui.lua","so-mod-daily.lua"})
  for path, text in pairs(files or {}) do m.files[path] = text end
  local e, s = m.env, {now=at,wall=at,events={}}
  e.os.epoch = function() return s.wall end
  e.SO = {mods={},now=function() return s.now end}
  e.SO.store = e.dofile("so-store.lua")
  if old then assert(e.SO.store.store("so-data/daily",function() return true end).save(old)) end
  e.SO.mods.state = {history={page=function(q)
    local entries = {}
    for _, ev in ipairs(s.events) do
      if ev.seq > q.from and #entries < q.count then entries[#entries+1] = ev end
    end
    return {entries=entries}
  end}}
  s.daily = e.dofile("so-mod-daily.lua")
  s.m, s.e = m, e
  s.tick = function(at, wall)
    s.now = at or s.now
    s.wall = wall or at or s.wall
    s.daily.tick(s.now)
  end
  s.add = function(kind, count, at, name)
    local ev = {seq=#s.events+1,gameAt=at or s.now,at=at or s.wall,kind=kind,
      data={name=name or "minecraft:diamond",count=count}}
    s.events[#s.events+1] = ev
    return ev
  end
  s.saved = function()
    return assert(e.textutils.unserialize(m.files["so-data/daily"])).value
  end
  return s
end
local function legacy(date)
  return {date=date,cursor=4,ore=7,oreByName={diamond=7},logs=9,recent={}}
end
local function oversizedLegacy()
  local old = legacy("2026-10-25")
  old.ore, old.logs, old.cursor, old.oreByName = 700, 91, 73, {}
  for i=1,700 do old.oreByName[string.rep("x",1180)..tostring(i)] = 1 end
  return old
end
local function boundedDisk(s)
  local total = 0
  for _, suffix in ipairs({"", ".bak", ".tmp"}) do
    local size = #(s.m.files["so-data/daily"..suffix] or "")
    assert(size <= 262144, "oversized daily generation survived migration")
    total = total + size
  end
  assert(total <= 786432, "daily generations exceed the combined disk budget")
end
return function(test, equal)
  test("daily an old daily file still loads with unknown earlier days", function()
    local s = fixture(midnight[7]+1000,nil,legacy("2026-10-25"))
    equal(s.daily.today(),{date="2026-10-25",ore=7,oreByName={diamond=7},logs=9,oreRecent=0})
    s.tick(s.now+60000)
    equal(s.saved().previous,{})
    local days = s.daily.days()
    equal(#days,7)
    equal(days[1],{date="2026-10-19",ore=false,logs=false,partial=true})
    equal(days[7],{date="2026-10-25",ore=7,logs=9,partial=true})
    days[7].ore = 999
    local today = s.daily.today() today.oreByName.diamond = 999
    equal(s.daily.days()[7].ore,7)
    equal(s.daily.today().oreByName.diamond,7)
  end)

  test("daily normalizes a legacy singleton previous row", function()
    local old = legacy("2026-10-25")
    old.previous = {date="2026-10-24",ore=11,logs=13}
    local s = fixture(midnight[7],nil,old)
    equal(s.daily.days()[6],{date="2026-10-24",ore=11,logs=13,partial=true})
    s.tick(s.now+60000)
    equal(s.saved().previous,{{date="2026-10-24",ore=11,logs=13,partial=true}})
  end)

  test("daily totals cover exactly the last 7 days and day 8 drops at the day boundary", function()
    local s = fixture(midnight[1])
    for day=1,7 do
      s.tick(midnight[day])
      s.add("mine.ore",day)
      s.add("lumber.logs",day*2)
      s.tick()
    end
    s.tick(s.now,midnight[8]-1)
    local before = s.daily.days()
    equal(#before,7) equal(before[1].date,"2026-10-19") equal(before[1].ore,1)
    equal(before[7].date,"2026-10-25") equal(before[7].ore,7)
    s.tick(s.now,midnight[8])
    local after = s.daily.days()
    equal(#after,7) equal(after[1].date,"2026-10-20") equal(after[1].ore,2)
    equal(after[7],{date="2026-10-26",ore=0,logs=0,partial=false})
    local saved = s.saved()
    equal(#saved.previous,6) equal(saved.previous[1].date,"2026-10-20")
    equal(saved.previous[6].logs,14) equal(saved.cursor,14)
    for _, row in ipairs(saved.previous) do equal(row.oreByName,nil) equal(row.recent,nil) end
  end)

  test("daily a server restart across day eight archives once and drops the oldest date", function()
    local s = fixture(midnight[1])
    for day=1,7 do
      s.tick(midnight[day]) s.add("mine.ore",day) s.tick(midnight[day]+60000)
    end
    local r = fixture(midnight[8],s.m.files)
    r.now = s.now
    r.events = s.events
    r.tick()
    equal(r.daily.days()[1].date,"2026-10-20") equal(r.daily.days()[1].ore,2)
    equal(r.daily.days()[6].ore,7) equal(r.daily.today().ore,0)
    equal(r.saved().cursor,7) equal(#r.saved().previous,6)
    local again = fixture(midnight[8],r.m.files)
    again.now = r.now
    again.events = r.events again.tick()
    equal(again.daily.days(),r.daily.days())
  end)

  test("daily UTC controls dates while game time controls recent ore", function()
    local s = fixture(midnight[1])
    s.now = midnight[8]
    equal(s.daily.days()[7].date,"2026-10-19")
    s.add("mine.ore",3) s.tick()
    equal(s.daily.today().date,"2026-10-19") equal(s.daily.today().oreRecent,3)
    s.tick(s.now+599999,s.wall)
    equal(s.daily.today().date,"2026-10-19") equal(s.daily.today().oreRecent,3)
    s.tick(s.now+1,s.wall) equal(s.daily.today().oreRecent,0)
    s.tick(s.now,midnight[2]-1) equal(s.daily.today().date,"2026-10-19")
    s.tick(s.now,midnight[2]) equal(s.daily.today().date,"2026-10-20")
    equal(s.daily.days()[6].ore,3)
  end)

  test("daily events use their UTC date even when gameAt is on another date", function()
    local s = fixture(midnight[7]) s.now = midnight[1]
    s.add("mine.ore",5)
    local logs=s.add("lumber.logs",8,midnight[6]) logs.gameAt=midnight[7]
    s.tick()
    equal(s.daily.today().date,"2026-10-25") equal(s.daily.today().ore,5)
    equal(s.daily.today().oreRecent,5) equal(s.daily.today().logs,0)
    equal(s.daily.days()[6].logs,8)
    local r=fixture(s.wall,s.m.files) r.now=s.now r.events=s.events r.tick()
    equal(r.daily.days(),s.daily.days()) equal(r.daily.today(),s.daily.today())
  end)

  test("daily valid UTC events keep totals when their game timestamp is malformed", function()
    local s=fixture(midnight[7])
    local ev=s.add("mine.ore",7) ev.gameAt="invalid"
    s.tick()
    equal(s.daily.today().ore,7) equal(s.daily.today().oreRecent,0)
  end)

  test("daily calendar pruning crosses both daylight saving boundaries", function()
    for _, dates in ipairs({
      {1774738800000,1774821600000,"2026-03-29","2026-03-30",23},
      {midnight[7],midnight[8],"2026-10-25","2026-10-26",25},
    }) do
      equal((dates[2]-dates[1])/3600000,dates[5])
      local s = fixture(dates[1])
      s.add("mine.ore",17) s.tick()
      s.tick(s.now,dates[2]-1) equal(s.daily.today().date,dates[3])
      s.tick(s.now,dates[2]) equal(s.daily.today().date,dates[4])
      equal(s.daily.days()[6].date,dates[3]) equal(s.daily.days()[6].ore,17)
    end
  end)

  test("daily missing days stay unknown and delayed events update their retained date", function()
    local s = fixture(midnight[1])
    s.add("mine.ore",2) s.tick()
    s.tick(midnight[7])
    equal(s.daily.days()[2],{date="2026-10-20",ore=false,logs=false,partial=true})
    s.add("mine.ore",5,midnight[1])
    s.add("lumber.logs",6,midnight[4])
    s.add("mine.ore",20,midnight[1]-1)
    s.tick(s.now+60000)
    equal(s.daily.days()[1].ore,7)
    equal(s.daily.days()[4],{date="2026-10-22",ore=0,logs=6,partial=true})
    equal(s.daily.today().ore,0) equal(s.saved().cursor,4)
    local r = fixture(s.now,s.m.files) r.events = s.events r.tick()
    equal(r.daily.days(),s.daily.days())
  end)

  test("daily backward clocks keep the retained date without duplicate archives", function()
    local s = fixture(midnight[1])
    s.add("mine.ore",2) s.tick() s.tick(midnight[2])
    s.tick(s.now+1000,midnight[1]+1000)
    s.add("mine.ore",3) s.tick()
    equal(s.daily.today().date,"2026-10-20") equal(s.daily.days()[6].ore,5)
    s.tick(midnight[2]+60000)
    equal(#s.saved().previous,1) equal(s.daily.days()[6].ore,5)
  end)

  test("daily history gaps mark observed days partial without extrapolating", function()
    local s = fixture(midnight[1])
    s.tick() s.tick(midnight[2]) equal(s.daily.days()[7].partial,false)
    local ev = s.add("mine.ore",8) ev.seq = 12
    s.tick(s.now+60000)
    equal(s.daily.days()[7].partial,true) equal(s.daily.days()[7].ore,8)
    equal(s.daily.days()[6].partial,true) equal(s.daily.days()[1].ore,false)
    equal(s.saved().cursor,12)
  end)

  test("daily pages and cursor replay count each ore and lumber receipt once", function()
    local s = fixture(midnight[1])
    for i=1,75 do
      local ev = s.add(i%2==0 and "mine.ore" or "lumber.logs",1)
      if ev.kind=="lumber.logs" then ev.data.receipts={worker=i} end
    end
    s.tick() equal(s.saved().cursor,50)
    local r = fixture(s.now,s.m.files) r.events=s.events r.tick(s.now+60000)
    equal(r.saved().cursor,75) equal(r.daily.today().ore,37) equal(r.daily.today().logs,38)
    r.tick(s.now+120000)
    equal(r.daily.today().ore,37) equal(r.daily.today().logs,38)
  end)

  test("daily failed saves retain aggregate counts and cursor together for retry and restart", function()
    local s = fixture(midnight[1])
    s.add("mine.ore",2) s.tick()
    local open = s.e.fs.open
    s.e.fs.open = function(path, mode)
      if path=="so-data/daily.tmp" and mode=="w" then error("disk unavailable") end
      return open(path,mode)
    end
    s.add("mine.ore",3) s.add("lumber.logs",4) s.tick(s.now+60000)
    equal(s.daily.today().ore,5) equal(s.saved().ore,2) equal(s.saved().cursor,1)
    local r = fixture(s.now,s.m.files) r.events=s.events r.tick(s.now+60000)
    equal(r.daily.today().ore,5) equal(r.daily.today().logs,4) equal(r.saved().cursor,3)
    s.e.fs.open = open s.tick(s.now+1)
    equal(s.saved().ore,5) equal(s.saved().logs,4) equal(s.saved().cursor,3)
  end)

  test("daily caps exact ore IDs and counts excess and long names under other", function()
    local s = fixture(midnight[1])
    for i=1,130 do s.add("mine.ore",1,nil,string.format("ore:%03d",i)) end
    s.add("mine.ore",3,nil,string.rep("x",129))
    for _=1,3 do s.tick() end
    s.tick(s.now+60000)
    local names = s.daily.today().oreByName
    local exact, total = 0,0
    for name, count in pairs(names) do
      assert(#name<=128) total=total+count if name~="other" then exact=exact+1 end
    end
    equal(exact,128) equal(total,133) equal(names.other,5) equal(s.saved().ore,133)
  end)

  test("daily compacts optional recent buckets before exceeding the generation budget", function()
    local s = fixture(midnight[1]) s.tick()
    s.now=s.now+20000
    for i=1,16000 do s.add("mine.ore",1,midnight[1]+i) end
    for _=1,320 do s.tick() end
    s.tick(midnight[1]+60000)
    equal(s.saved().ore,16000) equal(s.saved().cursor,16000)
    equal(s.saved().recent,{})
    s.tick(s.now+60000)
    local bytes=0
    for _, suffix in ipairs({"",".bak",".tmp"}) do
      local size=#(s.m.files["so-data/daily"..suffix] or "")
      assert(size<=262144,"daily generation exceeded its budget") bytes=bytes+size
    end
    assert(bytes<=786432,"daily generations exceeded their combined budget")
    local r=fixture(s.now,s.m.files) r.events=s.events r.tick()
    equal(r.daily.today().ore,16000)
  end)

  test("daily a garbage file still gives zero totals", function()
    local s = fixture(midnight[1],{["so-data/daily"]="garbage",["so-data/daily.bak"]="broken"})
    equal(s.daily.today().ore,0) equal(s.daily.today().logs,0)
    equal(s.daily.today().oreRecent,0) equal(#s.m.log,1)
    s.tick() equal(s.saved().ore,0) equal(s.saved().cursor,0)
  end)

  test("daily missing retained history marks totals partial and saves the skipped cursor", function()
    local old=legacy("2026-10-25") old.partial=false
    local s=fixture(midnight[7],nil,old)
    s.e.SO.mods.state.diagnostics=function() return {available=true,seq=19} end
    s.tick()
    equal(s.daily.days()[7].partial,true) equal(s.saved().cursor,19)
    equal(s.daily.today().ore,7) equal(s.daily.today().logs,9)
  end)

  test("daily legacy event timestamps load and unrelated or invalid counts leave missing days unknown", function()
    local s=fixture(midnight[7])
    local ev=s.add("mine.ore",3) ev.gameAt=nil ev.at=s.now
    s.add("unrelated",99,midnight[3])
    s.add("mine.ore",1.5,midnight[3])
    s.add("lumber.logs",-2,midnight[3])
    local broken=s.add("mine.ore",8) broken.data="broken"
    s.tick()
    equal(s.daily.today().ore,3) equal(s.daily.today().oreRecent,3)
    equal(s.daily.days()[3],{date="2026-10-21",ore=false,logs=false,partial=true})
    equal(s.saved().cursor,5)
  end)

  test("daily normalizes an oversized old ore breakdown without losing aggregates", function()
    local old=legacy("2026-10-25") old.ore=132 old.oreByName={}
    for i=1,130 do old.oreByName[string.format("ore:%03d",i)]=1 end
    old.oreByName[string.rep("x",129)]=2
    local s=fixture(midnight[7],nil,old) s.tick(s.now+60000)
    local exact,total=0,0
    for name,count in pairs(s.saved().oreByName) do
      assert(#name<=128) total=total+count if name~="other" then exact=exact+1 end
    end
    equal(exact,128) equal(total,132) equal(s.saved().ore,132)
  end)

  test("daily migrating an oversized legacy generation bounds all disk generations", function()
    for _, suffix in ipairs({"", ".bak", ".tmp"}) do
      local seed = fixture(midnight[7],nil,oversizedLegacy())
      local text = seed.m.files["so-data/daily"]
      assert(#text > 786432, "legacy fixture does not exceed both disk limits")
      local s = fixture(midnight[7],{["so-data/daily"..suffix]=text})
      s.tick(s.now+60000)
      equal(s.saved().ore,700) equal(s.saved().logs,91) equal(s.saved().cursor,73)
      equal(s.saved().oreByName,{other=700})
      boundedDisk(s)
      local r = fixture(s.now,s.m.files)
      equal(r.daily.today().ore,700) equal(r.daily.today().logs,91)
      equal(r.saved().cursor,73)
    end
  end)

  test("daily a failed migration save keeps oversized legacy data recoverable", function()
    for _, suffix in ipairs({"", ".bak", ".tmp"}) do
      local seed = fixture(midnight[7],nil,oversizedLegacy())
      local text = seed.m.files["so-data/daily"]
      local s = fixture(midnight[7],{["so-data/daily"..suffix]=text})
      local open = s.e.fs.open
      s.e.fs.open = function(path,mode)
        if path=="so-data/daily.tmp" and mode=="w" then error("disk unavailable") end
        return open(path,mode)
      end
      s.tick(s.now+60000)
      local kept = false
      for _, ending in ipairs({"", ".bak", ".tmp"}) do
        if s.m.files["so-data/daily"..ending] == text then kept = true end
      end
      assert(kept, "failed save deleted the oversized legacy generation")
      local r = fixture(s.now,s.m.files)
      equal(r.daily.today().ore,700) equal(r.daily.today().logs,91)
      s.e.fs.open = open
      s.tick(s.now+1)
      boundedDisk(s)
      equal(s.saved().cursor,73)
    end
  end)

  test("daily keeps oversized backups until normalized totals and cursor read back", function()
    for _, field in ipairs({"ore", "cursor", "generation", "read error"}) do
      local s = fixture(midnight[7],nil,oversizedLegacy())
      local text = s.m.files["so-data/daily"]
      local read = s.e.SO.store.read
      s.e.SO.store.read = function(path)
        local value, bytes = read(path)
        if path=="so-data/daily" and value and #bytes<=262144 then
          if field=="generation" then value.generation=0
          elseif field=="read error" then error("read unavailable")
          else value.value[field] = value.value[field]+1 end
        end
        return value, bytes
      end
      s.tick(s.now+60000)
      equal(s.m.files["so-data/daily.bak"],text)
      local r = fixture(s.now,s.m.files)
      equal(r.daily.today().ore,700) equal(r.daily.today().logs,91)
      equal(r.saved().cursor,73)
      s.e.SO.store.read = read
      s.tick(s.now+1)
      boundedDisk(s)
    end
  end)

end
