local H = dofile("tests/so/harness.lua")

local function boot(files)
  local net = H.new()
  local m = net.machine({ id = 1, directories = true, capacity = 16000000 })
  m.install({ "so-store.lua", "so-mod-cells.lua", "so-mod-lease.lua", "so-plan.lua" })
  for path, bytes in pairs(files or {}) do m.files[path] = bytes end
  m.env.SO = { now = function() return net.time end, mods = {},
    store = m.env.dofile("so-store.lua"), breathe = function() end }
  return m.env.dofile("so-mod-cells.lua"), m, net
end

local function fenced(files,safety)
  local cells,m,net=boot(files)
  m.files["so-server.cfg"]=H.encode({worldEdits=true,protectedAreas=safety})
  local sent={}
  m.env.rednet.send=function(_,wire) sent[#sent+1]=wire return true end
  m.env.SO.pair={key=function() return "key" end}
  m.env.SO.proto={build=function(_,t,body) return {t=t,body=body} end,encode=function(v) return v end}
  m.env.SO.mods.cells=cells
  local lease=m.env.dofile("so-mod-lease.lua") m.env.SO.mods.lease=lease
  local function hello()
    lease.handlers.hello({from=9,body={role="worker",dim="minecraft:overworld",
      capabilities={setupFence=true,parkBatch=true},journal={id="before",pose={x=0,y=0,z=0,f=0}}}})
  end
  hello()
  net.time=net.time+300000
  local function report(lid,change,ack)
    local body={lease=lid,journal="after",pose={x=0,y=0,z=0,f=0},results={{ok=true,
      data={dim="minecraft:overworld",x=4,y=5,z=6}}}}
    if change then change(body) end
    lease.handlers["step.report"]({from=9,body=body},ack)
  end
  return cells,m,net,lease,sent,hello,report
end

return function(test, equal)
  test("cells release: retry preserves reservations taken after the failed release", function()
    local cells, m, net = boot()
    local lane = { { "minecraft:overworld", 1, 2, 3 }, { "minecraft:overworld", 4, 5, 6 } }
    assert(cells.reserveMany("mine:9", lane))
    local open = m.env.fs.open
    m.env.fs.open = function(path, mode)
      if path == "so-data/cells/res.tmp" and mode == "w" then return nil end
      return open(path, mode)
    end
    equal(cells.releaseOwner("mine:9"), false)
    m.env.fs.open = open
    assert(cells.reserve("mine:9", 7, 8, 9))
    assert(cells.tick(net.time))
    assert(cells.reserveMany("next", lane))
    equal(cells.owner(7, 8, 9), "mine:9")
    local ok, reason = cells.reserveMany("next", { { "minecraft:overworld", 7, 8, 9 } })
    equal(ok, false)
    equal(reason, "held")
    local reboot = boot(m.files)
    equal(reboot.owner(7, 8, 9), "mine:9")
    equal(reboot.owner(4, 5, 6), "next")
  end)

  test("cells release: retry preserves snapshot cells handed to another owner", function()
    local cells, m, net = boot()
    assert(cells.reserve("mine:9", 1, 2, 3))
    local open = m.env.fs.open
    m.env.fs.open = function(path, mode)
      if path == "so-data/cells/res.tmp" and mode == "w" then return nil end
      return open(path, mode)
    end
    equal(cells.releaseOwner("mine:9"), false)
    m.env.fs.open = open
    assert(cells.handoff("mine:9", "other", 1, 2, 3))
    assert(cells.tick(net.time))
    equal(cells.owner(1, 2, 3), "other")
  end)

  for _, mode in ipairs({ "reserve", "reserveMany", "mixed" }) do
    test("cells release: " .. mode .. " renews a cell while its release is pending", function()
      local cells, m, net = boot()
      local pose = { "minecraft:overworld", 1, 2, 3 }
      local lane = { "minecraft:overworld", 4, 5, 6 }
      assert(cells.reserveMany("mine:9", { pose, lane }))
      local open = m.env.fs.open
      m.env.fs.open = function(path, access)
        if path == "so-data/cells/res.tmp" and access == "w" then return nil end
        return open(path, access)
      end
      equal(cells.releaseOwner("mine:9"), false)
      if mode == "reserve" then
        assert(cells.reserve("mine:9", 1, 2, 3))
      elseif mode == "reserveMany" then
        assert(cells.reserveMany("mine:9", { pose }))
      else
        m.env.fs.open = open
        assert(cells.reserveMany("mine:9", { pose, { "minecraft:overworld", 7, 8, 9 } }))
      end
      m.env.fs.open = open
      assert(cells.tick(net.time))
      equal(cells.owner(1, 2, 3), "mine:9")
      assert(cells.reserveMany("next", { lane }))
      local ok, reason = cells.reserveMany("next", { pose })
      equal(ok, false)
      equal(reason, "held")
      if mode == "mixed" then equal(cells.owner(7, 8, 9), "mine:9") end
    end)
  end

  test("cells release: a failed commit stays held until the next tick saves it", function()
    local cells, m, net = boot()
    local route = { { "minecraft:overworld", 1, 2, 3 }, { "minecraft:the_nether", 4, 5, 6 } }
    assert(cells.reserveMany("lane", route))
    assert(cells.reserve("other", 7, 8, 9))
    local open, attempts = m.env.fs.open, 0
    m.env.fs.open = function(path, mode)
      if path == "so-data/cells/res.tmp" and mode == "w" then
        attempts = attempts + 1
        if attempts == 1 then return nil end
      end
      return open(path, mode)
    end
    equal(cells.releaseOwner("lane"), false)
    equal(cells.owner(1, 2, 3), "lane")
    equal(cells.owner(4, 5, 6, "minecraft:the_nether"), "lane")
    local ok, reason = cells.reserveMany("next", route)
    equal(ok, false)
    equal(reason, "held")
    assert(cells.tick(net.time))
    equal(attempts, 2)
    equal(cells.owner(7, 8, 9), "other")
    local reboot = boot(m.files)
    equal(reboot.owner(1, 2, 3), nil)
    equal(reboot.owner(4, 5, 6, "minecraft:the_nether"), nil)
    assert(cells.reserveMany("next", route))
    assert(cells.tick(net.time))
    equal(attempts, 3)
    equal(cells.owner(1, 2, 3), "next")
  end)

  test("cells release: repeated failed ticks retain every pending owner", function()
    local cells, m, net = boot()
    assert(cells.reserve("lane", 1, 2, 3))
    assert(cells.reserve(42, 4, 5, 6))
    local open = m.env.fs.open
    m.env.fs.open = function(path, mode)
      if path == "so-data/cells/res.tmp" and mode == "w" then return nil end
      return open(path, mode)
    end
    equal(cells.releaseOwner("lane"), false)
    equal(cells.releaseOwner(42), false)
    for _ = 1, 2 do
      equal(cells.tick(net.time), false)
      equal(cells.owner(1, 2, 3), "lane")
      equal(cells.owner(4, 5, 6), 42)
    end
    m.env.fs.open = open
    assert(cells.tick(net.time))
    assert(cells.reserveMany("next", {
      { "minecraft:overworld", 1, 2, 3 }, { "minecraft:overworld", 4, 5, 6 },
    }))
  end)

  test("cells release: a failed recovery-policy save also retries the release", function()
    local cells, m, net = boot()
    assert(cells.reserve("lane", 1, 2, 3))
    cells.rememberWorker(9, { dim = "minecraft:overworld", x = 1, y = 2, z = 3 }, {})
    local open = m.env.fs.open
    m.env.fs.open = function(path, mode)
      if path == "so-data/dug-policy.tmp" and mode == "w" then return nil end
      return open(path, mode)
    end
    equal(cells.releaseOwner("lane"), false)
    equal(cells.tick(net.time), false)
    equal(cells.owner(1, 2, 3), "lane")
    m.env.fs.open = open
    assert(cells.tick(net.time))
    assert(cells.reserve("lane", 1, 2, 3))
    assert(cells.tick(net.time))
    equal(cells.owner(1, 2, 3), "lane")
    local reboot = boot(m.files)
    equal(reboot.owner(1, 2, 3), "lane")
  end)
  test("B3-B RELEASE waits for fenced GPS and lease acknowledgement",function()
    local c,m,_,lease,sent,_,report=fenced()
    assert(c.reserveMany("setup:9",{{"minecraft:overworld",4,5,6},{"minecraft:overworld",7,5,6}}))
    local offer=assert(c.releaseRequest("setup:9",10))
    equal(#sent,0)
    equal(c.releaseRequest("setup:9",11,offer.token),nil)
    local pending=assert(c.releaseRequest("setup:9",10,offer.token))
    equal(pending.status,"pending")
    equal(c.owner(7,5,6),"setup:9")
    equal(sent[1].body.steps,{{op="gps",park=true}})
    equal(sent[1].body.journal,"before")
    equal(lease.send(9,{{op="forward"}}),nil)
    local acknowledged=false
    report(pending.lease,nil,function(kind)
      equal(kind,"ack") equal(c.owner(7,5,6),nil) equal(c.owner(4,5,6),"gps:9") acknowledged=true
    end)
    assert(acknowledged)
    equal(c.owner(7,5,6),nil)
    equal(c.owner(4,5,6),"gps:9")
    equal(c.releaseStatus("setup:9").status,"released")
    equal(lease.peek(9).releasing,false)
    local reboot=boot(m.files)
    equal(reboot.owner(4,5,6),"gps:9")
    equal(reboot.owner(7,5,6),nil)
    local primary=m.files["so-data/cells/res"] m.files["so-data/cells/res"]=nil
    local recovered=boot(m.files)
    equal(recovered.owner(4,5,6),"gps:9")
    m.files["so-data/cells/res"]=primary
  end)

  for _,race in ipairs({"reservation","hello","assignment","open lease","short silence","boot grace","missing fence","unknown holder","token expiry","ignored contact","expired lease"}) do
    test("B3-B RELEASE rechecks "..race.." on confirmation",function()
      local c,m,net,lease,sent,hello=fenced()
      assert(c.reserve("setup:9",7,5,6))
      local offer=assert(c.releaseRequest("setup:9",10))
      if race=="reservation" then assert(c.reserve("other",8,5,6))
      elseif race=="hello" then hello()
      elseif race=="assignment" then m.env.SO.mods.mine={assigned=function() return true end}
      elseif race=="open lease" then assert(lease.send(9,{{op="inspectDown"}}))
      elseif race=="short silence" then net.time=net.time-1
      elseif race=="boot grace" then c=m.env.dofile("so-mod-cells.lua")
      elseif race=="missing fence" then
        lease.handlers.hello({from=9,body={role="worker",journal={id="before",pose={x=0,y=0,z=0,f=0}}}})
      elseif race=="unknown holder" then assert(c.releaseOwner("setup:9"))
      elseif race=="token expiry" then net.time=net.time+30001
      elseif race=="ignored contact" then lease.handlers["step.report"]({from=9,body={lease="foreign"}})
      elseif race=="expired lease" then
        assert(lease.send(9,{{op="forward"}},{ms=1})) net.time=net.time+10002 lease.tick(net.time)
      end
      equal(c.releaseRequest("setup:9",10,offer.token),nil)
      if race~="unknown holder" then equal(c.owner(7,5,6),"setup:9") end
      equal(#sent,(race=="open lease" or race=="expired lease") and 1 or 0)
    end)
  end

  for _,failure in ipairs({"timeout","GPS failure","old journal","pose change","uncertain","missing dimension","fractional GPS","wrong dimension","hello","reservation","assignment","disabled","save","rename","close save","hold save","send","restart"}) do
    test("B3-B RELEASE retains routes after "..failure,function()
      local c,m,net,lease,_,hello,report=fenced()
      assert(c.reserve("setup:9",7,5,6))
      local offer=assert(c.releaseRequest("setup:9",10))
      local open=m.env.fs.open
      if failure=="send" then m.env.rednet.send=function() return false end end
      if failure=="hold save" then
        m.env.fs.open=function(path,mode)
          if path=="so-data/cells/release-holds.tmp" and mode=="w" then return nil end
          return open(path,mode)
        end
      end
      local pending=c.releaseRequest("setup:9",10,offer.token)
      if failure=="send" or failure=="hold save" then equal(pending,nil)
      elseif failure=="timeout" then net.time=net.time+25001 lease.tick(net.time)
      elseif failure=="restart" then c=boot(m.files)
      else
        if failure=="hello" then hello() end
        if failure=="reservation" then assert(c.reserve("other",8,5,6)) end
        if failure=="assignment" then m.env.SO.mods.mine={assigned=function() return true end} end
        if failure=="disabled" then m.files["so-server.cfg"]=H.encode({worldEdits=false}) end
        if failure=="rename" then
          local move=m.env.fs.move
          m.env.fs.move=function(from,to)
            if from=="so-data/cells/res.tmp" then error("power loss during reservation rename") end
            return move(from,to)
          end
        end
        if failure=="close save" then
          local writes=0
          m.env.fs.open=function(path,mode)
            if path=="so-data/cells/res.tmp" and mode=="w" then writes=writes+1 if writes==2 then return nil end end
            return open(path,mode)
          end
        end
        if failure=="save" then
          m.env.fs.open=function(path,mode)
            if path=="so-data/cells/res.tmp" and mode=="w" then return nil end
            return open(path,mode)
          end
        end
        report(assert(pending).lease,function(body)
          if failure=="GPS failure" then body.results[1].ok=false
          elseif failure=="old journal" then body.journal="before"
          elseif failure=="pose change" then body.pose.x=1
          elseif failure=="uncertain" then body.uncertain=true
          elseif failure=="missing dimension" then body.results[1].data.dim=nil
          elseif failure=="fractional GPS" then body.results[1].data.x=0.5
          elseif failure=="wrong dimension" then body.results[1].data.dim="minecraft:the_end" end
        end)
      end
      m.env.fs.open=open
      equal(c.owner(7,5,6),"setup:9")
      local reboot=boot(m.files)
      equal(reboot.owner(7,5,6),"setup:9")
      if failure~="restart" then equal(lease.peek(9).releasing,false) end
      if failure~="restart" and failure~="hold save" then
        equal(lease.peek(9).releaseHold,true)
        equal(lease.send(9,{{op="forward"}}),nil)
      end
    end)
  end

  test("B3-B cells.forget uses the shared guarded two-request release",function()
    local c,_,_,_,_,_,report=fenced()
    assert(c.reserve("setup:9",7,5,6))
    local function request(body)
      local kind,answer
      c.handlers["cells.forget"]({from=10,body=body},function(k,b) kind,answer=k,b end)
      return kind,answer
    end
    local kind,first=request({who="setup:9"}) equal(kind,"cells.forget")
    local second
    kind,second=request({who="setup:9",confirm=first.confirm})
    equal(kind,"ack") equal(second.status,"pending")
    equal(c.owner(7,5,6),"setup:9")
    report(second.lease)
    equal(c.owner(7,5,6),nil)
  end)

  test("B3-B world edits default off closes the authenticated forget bypass",function()
    local c=boot()
    assert(c.reserve("setup:9",7,5,6))
    local kind
    c.handlers["cells.forget"]({from=10,body={who="setup:9"}},function(k) kind=k end)
    equal(kind,"err") equal(c.owner(7,5,6),"setup:9")
    equal(c.releaseRequest("setup:9",10),nil)
    equal(c.clearMarks({dim="minecraft:overworld",x1=0,y1=0,z1=0,x2=0,y2=0,z2=0},10),nil)
    equal(c.keep({}),false)
  end)

  test("B3-B fenced GPS renews the occupied cell when an older release is pending",function()
    local c,m,net,_,_,_,report=fenced()
    assert(c.reserve("setup:9",7,5,6)) assert(c.reserve("gps:9",4,5,6))
    local open=m.env.fs.open
    m.env.fs.open=function(path,mode)
      if path=="so-data/cells/res.tmp" and mode=="w" then return nil end
      return open(path,mode)
    end
    equal(c.releaseOwner("gps:9"),false)
    m.env.fs.open=open
    local offer=assert(c.releaseRequest("setup:9",10))
    local pending=assert(c.releaseRequest("setup:9",10,offer.token))
    local writes=0
    m.env.fs.open=function(path,mode)
      if path=="so-data/cells/res.tmp" and mode=="w" then writes=writes+1 if writes==2 then return nil end end
      return open(path,mode)
    end
    report(pending.lease)
    equal(c.releaseStatus("setup:9").status,"held")
    m.env.fs.open=open
    assert(c.tick(net.time))
    equal(c.owner(4,5,6),"gps:9") equal(c.owner(7,5,6),"setup:9")
    local reboot=boot(m.files)
    equal(reboot.owner(4,5,6),"gps:9") equal(reboot.owner(7,5,6),"setup:9")
  end)

  for _,safety in ipairs({false,true}) do
    test("B3-B release timeout allows retirement and fenced GPS recovery with safety="..tostring(safety),function()
      local files={}
      for i=1,3 do files["so-data/cells/minecraft%3aoverworld/"..(100+i).."_0_0"]=H.encode({schema=1,generation=1,
        value={format="hex4096",bits="1"..string.rep("0",1023),used=i}}) end
      local c,m,net,lease,sent,_,report=fenced(files,safety)
      local dim="minecraft:overworld"
      lease.handlers.hello({from=9,body={role="worker",dim=dim,gps={dim=dim,x=4,y=5,z=6},
        capabilities={parkBatch=true,setupFence=true},journal={id="before",pose={x=0,y=0,z=0,f=0}}}})
      net.time=net.time+300000
      m.env.SO.mods.state={disk=function() return {pressure=true} end}
      assert(c.reserve("setup:9",7,5,6))
      local offer=assert(c.releaseRequest("setup:9",10))
      assert(c.releaseRequest("setup:9",10,offer.token))
      net.time=net.time+25001 lease.tick(net.time)
      equal(c.releaseStatus("setup:9").status,"held")
      equal(lease.peek(9).releasing,false) equal(lease.peek(9).releaseHold,true)
      equal(lease.peek(9).boundaryHold,nil)
      equal(lease.protectionReady(),true)
      local protected={}
      assert(lease.dugProtection(function(d,p,margin) protected[#protected+1]={d=d,p=p,margin=margin} end))
      equal(protected[1],{d=dim,p={dim=dim,x=4,y=5,z=6},margin=48})
      assert(c.tick(net.time))
      local request=assert(c.retirement()) equal(request.status,"pending")
      assert(c.decideRetirement(request.id,"allow")) equal(c.isDug(1616,0,0),false)
      local box={dim=dim,x1=1632,y1=0,z1=0,x2=1632,y2=0,z2=0}
      local clear=assert(c.clearMarks(box,10))
      equal(assert(c.clearMarks(box,10,clear.token)).marks,1)
      lease.handlers.hello({from=10,body={role="worker",dim=dim,capabilities={parkBatch=true,setupFence=true},
        journal={id="other-before",pose={x=0,y=0,z=0,f=0}}}})
      local plan=m.env.dofile("so-plan.lua")
      local frame=plan.frame({dim=dim,x=160,y=0,z=0,facing=0},{x=0,y=0,z=0,f=0})
      local other=assert(lease.send(10,{{op="forward"}},{frame=frame}))
      lease.handlers["step.report"]({from=10,body={lease=other,journal="other-after",pose={x=0,y=0,z=-1,f=0},results={{ok=true}}}})
      equal(lease.peek(10).last.ok,true)
      equal(lease.send(9,{{op="forward"}},{recover=true}),nil)
      equal(lease.send(9,{{op="inspectDown"}},{recover=true}),nil)
      local recovery=assert(lease.send(9,{{op="gps"}},{recover=true}))
      equal(sent[#sent].body.journal,"before") equal(sent[#sent].body.steps,{{op="gps",park=true}})
      report(recovery)
      equal(lease.peek(9).releaseHold,false) equal(lease.peek(9).boundaryHold,nil)
      equal(lease.peek(9).reconciled,true)
      equal(c.owner(7,5,6),"setup:9") equal(c.owner(4,5,6),"gps:9")
      equal(c.releaseStatus("setup:9").status,"held")
      assert(c.protect({}))
      frame=plan.frame({dim=dim,x=4,y=5,z=6,facing=0},{x=0,y=0,z=0,f=0})
      assert(lease.send(9,{{op="forward"}},{frame=frame}))
    end)
  end

  for _,failure in ipairs({"GPS failure","old journal","wrong dimension","new contact","save","timeout"}) do
    test("B3-B recovery GPS preserves the per-worker hold after "..failure,function()
      local c,m,net,lease,_,hello,report=fenced()
      assert(c.reserve("setup:9",7,5,6))
      local offer=assert(c.releaseRequest("setup:9",10)) assert(c.releaseRequest("setup:9",10,offer.token))
      net.time=net.time+25001 lease.tick(net.time)
      local recovery=assert(lease.send(9,{{op="gps"}},{recover=true}))
      if failure=="timeout" then net.time=net.time+70001 lease.tick(net.time)
      else
        if failure=="new contact" then hello() end
        if failure=="save" then
          local open=m.env.fs.open
          m.env.fs.open=function(path,mode)
            if path=="so-data/cells/res.tmp" and mode=="w" then return nil end
            return open(path,mode)
          end
        end
        report(recovery,function(body)
          if failure=="GPS failure" then body.results[1].ok=false
          elseif failure=="old journal" then body.journal="before"
          elseif failure=="wrong dimension" then body.results[1].data.dim="minecraft:the_nether" end
        end)
      end
      equal(lease.peek(9).releaseHold,true) equal(lease.peek(9).releasing,false)
      equal(lease.peek(9).boundaryHold,nil) equal(c.owner(7,5,6),"setup:9")
      equal(lease.send(9,{{op="forward"}}),nil)
      assert(lease.dugProtection(function() end))
    end)
  end

end
