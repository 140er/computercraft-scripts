return function(test,Client)
  test("explicit calibration carries the pending token across a client failure",function()
    local secret="test-secret-123456"
    local client=Client.new({server=0,secret=secret,counterFile="client-calibration.counter"})
    local send,seen=rednet.send,false
    rednet.send=function(_,m,protocol)
      if m.op=="calibrate" then
        assert(m.previous.x==0 and m.pose.x==10 and m.token=="pending" and m.epoch=="epoch")
        seen=true
      end
      assert(client.dispatch(0,{v=1,type="ssot_reply",server=0,rid=m.rid,auth=secret,ok=true,
        token="pending",epoch="epoch",untilAt=os.epoch("utc")+10000},protocol))
    end
    local ok,err=pcall(function()
      local p={dim="minecraft:overworld",x=0,y=64,z=0}
      local to={dim=p.dim,x=1,y=64,z=0}
      assert(not pcall(client.move,p,to,function() error("client fault") end))
      local observed={dim=p.dim,x=10,y=64,z=0}
      assert(client.calibrate(observed,p) and seen)
      assert(client.move(observed,{dim=p.dim,x=11,y=64,z=0},function() return true end))
    end)
    rednet.send=send
    assert(ok,err)
  end)
  test("a full queue busy reply is retried with the same request id",function()
    local secret="test-secret-123456"
    local client=Client.new({server=0,secret=secret,counterFile="client-busy.counter",timeout=1})
    local send,rids=rednet.send,{}
    rednet.send=function(_,m,protocol)
      rids[#rids+1]=m.rid
      if #rids<3 then
        assert(client.dispatch(0,{type="busy",error="busy",rid=m.rid},protocol))
      else
        assert(client.dispatch(0,{v=1,type="ssot_reply",server=0,rid=m.rid,auth=secret,ok=true},protocol))
      end
    end
    local ok,err=pcall(function()
      local reply=client.sync({pose={dim="minecraft:overworld",x=0,y=64,z=0}})
      assert(reply and reply.ok)
      assert(#rids==3 and rids[1]==rids[2] and rids[2]==rids[3],"busy retry changed the request id")
    end)
    rednet.send=send
    assert(ok,err)
  end)
  test("client accepts bounded pages containing long block names",function()
    local secret="test-secret-123456"
    local client=Client.new({server=0,secret=secret,counterFile="client-boundary.counter"})
    local send=rednet.send
    rednet.send=function(_,m,protocol)
      local reply={v=1,type="ssot_reply",server=0,rid=m.rid,auth=secret,ok=true,cells={},cursor=0,revision=1}
      for i=1,64 do reply.cells[i]={i,"minecraft:" .. string.rep("a",118)} end
      while #textutils.serialize(reply,{compact=true})>8192 do table.remove(reply.cells) end
      assert(#reply.cells>16)
      assert(client.dispatch(0,reply,protocol),"valid page rejected")
      return true
    end
    local ok,err=pcall(function()
      local reply=client.snapshot({chunk="minecraft:overworld|0|4|0"})
      assert(reply and reply.ok and #reply.cells>16)
    end)
    rednet.send=send
    assert(ok,err)
  end)
  local function replies(client, secret, decide)
    local ops = {}
    local send = rednet.send
    rednet.send = function(_, m, protocol)
      ops[#ops + 1] = m.op
      local reply = { v = 1, type = "ssot_reply", server = 0, rid = m.rid, auth = secret, ok = true,
        epoch = "epoch", token = "t", untilAt = os.epoch("utc") + 10000 }
      decide(m, reply, ops)
      assert(client.dispatch(0, reply, protocol))
    end
    return ops, function() rednet.send = send end
  end
  test("a finished move syncs the destination when commit is late and dead turtles are enabled", function()
    local secret = "test-secret-123456"
    local client = Client.new({ server = 0, secret = secret, counterFile = "client-dead-recover.counter", deadTurtles = true })
    local ops, restore = replies(client, secret, function(m, reply)
      if m.op == "commit" then reply.ok, reply.error = false, "expired; reconcile" end
    end)
    local p = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }
    local to = { dim = p.dim, x = 1, y = 64, z = 0 }
    local ok, err = pcall(function() assert(client.move(p, to, function() return true end)) end)
    restore()
    assert(ok, err)
    assert(ops[1] == "sync" and ops[2] == "reserve" and ops[3] == "start" and ops[4] == "commit" and ops[5] == "sync")
  end)
  test("a late commit still stops movement when dead turtles are disabled", function()
    local secret = "test-secret-123456"
    local client = Client.new({ server = 0, secret = secret, counterFile = "client-dead-halt.counter" })
    local ops, restore = replies(client, secret, function(m, reply)
      if m.op == "commit" then reply.ok, reply.error = false, "expired; reconcile" end
    end)
    local p = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }
    local to = { dim = p.dim, x = 1, y = 64, z = 0 }
    local ok = pcall(function() client.move(p, to, function() return true end) end)
    restore()
    assert(not ok)
    assert(ops[#ops] == "commit")
    local halted, why = client.move(to, { dim = to.dim, x = 2, y = 64, z = 0 }, function() return true end)
    assert(halted == false and why == "SSOT movement stopped; reboot and reconcile")
  end)
  test("a failed recovery sync still stops the turtle", function()
    local secret = "test-secret-123456"
    local client = Client.new({ server = 0, secret = secret, counterFile = "client-dead-conflict.counter", deadTurtles = true })
    local syncs = 0
    local _, restore = replies(client, secret, function(m, reply)
      if m.op == "commit" then reply.ok, reply.error = false, "expired; reconcile" end
      if m.op == "sync" then
        syncs = syncs + 1
        if syncs > 1 then reply.ok, reply.error = false, "pose conflict" end
      end
    end)
    local p = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }
    local ok = pcall(function() client.move(p, { dim = p.dim, x = 1, y = 64, z = 0 }, function() return true end) end)
    restore()
    assert(not ok)
  end)
end
