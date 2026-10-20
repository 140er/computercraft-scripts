local M = {}
function M.open(context)
  local client,screen=context.client,context.screen or term.current()
  local registry=dofile("wh2-fleet.lua").registry
  local names={} for key in pairs(registry) do names[#names+1]=key end table.sort(names)
  local api={target=false,index=1,revision=false,effective={},pending="refresh",note="Fetching fleet settings"}
  local actions={}
  local function body(result) return result and (result.body or result) end
  function api.tick()
    local action=table.remove(actions,1) or api.pending
    if not action then return end
    api.pending=nil
    local target=api.target
    if type(action)=="table" then target=action.target end
    local request={wh2=1,topic="settings",cursor=0}
    if target~=false then request.computerId=target else request.field="defaults" end
    local result,err=client.call("wh2-get",request)
    result=body(result)
    if not result or not result.ok then api.note=tostring(err or result and result.error or "Server unavailable") return end
    local row=result.records and result.records[1]
    if not row or type(row.effective)~="table" then api.note="Settings response is incomplete" return end
    if api.target==target then api.revision,api.effective=result.revision,row.effective end
    if type(action)=="table" then
      local patch={wh2=1,scope=target==false and "global" or "turtle",baseRevision=result.revision,set={},unset={}}
      if target~=false then patch.computerId=target end
      if action.unset then patch.unset={action.key} else patch.set[action.key]=action.value end
      local saved,why=client.call("wh2-settings",patch) saved=body(saved)
      api.note=saved and saved.ok and "Settings saved" or tostring(why or saved and saved.error or "Save failed")
      if not api.pending then api.pending="refresh" end
    else api.note="Settings revision "..tostring(api.revision) end
  end
  function api.select(computerId)
    if computerId~=false and (type(computerId)~="number" or computerId<0 or computerId%1~=0) then return false end
    api.target,api.pending=computerId,"refresh" return true
  end
  function api.set(key,value)
    if not registry[key] then return false,"Unknown setting" end
    if #actions>=64 then return false,"Too many pending edits" end
    actions[#actions+1]={key=key,value=value,target=api.target} return true
  end
  function api.unset(key)
    if not registry[key] then return false,"Unknown setting" end
    if #actions>=64 then return false,"Too many pending edits" end
    actions[#actions+1]={key=key,unset=true,target=api.target} return true
  end
  function api.draw()
    local w,h=screen.getSize()
    screen.setBackgroundColor(colors.black) screen.setTextColor(colors.white) screen.clear()
    local function line(y,text) screen.setCursorPos(1,y) screen.write(tostring(text):sub(1,w)) end
    line(1,"Fleet dev | "..(api.target==false and "Global defaults" or "Computer #"..api.target))
    local rows=math.max(1,h-4)
    local first=math.max(1,math.min(api.index-math.floor(rows/2),#names-rows+1))
    for i=first,math.min(#names,first+rows-1) do
      local key,value=names[i],api.effective[names[i]]
      if type(value)=="table" then value=textutils.serialize(value,{compact=true}) end
      line(i-first+2,(i==api.index and "> " or "  ")..key.." = "..tostring(value))
    end
    line(h-2,"Arrows select. Enter edits. U inherits.")
    line(h-1,"G global. T turtle. Esc closes.")
    line(h,api.note)
  end
  function api.handle(event,key)
    if event=="key" then
      if key==keys.up then api.index=math.max(1,api.index-1)
      elseif key==keys.down then api.index=math.min(#names,api.index+1)
      elseif key==keys.enter then return "edit",names[api.index],api.effective[names[api.index]]
      elseif key==keys.escape then return "close" end
    elseif event=="char" then
      if key=="u" then api.unset(names[api.index])
      elseif key=="g" then api.select(false)
      elseif key=="t" then return "target" end
    end
    return "draw"
  end
  return api
end
function M.run(client,screen)
  local dev=M.open({client=client,screen=screen})
  local function edit()
    dev.draw()
    while true do
      local event,key=os.pullEvent()
      local action,name,value=dev.handle(event,key)
      if action=="close" then return end
      if action=="target" or action=="edit" then
        print(action=="target" and "Computer ID" or name.." as a Lua value")
        local input=read()
        if action=="target" then dev.select(tonumber(input))
        else
          local parsed=textutils.unserialize(input)
          if parsed~=nil then dev.set(name,parsed) else dev.note="Invalid value" end
        end
      end
      dev.draw()
    end
  end
  parallel.waitForAny(edit,function()
    while true do dev.tick() os.queueEvent("wh2_dev_draw") sleep(.1) end
  end)
end
return M
