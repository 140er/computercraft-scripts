local R = dofile('tests/ui/render.lua')
local S = dofile('tests/ui/scene.lua')
local A = dofile('tests/ui/size-adapters.lua')
local Actions=dofile('tests/ui/size-actions.lua')
return function(path)
local previous
local input = assert(io.open(path, 'rb'))
local P=dofile('so-proto.lua')
local inputs=assert(tonumber(assert(input:read('*l')):match('^inputs (%d+)$')),'missing input hashes')
for _=1,inputs do
  local name,digest=assert(input:read('*l')):match('^(%S+) (%x+)$')
  local file=assert(io.open(assert(name),'rb'))
  local bytes=file:read('*a') file:close()
  assert(P.hex(P.sha256(bytes))==digest,'stale size expectations: '..name..'; run python3 tests/ui/size-coverage.py --prepare')
end
local count, failed, pendingCount, groups = 0, 0, 0, {}
local router=S.new()
for header in input:lines() do
  local id,state,ws,hs=header:match('^(%S+) (%S+) (%d+) (%d+)$')
  assert(id,'invalid comparison case')
  local w,h=tonumber(ws),tonumber(hs)
  local expected={w=w,h=h,text={},fg={},bg={}}
  for _,layer in ipairs({'text','fg','bg'}) do
    for y=1,h do expected[layer][y]=assert(input:read('*l'),'truncated comparison case') end
  end
  local controls,budget,off=assert(input:read('*l')):match('^controls (%d+) budget (%d+) disabled (%d+)$')
  local required={}
  for _=1,assert(tonumber(controls),'missing required controls') do required[assert(input:read('*l'))]=true end
  local disabled={}
  for _=1,assert(tonumber(off),'missing disabled controls') do disabled[assert(input:read('*l'))]=true end
  local pending=assert(assert(input:read('*l')):match('^pending (.*)$'),'missing pending status')
  if previous~=id then print('size-render: checking '..id) io.stdout:flush() previous=id end
  local name=id..'/'..state..'/'..ws..'x'..hs
  local ok,err=pcall(function()
    local frame,handler,session=A.render(id,state,w,h,{budget=tonumber(budget)})
    assert(frame,'adapter returned no frame')
    assert(#frame.rows==h,'row count')
    local diff=R.diff(expected,S.capture(frame,w,h))
    assert(#diff==0,table.concat(diff,'\n'))
    for _,b in ipairs(frame.buttons or {}) do
      assert(b.x>=1 and b.y>=1 and b.w>0 and (b.h or 1)>0 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,'button bounds '..b.id)
    end
    local owners, reachable = {}, {}
    for _,b in ipairs(frame.buttons or {}) do
      for y=b.y,b.y+(b.h or 1)-1 do
        owners[y]=owners[y] or {}
        for x=b.x,b.x+b.w-1 do
          local previous=owners[y][x]
          assert(not previous or previous==b.id or previous=='dismiss','overlapping controls '..tostring(previous)..' '..b.id)
          owners[y][x]=b.id
        end
      end
    end
    for y,row in pairs(owners) do
      for x,bid in pairs(row) do
        if not reachable[bid] then
          Actions.tap(frame,handler,session,A.context,router,bid,x,y,disabled[bid])
          reachable[bid]=true
        end
      end
    end
    Actions.required(frame,required,reachable)
  end)
  count=count+1
  if count%500==0 then print("size-render: "..count.." cases checked") io.stdout:flush() end
  if pending~='' then
    local detail=tostring(err):match('^.-:%d+: (.*)$')
    if not ok and detail==pending then
      pendingCount=pendingCount+1
      print('EXPECTED-PENDING '..name..': '..pending)
      ok=true
    elseif ok then
      ok,err=false,'expected-pending case passed; remove its manifest exception'
    end
  end
  if not ok then
    failed=failed+1
    local group=id..'/'..state
    groups[group]=(groups[group] or 0)+1
    print('FAIL '..name..'\n'..tostring(err))
  end
end
input:close()
for id,n in pairs(groups) do print('FAILURES '..id..' '..n) end
print(string.format('size-render: %d cases, %d failed, %d expected-pending',count,failed,pendingCount))
return count,failed
end
