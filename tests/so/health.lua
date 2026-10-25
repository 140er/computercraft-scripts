local R = dofile("tests/ui/render.lua")

local ERROR = "tick\nfailed: so-mod-mine.lua:120 attempt to index a nil value while saving the mining job "..
  "for turtle 7; checkpoint refused because the disk is full. Free space in so-data, "..
  "then retry the job. The worker keeps its last saved pose and reservations while the "..
  "server waits for the checkpoint. Final detail: no blocks were changed."

local FIXTURES = {
  "tests/ui/fixtures/health/needs-error-26x20.txt", "tests/ui/fixtures/health/needs-error-29x12.txt",
  "tests/ui/fixtures/health/needs-enroll-26x20.txt", "tests/ui/fixtures/health/needs-enroll-29x12.txt",
  "tests/ui/fixtures/health/errors-list-26x20.txt", "tests/ui/fixtures/health/errors-list-29x12.txt",
  "tests/ui/fixtures/health/error-detail-26x20.txt", "tests/ui/fixtures/health/error-detail-29x12.txt",
  "tests/ui/fixtures/health/error-detail-next-26x20.txt", "tests/ui/fixtures/health/error-detail-next-29x12.txt",
}

local function health()
  local t = {now=3600000,clock=0,entries={},screens={},enroll=nil}
  local env = setmetatable({}, {__index=_G})
  env.os = {clock=function() return t.clock end}
  env.peripheral = {find=function() return {} end}
  env.SO = {mods={},store={read=function() end},
    enroll={view=function(owner) assert(owner==nil);return t.enroll end},
    errors={entries=function() return t.entries end,status=function() return {count=#t.entries,bytes=340} end}}
  env.SO.mods.display = {screen=function(role,render,input) t.screens[role]={render=render,input=input} end}
  t.mod = assert(loadfile("so-mod-health.lua","t",env))()
  t.tick = function(now) t.now=now or t.now;t.clock=t.clock+5;t.mod.tick(t.now) end
  t.render = function(role,w,h,session) return t.screens[role].render(w,h,session) end
  t.input = function(role,session,id,open) t.screens[role].input({session=session,id=id,open=open}) end
  t.tick()
  return t
end

local function buttons(frame)
  local out = {}
  for _, b in ipairs(frame.buttons) do out[b.id]=b end
  return out
end

local function capture(frame,w,h)
  local out = R.capture(w,h)
  assert(#frame.rows==h)
  for y,row in ipairs(frame.rows) do
    local fg,bg = {},{}
    for _,run in ipairs(row.runs) do
      fg[#fg+1],bg[#bg+1]=string.rep(run[2],run[1]),string.rep(run[3],run[1])
    end
    fg,bg=table.concat(fg),table.concat(bg)
    assert(#row.text<=w and #fg==w and #bg==w,"row width")
    out.setCursorPos(1,y)
    out.blit(row.text..string.rep(" ",w-#row.text),fg,bg)
  end
  for i,b in ipairs(frame.buttons) do
    assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+b.h-1<=h,"button bounds "..b.id)
    for j,o in ipairs(frame.buttons) do
      assert(i==j or b.x+b.w<=o.x or o.x+o.w<=b.x or b.y+b.h<=o.y or o.y+o.h<=b.y,
        "overlapping buttons "..b.id.." "..o.id)
    end
  end
  return out
end

local function match(name,frame,w,h)
  local path = "tests/ui/fixtures/health/"..name.."-"..w.."x"..h..".txt"
  local declared = false
  for _,v in ipairs(FIXTURES) do if v==path then declared=true end end
  assert(declared,path)
  local diff = R.diff(R.load(path),capture(frame,w,h))
  assert(#diff==0,path.."\n"..table.concat(diff,"\n"))
end

return function(test,equal)
  test("health keeps UTF-8 codepoints whole at list and detail cut points",function()
    local function valid(text)
      local i = 1
      while i <= #text do
        local byte = text:byte(i)
        local size = byte < 128 and 1 or byte >= 194 and byte <= 223 and 2
          or byte >= 224 and byte <= 239 and 3 or byte >= 240 and byte <= 244 and 4
        assert(size,"invalid UTF-8 lead byte at "..i)
        for j=1,size-1 do
          local nextByte = text:byte(i+j)
          assert(nextByte and nextByte >= 128 and nextByte <= 191,"split UTF-8 codepoint at "..i)
        end
        i = i+size
      end
    end
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h = size[1],size[2]
      for _,width in ipairs({w-2,w-7}) do
        for _,char in ipairs({"\195\169","\226\130\172","\240\159\152\128"}) do
          for offset=1,#char-1 do
            local t,s = health(),{}
            local text = string.rep("x",width-offset)..char..string.rep("z",w+4).." final detail"
            t.entries = {{at=t.now,text=text}}
            local frame = t.render("errors",w,h,s)
            capture(frame,w,h)
            for _,row in ipairs(frame.rows) do valid(row.text) end
            t.input("errors",s,"error:1")
            local got = {}
            for page=1,64 do
              frame = t.render("errors",w,h,s)
              capture(frame,w,h)
              local top
              for y,row in ipairs(frame.rows) do
                valid(row.text)
                if row.text:find("ago",1,true) then top=y+1+(h>=16 and 1 or 0) end
              end
              assert(top)
              for y=top,h-1-(h>=16 and 1 or 0) do got[#got+1]=frame.rows[y].text end
              if not s.visibility.errors.errorNext then break end
              t.input("errors",s,"next")
              assert(page<64,"UTF-8 detail paging did not finish")
            end
            equal(table.concat(got):gsub("%s",""),text:gsub("%s",""))
          end
        end
      end
    end
  end)

  test("health error list stops at the first line break and details keep every line",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h = size[1],size[2]
      for _,newline in ipairs({"\n","\r\n","\r"}) do
        for _,first in ipairs({"FIRST",""}) do
          local t,s = health(),{}
          t.entries = {{at=t.now,text=first..newline.."SECOND line"}}
          local frame = t.render("errors",w,h,s)
          local preview = {}
          for _,row in ipairs(frame.rows) do preview[#preview+1]=row.text end
          assert(not table.concat(preview):find("SECOND",1,true),"list includes a later line")
          t.input("errors",s,"error:1")
          frame = t.render("errors",w,h,s)
          capture(frame,w,h)
          local detail = {}
          for _,row in ipairs(frame.rows) do detail[#detail+1]=row.text end
          assert(table.concat(detail):find("SECOND line",1,true),"detail lost a later line")
        end
      end
    end
  end)

  test("health gathers pending enroll rows without an owner token",function()
    local t,s = health(),{}
    t.enroll={owner=6,rows={{id=17,kind="worker",n="nonce"}}}
    t.tick(t.now+5000)
    local frame=t.render("attention",26,20,s)
    equal(t.mod.count(),1)
    assert(buttons(frame)["item:pair/17"])
    local opened
    t.input("attention",s,"item:pair/17",function(...) opened={...} end)
    equal(opened,{"panel",{"pair"}})
    t.enroll=nil
    t.tick(t.now+5000)
    equal(t.mod.count(),0)
    local env=setmetatable({SO={mods={},store={}}},{__index=_G})
    local mod=assert(loadfile("so-mod-health.lua","t",env))()
    mod.tick(0)
    equal(mod.count(),0)
  end)

  test("health shows one NEEDS row for fresh errors and expires it after ten minutes",function()
    local t,s=health(),{}
    t.entries={{at=t.now-700000,text="old"},{at=t.now,text="fresh"}}
    t.tick(t.now+5000)
    equal(t.mod.count(),1)
    local frame=t.render("attention",26,20,s)
    assert(buttons(frame)["item:errors"])
    local opened
    t.input("attention",s,"item:errors",function(role) opened=role end)
    equal(opened,"errors")
    t.tick(4199999)
    equal(t.mod.count(),1)
    t.tick(4205000)
    equal(t.mod.count(),0)
    equal(#t.entries,2)
    local facts={now=600000,disk={},errorCount=1,errorAt=0}
    equal(#t.mod.attention(facts),0)
    facts.now=599999
    equal(#t.mod.attention(facts),1)
    facts.errorCount=0
    equal(#t.mod.attention(facts),0)
  end)

  test("health fresh errors and enroll rows match generated fixtures at both sizes",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h=size[1],size[2]
      local t,s=health(),{}
      t.entries={{at=3590000,text=ERROR}}
      t.tick()
      match("needs-error",t.render("attention",w,h,s),w,h)
      match("errors-list",t.render("errors",w,h,s),w,h)
      local row=buttons(t.render("errors",w,h,s))["error:1"]
      assert(row and row.x==1 and row.w==w)
      t.input("errors",s,"error:1")
      match("error-detail",t.render("errors",w,h,s),w,h)
      t.input("errors",s,"next")
      match("error-detail-next",t.render("errors",w,h,s),w,h)
      t.input("errors",s,"prev")
      match("error-detail",t.render("errors",w,h,s),w,h)
      t.input("errors",s,"error-back")
      match("errors-list",t.render("errors",w,h,s),w,h)
      t.entries={}
      t.enroll={rows={{id=17}}}
      t.tick(3610000)
      match("needs-enroll",t.render("attention",w,h,s),w,h)
    end
  end)

  test("health error details keep all 2048 bytes reachable across pages and resize",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local t,s=health(),{}
      local text=("start\n"..string.rep("long/path/without/spaces/",65)..string.rep(" word",130)):sub(1,2038).." END-MARK!"
      equal(#text,2048)
      t.entries={{at=t.now,text=text}}
      t.render("errors",size[1],size[2],s)
      t.input("errors",s,"error:1")
      local got={}
      for page=1,128 do
        local frame=t.render("errors",size[1],size[2],s)
        capture(frame,size[1],size[2])
        local top
        for y,row in ipairs(frame.rows) do if row.text:find("ago",1,true) then top=y+1+(size[2]>=16 and 1 or 0) end end
        assert(top)
        for y=top,size[2]-1-(size[2]>=16 and 1 or 0) do got[#got+1]=frame.rows[y].text end
        if not s.visibility.errors.errorNext then break end
        t.input("errors",s,"next")
        assert(page<128,"detail paging did not finish")
      end
      equal(table.concat(got):gsub("%s",""),text:gsub("%s",""))
      local other={}
      equal(buttons(t.render("errors",26,20,other))["error-back"],nil)
      t.entries={{at=t.now,text="replacement"}}
      t.render("errors",57,24,s)
      equal(s.visibility.errors.error.text,text)
      t.input("errors",s,"errors",function(role) equal(role,"errors") end)
      equal(s.visibility.errors.error,nil)
    end
  end)

  test("health returns from an error detail to the same list page",function()
    local t,s=health(),{}
    for i=1,30 do t.entries[i]={at=t.now,text="error "..i} end
    t.render("errors",29,12,s)
    t.input("errors",s,"next")
    local frame=t.render("errors",29,12,s)
    local id
    for key in pairs(buttons(frame)) do if key:match("^error:") then id=key;break end end
    assert(id)
    t.input("errors",s,id)
    assert(buttons(t.render("errors",29,12,s))["error-back"])
    t.input("errors",s,"error-back")
    equal(s.visibility.errors.page,2)
    assert(buttons(t.render("errors",29,12,s))[id])
  end)
end
