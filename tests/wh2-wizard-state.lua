local mocks = dofile("tests/mocks.lua")
local function forbidden() error("The wizard attempted an external effect.") end
local env = setmetatable({ textutils={serialize=mocks.encode}, sleep=forbidden,
  fs=setmetatable({}, {__index=function() return forbidden end}),
  rednet={send=forbidden,broadcast=forbidden}, peripheral={call=forbidden} }, {__index=_G})
local M = assert(loadfile("wh2-wizard.lua","t",env))()
local passed = 0
local function equal(actual, expected)
  assert(mocks.encode(actual)==mocks.encode(expected),
    "Expected "..mocks.encode(expected)..", got "..mocks.encode(actual))
end
local function copy(v)
  if type(v)~="table" then return v end
  local result = {}
  for k,x in pairs(v) do result[k]=copy(x) end
  return result
end
local function test(name, fn)
  local ok, err = pcall(fn)
  assert(ok,name.."\n"..tostring(err))
  passed=passed+1
  print("PASS "..name)
end
local function context()
  return { now=1792500000000, epoch=1, config={enabled=true,operators={["4"]=true}},
    save=forbidden, send=forbidden, recipes={getUsesOf=forbidden} }
end
local function run(s, op, body, sender, ctx)
  ctx=ctx or context()
  if ctx.epoch==nil then ctx.epoch=1 end
  if op=="wh2-class" and body.action==nil then
    body=copy(body)
    local q=s.wh2 and s.wh2.wizard and s.wh2.wizard.questions and s.wh2.wizard.questions[body.item]
    body.action=q and q.state~="resolved" and "resolve" or "set"
    if body.action=="resolve" then body.questionId,body.draftRevision=q.id,q.draft and q.draft.revision or 0 end
  end
  return M.run(s,sender or 4,{op=op,body=body},ctx)
end
local function query(s, topic, cursor, revision, id)
  if cursor==nil then cursor=0 end
  return run(s,"wh2-get",{wh2=1,topic=topic,cursor=cursor,revision=revision,id=id})
end
local function report(s, item, location, sender, ctx)
  return run(s,"wh2-unknown",{item=item,sampleLocationId=location or false},sender,ctx)
end
local function answer(s, item, revision, value, sender, ctx)
  return run(s,"wh2-class",{item=item,baseRevision=revision,value=value or {
    class="ores",route="blast",storeCategory="ingots",recipeId="example:tin_from_blasting"}},sender,ctx)
end
local function row(item, source, revision)
  return {v=1,item=item,class="misc",route="store",storeCategory="misc",recipeId=false,
    source=source or "wizard",revision=revision or 1,updatedBy=4}
end
local function state()
  return {wh2={schema=1,wizard={v=1,revision=0,classes={},questions={}}}}
end
local function reject(s, code, op, body, sender, ctx)
  local before = mocks.encode(s)
  local result = run(s,op,body,sender,ctx)
  equal(result.ok,false)
  equal(result.code,code)
  assert(type(result.error)=="string" and #result.error>0)
  equal(mocks.encode(s),before)
end

test("Absent state validates and reads without creating subtrees",function()
  assert(M.valid(nil))
  local s = {schema=1,warehouse={kept=true}}
  equal(query(s,"classes"),{wh2=1,ok=true,revision="0:0",records={},cursor=0})
  equal(query(s,"questions").revision,0)
  equal(s,{schema=1,warehouse={kept=true}})
end)

test("Unknown reports coalesce across workers and preserve the first observation",function()
  local s = {}
  local first = report(s,"example:raw_tin","warehouse-in",17)
  assert(first.ok)
  equal(first.revision,1)
  equal(first.question,{v=1,id="item:example:raw_tin",item="example:raw_tin",state="open",
    revision=1,firstSeen=1792500000000,sampleLocationId="warehouse-in",draft=false})
  local ctx = context()
  ctx.now=ctx.now+10000
  local again = report(s,"example:raw_tin","another-input",18,ctx)
  equal(again,first)
  equal(s.wh2.wizard.revision,1)
  assert(M.valid(s.wh2.wizard))
  first.question.state="resolved"
  equal(s.wh2.wizard.questions["example:raw_tin"].state,"open")
end)

test("An answer atomically resolves its question and stamps the operator",function()
  local s = {}
  assert(report(s,"example:raw_tin").ok)
  local result = answer(s,"example:raw_tin",1,{class="ores",route="blast",storeCategory="ingots",
    recipeId="example:tin_from_blasting",updatedBy=999,source="layout",revision=999})
  assert(result.ok)
  equal(result.revision,2)
  equal(result.class,{v=1,item="example:raw_tin",class="ores",route="blast",storeCategory="ingots",
    recipeId="example:tin_from_blasting",updatedBy=4,source="wizard",revision=2})
  equal(result.question.state,"resolved")
  equal(result.question.firstSeen,1792500000000)
  equal(report(s,"example:raw_tin").revision,2)
  equal(s.wh2.wizard.questions["example:raw_tin"].state,"resolved")
  result.class.route="fuel"
  equal(s.wh2.wizard.classes["example:raw_tin"].route,"blast")
  assert(M.valid(s.wh2.wizard))
end)

test("Concurrent answers reject the stale editor without changing either record",function()
  local s = {}
  assert(report(s,"example:a").ok)
  assert(report(s,"example:b").ok)
  assert(answer(s,"example:a",2).ok)
  reject(s,"stale_revision","wh2-class",{item="example:b",baseRevision=2,
    value={class="ores",route="blast",storeCategory="ingots",recipeId=false}})
  equal(s.wh2.wizard.questions["example:b"].state,"open")
  equal(s.wh2.wizard.classes["example:b"],nil)
end)

test("Skipping is local and cannot close a durable question",function()
  local s = {}
  assert(report(s,"example:skip").ok)
  local body = {item="example:skip",baseRevision=1,skip=true}
  reject(s,"invalid","wh2-class",body)
  equal(query(s,"questions").records[1].state,"open")
end)

test("Feature opt-in and configured operator IDs control writes",function()
  local body = {item="example:a",baseRevision=0,value={class="misc",route="store",
    storeCategory="misc",recipeId=false}}
  for _, cfg in ipairs({{}, {enabled=false}, {enabled="true"}}) do
    reject({},"disabled","wh2-class",body,4,{config=cfg})
  end
  for _, operators in ipairs({{}, {[4]=true}, {["4"]=1}, {["5"]=true}}) do
    reject({},"forbidden","wh2-class",body,4,{config={enabled=true,operators=operators}})
  end
  reject({},"forbidden","wh2-class",body,17)
  reject({},"forbidden","wh2-unknown",{item="example:a",sampleLocationId=false},-1)
  local s = {}
  assert(report(s,"example:a",false,17).ok)
  assert(query(s,"questions").ok)
  assert(answer(s,"example:a",1).ok)
end)

test("Only the verified body supplies operation arguments",function()
  local s = {}
  local before = mocks.encode(s)
  equal(M.run(s,4,{op="wh2-unknown",item="example:a",sampleLocationId=false},context()).code,"invalid")
  equal(M.run(s,4,{op="wh2-unknown",body={item="example:a",sampleLocationId=false},
    item="example:spoof"},context()).ok,true)
  equal(s.wh2.wizard.questions["example:spoof"],nil)
  assert(s.wh2.wizard.questions["example:a"])
  assert(before~=mocks.encode(s))
end)

test("Classes overlay layout defaults without changing other owners' state",function()
  local layout = {revision=7,classDefaults={
    ["example:a"]=row("example:a","layout",7),["example:b"]=row("example:b","layout",3)},
    rooms={opaque=true}}
  local s = {schema=1,wh2={schema=1,layout=layout,fleet={opaque=true},craft={opaque=true}},
    warehouse={opaque=true},moves={opaque=true}}
  local before = mocks.encode(s)
  local first = query(s,"classes")
  equal(first.revision,"7:0")
  equal(#first.records,2)
  equal(mocks.encode(s),before)
  assert(answer(s,"example:a",0).ok)
  assert(s.wh2.layout==layout)
  equal(layout.classDefaults["example:a"].route,"store")
  equal(s.wh2.fleet,{opaque=true})
  equal(s.wh2.craft,{opaque=true})
  equal(s.moves,{opaque=true})
  equal(s.warehouse,{opaque=true})
  local view = query(s,"classes")
  equal(view.revision,"7:1")
  equal(view.records[1].source,"wizard")
  equal(view.records[2].source,"layout")
  view.records[2].route="unknown"
  equal(layout.classDefaults["example:b"].route,"store")
  equal(s.wh2.wizard.questions,{})
end)

test("Both topics page in sorted order within byte and record budgets",function()
  local s = state()
  for i=128,1,-1 do assert(report(s,string.format("example:item_%03d",i),"warehouse-in").ok) end
  for i=128,1,-1 do assert(answer(s,string.format("example:item_%03d",i),s.wh2.wizard.revision).ok) end
  for _, topic in ipairs({"questions","classes"}) do
    local cursor, revision, seen, pages = 0,nil,{},0
    repeat
      local result = query(s,topic,cursor,revision)
      assert(result.ok)
      assert(#mocks.encode(result)<=4096)
      assert(#result.records>0 and #result.records<=64)
      revision=revision or result.revision
      equal(result.revision,revision)
      for _, record in ipairs(result.records) do
        local expected = string.format("example:item_%03d",#seen+1)
        equal(record.item,expected)
        seen[#seen+1]=record.item
      end
      if result.cursor~=0 then assert(result.cursor>cursor) end
      cursor=result.cursor
      pages=pages+1
      assert(pages<=128)
    until cursor==0
    equal(#seen,128)
    assert(pages>1)
  end
end)

test("Later pages require pins and detect changes in either class owner",function()
  local s = state()
  for i=1,35 do assert(report(s,"example:item_"..i).ok) end
  local first = query(s,"questions")
  assert(first.cursor>0)
  equal(query(s,"questions",first.cursor).code,"invalid")
  assert(report(s,"example:another").ok)
  equal(query(s,"questions",first.cursor,first.revision).code,"stale_revision")
  local classes = query(s,"classes")
  s.wh2.layout={revision=1,classDefaults={}}
  equal(query(s,"classes",0,classes.revision).code,"stale_revision")
  local second = query(s,"classes")
  assert(answer(s,"example:a",s.wh2.wizard.revision).ok)
  equal(query(s,"classes",0,second.revision).code,"stale_revision")
end)

test("Queries select one stable ID and reject invalid cursors and revisions",function()
  local s = {}
  assert(report(s,"example:a").ok)
  assert(report(s,"example:b").ok)
  equal(#query(s,"questions",0,nil,"item:example:b").records,1)
  equal(query(s,"questions",0,nil,"item:example:b").records[1].item,"example:b")
  equal(#query(s,"questions",0,nil,"item:example:absent").records,0)
  for _, cursor in ipairs({-1,0.5,257,"0",false,math.huge}) do
    equal(query(s,"questions",cursor).code,"invalid")
  end
  equal(query(s,"questions",3,2).code,"invalid")
  equal(query(s,"questions",0,false).code,"invalid")
  equal(query(s,"classes",0,1).code,"invalid")
  equal(query(s,"classes",0,"bad").code,"invalid")
  equal(query(s,"classes",0,"9999999999:0").code,"invalid")
  equal(query(s,"classes",0,"00:0").code,"invalid")
  equal(query(s,"unowned").code,"invalid")
end)

test("Class capacity never evicts and still permits updates",function()
  local s = state()
  s.wh2.wizard.revision=1
  for i=1,128 do
    local item="example:item_"..i
    s.wh2.wizard.classes[item]=row(item)
  end
  assert(M.valid(s.wh2.wizard))
  reject(s,"capacity","wh2-class",{item="example:overflow",baseRevision=1,
    value={class="misc",route="store",storeCategory="misc",recipeId=false}})
  assert(answer(s,"example:item_1",1).ok)
  equal(s.wh2.wizard.classes["example:item_128"].item,"example:item_128")
end)

test("Question capacity never evicts and still permits answers and duplicates",function()
  local s = {}
  for i=1,128 do assert(report(s,"example:item_"..i).ok) end
  reject(s,"capacity","wh2-unknown",{item="example:overflow",sampleLocationId=false})
  equal(report(s,"example:item_1").revision,128)
  assert(answer(s,"example:item_1",128).ok)
  equal(s.wh2.wizard.questions["example:item_128"].state,"open")
end)

test("Every contract route and category round-trips",function()
  local s = {}
  local routes = {"store","furnace","blast","smoker","fuel","unknown"}
  local categories = {"any","ores","ingots","gems","fuel","misc"}
  for i, route in ipairs(routes) do
    local item="example:item_"..i
    local result=answer(s,item,i-1,{class=categories[i],route=route,
      storeCategory=categories[i],recipeId=false})
    assert(result.ok)
    equal(query(s,"classes",0,nil,item).records[1].route,route)
  end
end)

test("Malformed and oversized fields fail before publishing an answer",function()
  local s = {}
  assert(report(s,"example:a").ok)
  local good = {item="example:a",baseRevision=1,value={class="ores",route="blast",
    storeCategory="ingots",recipeId=false}}
  for _, patch in ipairs({{route="trash"},{class="metal"},{storeCategory="chest"},
    {recipeId="guessed_recipe"},{recipeId=string.rep("a",129)},
    {updatedBy=-1},{source="worker"},{revision=0.5},{item="example:b"},
    {extra=true},{route={}},{recipeId=function() end}}) do
    local body=copy(good)
    for k,v in pairs(patch) do body.value[k]=v end
    reject(s,"invalid","wh2-class",body)
  end
  for _, field in ipairs({"class","route","storeCategory","recipeId"}) do
    local body=copy(good)
    body.value[field]=nil
    reject(s,"invalid","wh2-class",body)
  end
  for _, item in ipairs({"no_namespace","example:a b","EXAMPLE:A","example:",string.rep("a",129),false,{}}) do
    reject(s,"invalid","wh2-unknown",{item=item,sampleLocationId=false})
  end
  reject(s,"invalid","wh2-unknown",{item="example:b",sampleLocationId=string.rep("a",65)})
  reject(s,"invalid","wh2-unknown",{item="example:b",sampleLocationId=false,firstSeen=0})
  reject(s,"invalid","wh2-class",{item="example:a",baseRevision=1,value=good.value,skip=true})
  equal(s.wh2.wizard.questions["example:a"].state,"open")
end)

test("Resource and derived question IDs are bounded without truncation",function()
  local s = {}
  local longest="x:"..string.rep("a",57)
  assert(report(s,longest).ok)
  equal(#s.wh2.wizard.questions[longest].id,64)
  reject(s,"too_large","wh2-unknown",{item=longest.."a",sampleLocationId=false})
  local item="x:"..string.rep("a",126)
  assert(answer(s,item,1,{class="misc",route="furnace",storeCategory="misc",recipeId=item}).ok)
  equal(query(s,"classes",0,nil,item).records[1].item,item)
end)

test("Cycles, shared references, metatables, and sparse tables cannot become state",function()
  local bodies = {}
  local cyclic = {item="example:a",sampleLocationId=false}
  cyclic.extra=cyclic
  bodies[#bodies+1]=cyclic
  bodies[#bodies+1]=setmetatable({item="example:a",sampleLocationId=false},{})
  bodies[#bodies+1]={[1]="example:a",[3]=false}
  for _, body in ipairs(bodies) do
    local s={}
    local ok,result=pcall(run,s,"wh2-unknown",body)
    assert(ok)
    equal(result.code,"invalid")
    equal(s,{})
  end
  local shared={}
  assert(not M.valid({revision=0,classes=shared,questions=shared}))
  local cycle=state().wh2.wizard
  cycle.questions["example:a"]=cycle
  assert(not M.valid(cycle))
  assert(not M.valid(setmetatable({revision=0,classes={},questions={}},{__pairs=forbidden})))
end)

test("Saved state rejects malformed shapes and impossible resolved questions",function()
  local variants={false,{}, {revision=-1,classes={},questions={}},
    {revision=1,classes=false,questions={}}, {revision=1,classes={},questions=false}}
  for _, value in ipairs(variants) do assert(not M.valid(value)) end
  local base={v=1,revision=1,classes={["example:a"]=row("example:a")},questions={}}
  for _, patch in ipairs({{item="example:b"},{source="layout"},{revision=2},
    {updatedBy="4"},{route="delete"},{class="unknown"},{extra=true}}) do
    local value=copy(base)
    for k,v in pairs(patch) do value.classes["example:a"][k]=v end
    assert(not M.valid(value))
  end
  local q={v=1,id="item:example:a",item="example:a",state="resolved",revision=1,firstSeen=1,sampleLocationId=false,draft=false}
  assert(not M.valid({v=1,revision=1,classes={},questions={["example:a"]=q}}))
  for _, patch in ipairs({{id="wrong"},{state="skipped"},{firstSeen=math.huge},
    {sampleLocationId={}},{extra=true}}) do
    local value=copy(base)
    value.questions["example:a"]=copy(q)
    for k,v in pairs(patch) do value.questions["example:a"][k]=v end
    assert(not M.valid(value))
  end
  local excessive=copy(base)
  for i=1,129 do excessive.classes["example:item_"..i]=row("example:item_"..i) end
  assert(not M.valid(excessive))
end)

test("Malformed saved roots are preserved and never normalized",function()
  for _, s in ipairs({{wh2=false},{wh2={}},{wh2={schema=2}},
    {wh2={schema=1,wizard=false}},{wh2={schema=1,wizard={revision=0}}}}) do
    reject(s,"invalid","wh2-unknown",{item="example:a",sampleLocationId=false})
  end
  local s={wh2={schema=1,layout={revision=1,classDefaults={bad=true}}}}
  reject(s,"invalid","wh2-get",{topic="classes",cursor=0})
  assert(query(s,"questions").ok)
  assert(report(s,"example:a").ok)
  equal(s.wh2.layout,{revision=1,classDefaults={bad=true}})
end)

test("Timestamp and revision exhaustion cannot publish partial changes",function()
  for _, now in ipairs({-1,0.5,false,math.huge,9007199254740992}) do
    local ctx=context()
    ctx.now=now
    reject({},"invalid","wh2-unknown",{item="example:a",sampleLocationId=false},17,ctx)
  end
  local s=state()
  s.wh2.wizard.revision=2147483647
  reject(s,"capacity","wh2-unknown",{item="example:a",sampleLocationId=false})
  reject(s,"capacity","wh2-class",{item="example:a",baseRevision=2147483647,
    value={class="misc",route="store",storeCategory="misc",recipeId=false}})
end)

test("The module returns without saving, sending, yielding, or querying recipes",function()
  local s={}
  local thread=coroutine.create(function()
    assert(report(s,"example:a").ok)
    assert(answer(s,"example:a",1).ok)
    assert(query(s,"questions").ok)
    assert(query(s,"classes").ok)
  end)
  local ok,err=coroutine.resume(thread)
  assert(ok,err)
  equal(coroutine.status(thread),"dead")
end)

print(string.format("%d wizard state tests passed",passed))
return true
