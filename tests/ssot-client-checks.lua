return function(test,Client)
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
end
