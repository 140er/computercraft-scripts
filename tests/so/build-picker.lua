-- F5-G2: the builder's material picker over j.inv and the budget rows of build.budget().
local fixture=dofile("tests/so/build-fixture.lua")
return function(test,equal)
  local function ready(f)
    f.tick() assert(f.queued(),"recovery report missing") f.report()
  end
  local function buttons(frame)
    local out={} for _,b in ipairs(frame.buttons) do out[b.id]=b end return out
  end
  test("F5-G2 budget rows read unknown before the first report, then the carried stacks",function()
    local f=fixture() f.configure("floor",5,1,5)
    local text=f.text(29,12,{})
    assert(text:find("need %S+ 25") and text:find("carried %S+ unknown"),text)
    ready(f)
    text=f.text(29,12,{})
    assert(text:find("carried %S+ 0") and not text:find("unknown",1,true),text)
    f.inventory[1]={name="minecraft:stone",count=12}
    f.inventory[3]={name="minecraft:stone",count=4}
    f.input("start")
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.count()==1 then break end end
    equal(f.mod().budget(),{total=25,remaining=24,carried=15})
    text=f.text(29,12,{})
    assert(text:find("need %S+ 24") and text:find("carried %S+ 15") and text:find("1/25",1,true),text)
  end)
  test("F5-G2 the material picker lists the reported items and says no report before one",function()
    local f=fixture() f.configure("floor",5,1,5)
    local session={buildSetup=true}
    f.press("material-pick",session)
    local text,frame=f.text(26,20,session)
    assert(text:find("no report",1,true) and not text:find("empty",1,true),text)
    equal(buttons(frame)["material minecraft:stone"],nil)
    ready(f)
    text=f.text(26,20,session)
    assert(text:find("empty",1,true) and not text:find("no report",1,true),text)
    f.inventory[2]={name="minecraft:dirt",count=7}
    f.inventory[5]={name="minecraft:dirt",count=2}
    f.inventory[6]={name="minecraft:glass",count=3}
    f.restart() ready(f)
    text,frame=f.text(26,20,session)
    local b=buttons(frame)
    assert(b["material minecraft:dirt"] and b["material minecraft:glass"],text)
    assert(text:find("dirt %S+ 9") and text:find("glass %S+ 3"),text)
    equal(b.prev,nil) equal(b.next,nil)
  end)
  test("F5-G2 a material picked mid-build keeps the cursor",function()
    local f=fixture() f.configure("floor",5,1,5)
    ready(f) f.input("start")
    for _=1,200 do f.tick() if f.queued() then f.report() end if f.count()==3 then break end end
    equal(f.count(),3)
    f.input("stop")
    for _=1,10 do if not f.queued() then break end f.report() f.tick() end
    local cursor=f.job().cursor
    f.inventory[7]={name="minecraft:dirt",count=30}
    f.restart() ready(f)
    local session={buildSetup=true}
    f.press("material-pick",session)
    f.press("material minecraft:dirt",session)
    equal(f.job().material,"minecraft:dirt")
    equal(f.job().cursor,cursor)
    equal(session.buildPick,nil)
    local text=f.text(29,12,{})
    assert(text:find("need %S+ "..(25-cursor+1)) and text:find("carried %S+ 30"),text)
  end)
end
