local M={}
local globals={[_G]=true}
for _,value in pairs(_G) do if type(value)=='table' then globals[value]=true end end

-- Every tap starts from the same session and module state, including closure-held counters.
local function snapshot(roots, input)
  local saved,bindings,functions={},{},{}
  local function visit(value)
    if type(value)=='function' then
      if functions[value] or debug.getinfo(value,'S').what=='C' then return end
      functions[value]=true
      for i=1,60 do
        local name,v=debug.getupvalue(value,i)
        if not name then break end
        if name~='_ENV' then bindings[#bindings+1]={value,i,v,name} visit(v) end
      end
    elseif type(value)=='table' and not globals[value] and not saved[value] then
      local copy={} saved[value]=copy
      for k,v in pairs(value) do copy[k]=v visit(v) end
    end
  end
  for _,root in ipairs(roots) do visit(root) end
  visit(input)
  return saved,bindings
end

local function restore(saved,bindings)
  for target,values in pairs(saved) do
    for k in pairs(target) do if values[k]==nil then target[k]=nil end end
    for k,v in pairs(values) do target[k]=v end
  end
  for _,b in ipairs(bindings) do debug.setupvalue(b[1],b[2],b[3]) end
end

local function changed(saved,bindings)
  for target,values in pairs(saved) do
    for k,v in pairs(target) do if values[k]~=v then return true end end
    for k,v in pairs(values) do if target[k]~=v then return true end end
  end
  for _,b in ipairs(bindings) do local _,v=debug.getupvalue(b[1],b[2]) if v~=b[3] then return true end end
  return false
end


M.required=function(frame,required,reachable)
  local targets={}
  for _,button in ipairs(frame.buttons or {}) do targets[button.id]=true end
  for bid in pairs(required) do
    assert(targets[bid],'missing required control '..bid)
    assert(reachable[bid],'unreachable required control '..bid)
  end
end

local EFFECT={setMinimum=true,setWatch=true,setList=true,setPin=true,send=true,order=true,settings=true,decide=true,extend=true,close=true,forgetDevice=true,pairCode=true,input=true,command=true}
local cached
local NAV={health=true,attention=true,events=true,alerts=true,errors=true}
M.tap=function(frame,input,session,context,router,bid,x,y,disabled)
  assert(type(input)=='function','missing real input handler for '..bid)
  assert(type(session)=='table','missing real input session for '..bid)
  if cached then
    for _,method in ipairs(cached.methods) do
      if method.target[method.key]~=method.fn then cached=nil break end
    end
  end
  if not cached or cached.frame~=frame or cached.input~=input then
    local saved,bindings=snapshot({session,context or {}},input)
    local methods={}
    for target,values in pairs(saved) do for key,fn in pairs(values) do
      if EFFECT[key] and type(fn)=='function' then methods[#methods+1]={target=target,key=key,fn=fn} end
    end end
    cached={frame=frame,input=input,saved=saved,bindings=bindings,methods=methods}
  end
  local saved,bindings=cached.saved,cached.bindings
  local opened,calls={},0
  local commands=context and context.commands and #context.commands
  local effects=context and context.effects and #context.effects
  local saves=type(context and context.saves)=='function' and context.saves() or context and context.saves
  local ok,err=pcall(function()
    router.D.monitor={name='coverage',frame=frame}
    router.D.localDraw=function(_,event)
      assert(event.id==bid,'tap reached a different action')
      event.session,event.from=session,session.id
      event.open=function(role,actions) opened[#opened+1]={role=role,actions=actions} end
      input(event)
      calls=calls+1
    end
    local spies={}
    for _,method in ipairs(cached.methods) do
      local target,key,fn=method.target,method.key,method.fn
      local spy={target=target,key=key,fn=fn,count=0,ids={}} spies[#spies+1]=spy
      target[key]=function(...)
        spy.count=spy.count+1
        local event=select(1,...)
        if key=='input' and type(event)=='table' then spy.ids[#spy.ids+1]=event.id end
        return fn(...)
      end
    end
    router.D.localTouch('coverage',x,y)
    for _,spy in ipairs(spies) do
      spy.target[spy.key]=spy.fn
      local allowed=1
      if spy.key=='input' and (bid:match('^drop:') or bid=='broken') then allowed=2 end
      if spy.key=='decide' and bid:match('^enroll%-all:') then allowed=0 for _ in bid:gmatch('%d+%-%d+') do allowed=allowed+1 end end
      if spy.key=='input' and spy.count==2 and allowed==2 then
        assert(spy.ids[1]=='list' and spy.ids[2]:match('^focus:'),'drop navigation must initialize LIST then focus its row')
      end
      assert(spy.count<=allowed,'one tap called '..spy.key..' '..spy.count..' times')
    end
    assert(calls==1,'one tap must call its real handler once')
    assert(#opened<=1,'one tap opened multiple destinations')
    if #opened>0 and NAV[bid] then assert(opened[1].role==bid,'wrong navigation destination '..bid) end
    if context and context.screens and context.screens.health and NAV[bid] then assert(#opened==1,'navigation must open its destination once') end
    if commands then
      local count=#context.commands-commands
      local selected=saved[session].turtle
      local before=selected and saved[selected]
      local key=bid=='turtle-remove' and 'remove' or bid=='turtle-save' and 'add' or nil
      if bid=='turtle-park' then
        assert(count==1 and context.commands[commands+1]=='stop','PARK must issue one stop command')
        assert(context.mine.mod.facts().state=='stopped','PARK must stop the real mining job')
      elseif key then
        local fire=before.confirm==key
        assert(count==(fire and 1 or 0),'two-tap control must issue its command only once when confirmed')
        if fire then
          local text=context.commands[commands+1]
          assert(text:match('^'..(key=='remove' and 'remove' or 'add')..' '..selected.id),'turtle command destination')
        else assert(session.turtle.confirm==key,'first tap must arm the drawn confirmation') end
      else assert(count==0,'navigation must not send a turtle command') end
    end
    local tab=bid:match('^tab:(.+)$')
    if tab and session.pocket then assert(session.pocket.page==tab,'wrong pocket tab destination') end
    local turtle=bid:match('^turtle:(%d+)$')
    if turtle then
      if context and context.S and context.S.points then
        local view=context.S.views[session.id]
        local old=saved[view].turtle
        local want=old~=tonumber(turtle) and tonumber(turtle) or nil
        assert(view.turtle==want,'drop setup turtle selection must toggle once')
      else assert(session.turtle and session.turtle.id==turtle,'turtle control must open its detail') end
    end
    if bid=='disk' then assert(session.visit=='disk','disk control must open disk') end
    if bid:match('^drop:') or bid=='broken' and context and context.generic then
      assert(session.visit=='generic','drop control must open drops')
    end
    if bid=='setup-next' then
      local view=session.mining or session.lumber
      assert(view and view.offset==(saved[view].offset or 0)+1,'setup pager must advance once')
    end
    if bid=='ar-back' then assert(session.arPicker==nil,'AR BACK must close picker') end
    if bid=='ar-more' then assert(session.arPicker.page==saved[session.arPicker].page+1,'AR pager must advance once') end
    if context and context.A then
      local dim=bid:match('^ar%-dim:(%a+)$')
      local n=bid:match('^ar%-turtle:(%d+)$')
      local drop=bid:match('^ar%-drop:(.+)$')
      if dim then assert(context.A.dim==context.A.dimIds[dim],'AR dimension destination') end
      if n or drop or bid=='ar-all' then
        local focus=context.A.focus
        assert(focus.kind==(n and 'turtle' or drop and 'drop' or 'all') and focus.id==(n and tonumber(n) or drop),'AR focus destination')
      end
    end
    if bid=='alerts-back' then assert(session.alertList==nil,'BACK must return from ALERTS') end
    if bid=='alert-next' and saved[session].alertList then assert(session.alertList==saved[session].alertList+1,'ALERTS NEXT must advance once') end
    if bid=='alert-prev' and saved[session].alertList then assert(session.alertList==saved[session].alertList-1,'ALERTS PREV must advance once') end
    if effects then
      local count=#context.effects-effects
      local dim=bid:match('^worker%-dim:(%a+)$')
      local swap=bid:match('^worker%-swap:(%a+)$')
      if dim or swap then
        local dims={world='minecraft:overworld',nether='minecraft:the_nether',['end']='minecraft:the_end'}
        local wanted=dim and dims[dim] or swap=='on'
        local field=dim and 'dim' or 'autoToolSwap'
        local needs=dim and dim~='world' or swap=='on'
        assert(count==(needs and 1 or 0),'worker change must issue one request')
        if needs then
          local effect=context.effects[#context.effects]
          assert(effect[1]=='settings' and effect[2]==4 and effect[3][field]==wanted,'worker request destination')
        end
      elseif bid:match('^enroll%-all:') then
        local expected=0
        for id,n in bid:gmatch('(%d+)%-(%d+)') do
          expected=expected+1
          local effect=context.effects[effects+expected]
          assert(effect and effect[1]=='decide' and effect[2]==tonumber(id) and effect[3]==tonumber(n) and effect[4]==true,'bulk enrollment destination')
        end
        assert(count==expected,'bulk enrollment must decide each shown row once')
      elseif bid=='enroll-extend' or bid=='enroll-close' or bid:match('^enroll%-[on][ko]:') or bid:match('^forget%-confirm:') then
        assert(count==1,'one tap must issue one enrollment or forget action')
      end
    end
    if bid=='paired' then assert(session.panel.page=='paired','PAIR must open PAIRED') end
    if bid=='worker-back' then assert(session.panel.page=='paired','WORKER BACK must return to PAIRED') end
    if bid=='paired-back' then assert(session.panel.page=='pair','PAIRED BACK must return to PAIR') end
    if bid=='panel-back' then assert(session.panel.page=='main','panel BACK must return to main') end
    if bid=='turtle-back' then assert(session.turtle==nil,'turtle BACK must close detail') end
    if bid=='inventory-back' then assert(session.turtle.page==nil,'inventory BACK must return to detail') end
    if bid=='turtle-cancel' then assert(session.turtle.draft==nil,'pose CANCEL must return to detail') end
    if bid=='material-back' then assert(session.buildPick==nil,'material BACK must close picker') end
    if bid=='tab:setup' and not session.pocket then
      if session.buildSetup~=nil then assert(session.buildSetup==true,'build SETUP destination')
      else local view=session.mining or session.lumber assert(view and view.page=='setup','job SETUP destination') end
    end
    if bid=='tab:job' then assert(session.buildSetup==false,'build JOB destination') end
    if bid=='tab:overview' then local view=session.mining or session.lumber assert(view and view.page=='main','job OVERVIEW destination') end
    local field,sign=bid:match('^set%-(%w+)([%+%-])$')
    if field or bid=='start' or bid=='stop' then
      local checked,refusal=false,nil
      for _,b in ipairs(bindings) do
        if b[4]=='S' and type(b[3])=='table' then
          local _,state=debug.getupvalue(b[1],b[2])
          refusal=state.error or state.feedback or refusal
        end
      end
      for _,b in ipairs(bindings) do
        if (b[4]=='job' or b[4]=='j') and type(b[3])=='table' and b[3].running~=nil then
          local _,job=debug.getupvalue(b[1],b[2])
          if field and saved[b[3]][field] then
            local delta=(sign=='+' and 1 or -1)*(field=='length' and 8 or 1)
            local old=saved[b[3]]
            assert(job[field]==old[field]+delta or job[field]==old[field] and type(refusal)=='string' and #refusal>0,'job step must act once or explain refusal') checked=true
          elseif not field then
            assert(job.running==(bid=='start') or type(refusal)=='string' and #refusal>0,'job command destination or refusal') checked=true
          end
        end
      end
      assert(checked,'missing job action contract '..bid)
    end
    local axis,delta=bid:match('^pose:(%a+):(%-?%d+)$')
    if axis then
      local draft=session.turtle.draft
      local original=assert(saved[assert(saved[session].turtle)]).draft
      local before=assert(saved[original])[axis]
      local step=axis=='facing' and 1 or session.turtle.step or 1
      local want=before+tonumber(delta)*step
      if axis=='facing' then want=want%4 end
      assert(draft[axis]==want,'pose step must act once')
    end
    if context and context.A and context.A.layerIds[bid] then
      local before=assert(saved[assert(saved[context.A].layers)])[bid]
      assert(context.A.layers[bid]==not before,'AR layer must toggle once')
    end
    if saves~=nil then
      local after=type(context.saves)=='function' and context.saves() or context.saves
      assert(after-saves<=1,'one tap saved more than once')
      if context.A and context.A.layerIds[bid] then assert(after==saves+1,'AR tap must save once') end
    end
    local views=context and context.S and context.S.views
    local view=views and (views[session.id] or views[tostring(session.id)])
    if not view then
      for _,b in ipairs(bindings) do
        if b[4]=='S' and type(b[3])=='table' and b[3].views then
          local candidate=b[3].views[session.id] or b[3].views[tostring(session.id)]
          if candidate and candidate.tab then view=candidate break end
        end
      end
    end
    if view and view.tab then
      if tab then assert(view.tab==tab,'stock tab destination') end
      for _,key in ipairs({'sort','cat','sub','low'}) do
        local value=bid:match('^'..key..':(.+)$')
        if value then assert(view[key]==value,'stock filter destination '..key) end
      end
    end
    if bid=='next' or bid=='prev' then
      local pager=view
      local field='page'
      if session.buildPick then pager=session.buildPick
      elseif session.pocket and session.pocket.page=='shop' then pager,field=session.pocket,'shopPage'
      elseif session.panel and session.panel.page=='shop' then pager,field=session.panel,'shopPage' end
      for _,b in ipairs(bindings) do
        if b[4]=='role' and NAV[b[3]] and session.visibility and session.visibility[b[3]] then
          pager=session.visibility[b[3]]
          if pager.error then field='errorPage' elseif pager.picker then pager=pager.picker end
          break
        end
      end
      assert(pager and saved[pager],'missing pager state contract')
      local old=saved[pager][field] or 1
      local want=disabled and old or bid=='next' and old+1 or math.max(1,old-1)
      assert(pager[field]==want,'pager must '..(disabled and 'stay on its disabled page' or 'move exactly one page'))
    end
    if bid=='map-fit' then assert(session.map.fit==true,'map FIT destination') end
    -- A selected tab or filter can be idempotent. Its destination still has to match.
    local idempotent=tab or bid:match('^sort:') or bid:match('^cat:') or bid:match('^sub:') or bid:match('^low:')
      or bid:match('^show:') or bid:match('^worker%-dim:') or bid:match('^worker%-swap:')
      or bid=='start' or bid=='stop' or bid=='map-pick' or bid=='map-fit' or bid=='map-in' or bid=='map-out' or bid=='queue-stop' or (bid=='prev' or bid=='next') and disabled
    assert(changed(saved,bindings) or #opened==1 or idempotent,'tap performed no action: '..bid)
  end)
  restore(saved,bindings)
  assert(ok,err)
end
return M
