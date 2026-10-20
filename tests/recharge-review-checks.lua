return function(test,read,mocks)
  local sources={}
  for _,path in ipairs({"miner.lua","mining.lua","warehouse.lua","atomic.lua","ssot.lua",
      "mine-tasks.lua","warehouse-tasks.lua","ssot-client.lua"}) do sources[path]=read(path) end
  read=function(path) return assert(sources[path],"fixture source missing: "..path) end
  test("recharge command completion survives restart and rejects replay",function()
    local fixture=dofile("tests/nav-fixture.lua")(nil,mocks)
    local world=fixture({epoch=1})
    assert(world.nav.recover())
    assert(world.nav.control("recharge",1,4,"recharge-1"))
    local restored=world.reopen()
    assert(restored.controlState().kind=="recharge" and not restored.controlState().complete)
    assert(restored.completeControl(1,4))
    restored=world.reopen()
    assert(restored.controlState().complete)
    assert(not restored.control("recharge",2,4,"recharge-1"),"new server epoch replayed a completed recharge")
    assert(restored.rechargeReceipt()=="recharge-1")
    assert(restored.control("recharge",2,5,"recharge-2"))
    assert(not restored.controlState().complete,"new recharge inherited the old completion")
    assert(not restored.completeControl(1,4),"old completion consumed a newer request")
  end)
  for _,scenario in ipairs({{rises=true,label="fuel rise"},{label="no fuel rise"},
      {cancel="recall",label="cancellation by recall"},{cancel="go",label="cancellation by go"}}) do
    test("confirmed recharge runs the real service and reports "..scenario.label,function()
      local rises=scenario.rises
      local dim="minecraft:overworld"
      local home={dim=dim,x=0,y=65,z=0,h=1}
      local m=mocks.miner({home={x=0,y=65,z=0},facing=1,spine=2,ssot={server=0,dimension=dim},
        mining={enabled=true,home=home,targets={"minecraft:diamond_ore"}},
        warehouse={enabled=true,drop="drop",charger="charge",targetFuel=70,chargeTimeout=1000}})
      local env=m.env
      env.dofile=function(path) return assert(load(read(path),"@"..path,"t",env))() end
      local A=env.dofile("atomic.lua")
      local prefix=assert(read("miner.lua"):match("^(.*)\nopenModem%(%)"))
      local api=assert(load(prefix.."\nreturn {C=C,st=st,listener=listener,packet=packet}","=miner.lua","t",env))()
      local current,fuel,command=A.copy(home),40,{}
      local charged,visits,completed=0,{},0
      local cancelledAt,returnedAt
      local sites={
        drop={kind="drop",pose={dim=dim,x=1,y=65,z=0,h=1},side="front"},
        charge={kind="charge",pose={dim=dim,x=2,y=65,z=0,h=1},side="front"},
      }
      api.C.nav={
        control=function(kind,epoch,cid,rechargeId)
          if kind=="recharge" and command.rechargeId==rechargeId then return false,"duplicate recharge" end
          if command.cid and cid<=command.cid then return false,"stale command" end
          command={kind=kind,epoch=epoch,cid=cid,rechargeId=rechargeId}
          return true
        end,
        controlState=function() return A.copy(command) end,
        completeControl=function(epoch,cid,rechargeId)
          if epoch~=command.epoch or cid~=command.cid or rechargeId~=command.rechargeId then return false end
          command.complete=true completed=completed+1 return true
        end,
        stopped=function() return false end,
        pose=function() return A.copy(current) end,
        homeCost=function(to,from) return math.abs(to.x-(from or current).x) end,
        go=function(to)
          fuel=fuel-math.abs(to.x-current.x)
          current=A.copy(to) visits[#visits+1]=to.x
          return true
        end,
        face=function(h) current.h=h return true end,
      }
      api.C.ssot={call=function(op,fields)
        if op=="recharge-check" then return {ok=true} end
        if op=="wh-sites" or op=="wh-lock" then return {ok=true,site=A.copy(sites[fields.name])} end
        assert(op=="wh-unlock",op)
        return {ok=true}
      end}
      env.turtle.getFuelLevel=function() return fuel end
      env.turtle.getFuelLimit=function() return 100 end
      env.turtle.getItemCount=function() return 0 end
      env.turtle.getItemDetail=function() end
      env.sleep=function(seconds)
        if api.st.rechargeResult=="cancelled" and not returnedAt then returnedAt=m.time end
        m.time=m.time+(seconds or 0)
        if scenario.cancel and current.x==2 and command.kind=="recharge" then
          api.C.nav.control(scenario.cancel,1,2)
          cancelledAt=m.time
        end
        if rises and current.x==2 then fuel=math.min(100,fuel+10) charged=charged+10 end
        coroutine.yield()
      end
      m.app=coroutine.create(api.listener)
      m.push()
      m.push("rednet_message",999,{type="recharge",commandEpoch="1",cid=1},"minearmy")
      assert(command.kind==nil,"unpaired sender started recharge")
      m.push("rednet_message",0,{type="recharge",commandEpoch="1",cid=1},"minearmy")
      assert(command.kind==nil,"forged server ID started recharge over the legacy channel")
      local transport=env.dofile("ssot-client.lua").new({server=0,secret="paired-miner-secret"})
      api.C.ssot.dispatch=transport.dispatch
      local request=coroutine.create(function() return transport.call("recharge-check") end)
      assert(coroutine.resume(request))
      local packet={v=1,type="ssot_reply",server=0,rid=m.messages[#m.messages].rid,ok=true,
        auth="wrong",recharge={epoch=1,cid=1,rechargeId="recharge-1"}}
      assert(not api.C.receiveSSOT(0,packet,"fleetserver") and command.kind==nil)
      packet.auth="paired-miner-secret"
      local rid=packet.rid
      packet.rid="unrequested"
      assert(not api.C.receiveSSOT(0,packet,"fleetserver") and command.kind==nil)
      packet.rid=rid
      assert(api.C.receiveSSOT(0,packet,"fleetserver"))
      assert(command.kind=="recharge","correlated authenticated reply did not start recharge")
      assert(coroutine.resume(request,"ssot_reply",rid))
      local worker=coroutine.create(api.C.runMining)
      for _=1,80 do
        local ok,why=coroutine.resume(worker)
        assert(ok,why)
        if completed==1 or scenario.cancel and api.st.rechargeResult=="cancelled" then break end
      end
      assert(completed==(scenario.cancel and 0 or 1),"service consumed the wrong command or did not finish")
      assert(current.x==home.x and current.h==home.h,"service did not return to its home pose")
      local reached=false for _,x in ipairs(visits) do if x==2 then reached=true end end
      assert(reached,"production service never visited the configured charger")
      assert(api.packet().rechargeAvailable and api.packet().rechargeResult==api.st.rechargeResult)
      if scenario.cancel then
        assert(command.kind==scenario.cancel and api.st.rechargeResult=="cancelled")
        assert(charged==0 and returnedAt and returnedAt-cancelledAt<1,"superseded recharge waited for the charging timeout")
      elseif rises then assert(charged>0 and fuel>40 and api.st.rechargeResult=="charged")
      else assert(charged==0 and api.st.rechargeResult=="no charging fuel rise",tostring(api.st.rechargeResult)) end
      m.push("rednet_message",0,{type="recharge",commandEpoch="1",cid=1},"minearmy")
      assert(scenario.cancel and command.kind==scenario.cancel or command.complete,"replayed recharge changed the current command")
    end)
  end
end
