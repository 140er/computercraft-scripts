return function(test,read,mocks)
  local source=read("miner.lua")
  test("miner reserves each displacement only when SSOT is enabled",function()
    for _,enabled in ipairs({false,true}) do
      local cfg={home={x=100,y=64,z=20},facing=2,spine=3}
      if enabled then cfg.ssot={enabled=true,dimension="minecraft:overworld",server=0,secret="test-secret-123456"} end
      local m=mocks.miner(cfg)
      local calls=0
      m.env.dofile=function(path)
        if path == "atomic.lua" then return assert(loadfile(path, "t", m.env))() end
        assert(path=="ssot-client.lua", path)
        return {new=function()
          return {move=function(from,to,execute)
            calls=calls+1
            assert(from.dim=="minecraft:overworld" and from.dim==to.dim)
            assert(math.abs(from.x-to.x)+math.abs(from.y-to.y)+math.abs(from.z-to.z)==1)
            return execute()
          end}
        end}
      end
      local code=assert(source:match("^(.*)\nopenModem%(%)"))
      local api=assert(load(code .. "\nreturn {move=rawMove,pos=pos,st=st,listener=listener,event=C.netEvent}","=miner.lua","t",m.env))()
      for d=0,5 do assert(api.move(d)) end
      api.st.turnFrom=2
      assert(api.move((api.st.h+2)%4,nil,true))
      assert((enabled and api.st.turnFrom==nil) or (not enabled and api.st.turnFrom==2))
      assert(api.pos.x==m.pos.x and api.pos.y==m.pos.y and api.pos.z==m.pos.z)
      assert(calls==(enabled and 7 or 0))
      m.files["dev.key"]="test-key"
      m.app=coroutine.create(api.listener)
      m.push()
      m.push(api.event,7,{type="dev",op="drive",act="forward",key="test-key"},"minearmy")
      local reply=m.messages[#m.messages]
      assert(reply.type=="dev_reply" and reply.ok==not enabled)
    end
  end)
end
