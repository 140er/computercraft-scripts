local mocks = dofile("tests/mocks.lua")
local env = setmetatable({textutils={serialize=mocks.encode}}, {__index=_G})
local Wizard = assert(loadfile("wh2-wizard.lua", "t", env))()
local passed = 0
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, entry in pairs(value) do result[key] = copy(entry) end
  return result
end
local function test(name, body)
  local ok, err = pcall(body)
  assert(ok, name .. "\n" .. tostring(err))
  passed = passed + 1
  print("PASS " .. name)
end
local function fixture()
  local state = {}
  local ctx = {now=1792500000000,epoch=3,config={enabled=true,operators={["4"]=true,["5"]=true}}}
  local function call(op, body, sender)
    return Wizard.run(state, sender or 4, {op=op,body=body}, ctx)
  end
  local function edit(action, item, extra, sender)
    local q = state.wh2.wizard.questions[item]
    local body = {action=action,item=item,baseRevision=state.wh2.wizard.revision,
      questionId=q.id,draftRevision=q.draft and q.draft.revision or 0}
    for k,v in pairs(extra or {}) do body[k]=v end
    if body.draft then body.draft.revision=body.draftRevision end
    return call("wh2-class",body,sender), body
  end
  return state,ctx,call,edit
end
local value = {class="ores",route="blast",storeCategory="ingots",recipeId="example:tin_heat"}
local function draft(editor, text)
  return {v=1,editor=editor or 4,revision=0,updatedAt=0,step="recipe",
    answers={class="ores",route="blast",storeCategory="ingots"},text=text or "example:tin"}
end

test("contract3 reports include version, question revision, and false draft",function()
  local s,_,call = fixture()
  local result=call("wh2-unknown",{item="example:raw_tin",sampleLocationId=false},17)
  assert(result.ok)
  assert(s.wh2.wizard.v==1 and result.question.v==1)
  assert(result.question.revision==1 and result.question.draft==false)
  assert(Wizard.valid(s.wh2.wizard))
end)

test("drafts persist partial fields and cannot become effective answers",function()
  local s,ctx,call,edit = fixture()
  assert(call("wh2-unknown",{item="example:raw_tin",sampleLocationId=false},17).ok)
  local result=edit("draft","example:raw_tin",{draft=draft()})
  assert(result.ok)
  local q=result.question
  assert(q.state=="answering" and q.revision==2)
  assert(q.draft.revision==1 and q.draft.editor==4 and q.draft.updatedAt==ctx.now)
  assert(q.draft.step=="recipe" and q.draft.text=="example:tin")
  assert(q.draft.answers.recipeId==nil and s.wh2.wizard.classes["example:raw_tin"]==nil)
  local rebooted=assert(load("return "..mocks.encode(s),"state","t",{}))()
  assert(Wizard.valid(rebooted.wh2.wizard))
  local again=call("wh2-unknown",{item="example:raw_tin",sampleLocationId="other"},18)
  assert(mocks.encode(again.question)==mocks.encode(q))
  assert(again.revision==result.revision)
end)

test("a refreshed operator takes over and fences the prior editor",function()
  local s,ctx,call,edit=fixture()
  assert(call("wh2-unknown",{item="example:a",sampleLocationId=false}).ok)
  local first,old=edit("draft","example:a",{draft=draft()})
  assert(first.ok)
  local second=edit("draft","example:a",{draft=draft(5,"kept text")},5)
  assert(second.ok and second.question.draft.editor==5)
  local before=mocks.encode(s)
  old.draft.text="stale overwrite"
  assert(call("wh2-class",old).code=="stale_revision")
  assert(mocks.encode(s)==before)
  assert(edit("resolve","example:a",{value=value},4).code=="forbidden")
  local done=edit("resolve","example:a",{value=value},5)
  assert(done.ok and done.question.state=="resolved" and done.question.draft==false)
  assert(done.class.v==1 and done.class.updatedBy==5)
end)

test("discard keeps the durable question and unknown answers stay resolved",function()
  local s,_,call,edit=fixture()
  assert(call("wh2-unknown",{item="example:a",sampleLocationId=false}).ok)
  assert(edit("draft","example:a",{draft=draft()}).ok)
  local discarded=edit("discard","example:a")
  assert(discarded.ok and discarded.question.state=="open" and discarded.question.draft==false)
  local done=edit("resolve","example:a",{value={class="misc",route="unknown",storeCategory="misc",recipeId=false}})
  assert(done.ok and done.question.state=="resolved")
  local again=call("wh2-unknown",{item="example:a",sampleLocationId=false},17)
  assert(again.revision==done.revision and again.question.state=="resolved")
end)

test("set cannot bypass a pending question or consume an illegal false value",function()
  local s,_,call=fixture()
  assert(call("wh2-unknown",{item="example:a",sampleLocationId=false}).ok)
  local before=mocks.encode(s)
  assert(call("wh2-class",{action="set",item="example:a",baseRevision=1,value=value}).code=="invalid")
  assert(mocks.encode(s)==before)
  for _,key in ipairs({"class","route","storeCategory"}) do
    local invalid=copy(value)
    invalid[key]=false
    assert(call("wh2-class",{action="set",item="example:b",baseRevision=1,value=invalid}).code=="invalid")
  end
  assert(call("wh2-class",{action="set",item="example:b",baseRevision=1,value=value},17).code=="forbidden")
end)

test("draft limits and malformed partial values reject without mutation",function()
  local s,_,call,edit=fixture()
  assert(call("wh2-unknown",{item="example:a",sampleLocationId=false}).ok)
  for _,patch in ipairs({{step="done"},{text=false},{text=string.rep("x",4097)},
    {answers={class=false}},{answers={recipeId=true}},{answers={extra=true}}}) do
    local d=draft()
    for k,v in pairs(patch) do d[k]=v end
    local before=mocks.encode(s)
    local result=edit("draft","example:a",{draft=d})
    assert(result.ok==false)
    assert(mocks.encode(s)==before)
  end
end)

test("a legal large draft remains readable as a complete question",function()
  local s,ctx,call,edit=fixture()
  assert(call("wh2-unknown",{item="example:a",sampleLocationId=false}).ok)
  assert(call("wh2-unknown",{item="example:b",sampleLocationId=false}).ok)
  local maximum=draft()
  maximum.revision,maximum.updatedAt=1,1792500000000
  maximum.text=""
  maximum.text=string.rep("x",4096-#mocks.encode(maximum))
  assert(#mocks.encode(maximum)==4096)
  local saved=edit("draft","example:a",{draft=maximum})
  assert(saved.ok)
  local rebooted=assert(load("return "..mocks.encode(s),"state","t",{}))()
  assert(Wizard.valid(rebooted.wh2.wizard))
  local page=Wizard.run(rebooted,4,{op="wh2-get",body={topic="questions",cursor=0}},ctx)
  assert(page.ok,"Legal drafts must remain readable after reboot")
  assert(page.records[1].draft.text==maximum.text)
  assert(#page.records==1 and #mocks.encode(page)<=6144 and page.cursor==1)
  local nextPage=Wizard.run(rebooted,4,{op="wh2-get",body={topic="questions",cursor=page.cursor,revision=page.revision}},ctx)
  assert(nextPage.ok and nextPage.records[1].item=="example:b" and nextPage.cursor==0)
  local envelope={wire=2,v=1,type="ssot_reply",direction="reply",op="wh2-get",server=0,client=4,
    counter=2147483647,rid=string.rep("r",64),session=string.rep("s",64),sessionGeneration=2147483647,
    boot=string.rep("b",64),keyId=string.rep("k",64),mac=string.rep("f",64),body=page}
  assert(#mocks.encode(envelope)<=8192)
end)

test("numeric authority epochs and required record versions reject legacy shapes",function()
  local s,ctx,call=fixture()
  ctx.epoch="3"
  assert(call("wh2-unknown",{item="example:a",sampleLocationId=false}).code=="invalid")
  assert(s.wh2==nil)
  assert(not Wizard.valid({revision=0,classes={},questions={}}))
  assert(not Wizard.valid({v=2,revision=0,classes={},questions={}}))
end)

print(string.format("%d wizard contract3 tests passed",passed))
return true
