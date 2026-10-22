local H = dofile("tests/so/harness.lua")
local F = dofile("tests/so/dug-fixture.lua")
local function marked(cells, i) return cells.isDug((100+i)*16, 0, 0) end
local function saved(m, path, value)
  m.files[path] = H.encode({schema=1, generation=1, value=value})
end

return function(test, equal)
  test("dug retirement: crossing 1 MB only requests consent, then allow retires oldest first", function()
    local cells, m, net = F.setup(nil, 500)
    assert(cells.tick(net.time))
    local request = assert(cells.retirement())
    equal(request.status, "pending")
    assert(request.bytes > 1000000 and request.count > 100)
    equal(cells.counts().dug, 500)
    for _=1,20 do net.time=net.time+10000 assert(cells.tick(net.time)) end
    equal(cells.counts().dug, 500)
    assert(m.files[F.path(1)] and m.files[F.path(1)..".bak"])
    equal(cells.decideRetirement("stale", "allow"), false)
    equal(cells.decideRetirement(request.id, "yes"), false)
    local deleted, remove = {}, m.env.fs.delete
    m.env.fs.delete = function(path) deleted[#deleted+1] = path return remove(path) end
    assert(cells.decideRetirement(request.id, "allow"))
    equal(deleted[1], F.path(1)..".bak")
    equal(deleted[2], F.path(1))
    equal(marked(cells, 1), false)
    equal(marked(cells, 500), true)
    equal(cells.counts().dug, 500-request.count)
    equal(cells.retirement().status, "allowed")
    local reboot = F.setup(m.files)
    equal(marked(reboot, 1), false)
    equal(marked(reboot, 500), true)
    local bytes = 0
    for path, text in pairs(m.files) do if path:match("^so%-data/cells/.+/%d+_0_0") then bytes=bytes+math.max(500,#text) end end
    assert(bytes <= 650000, "remaining section storage "..bytes)
  end)

  test("dug retirement: finish lossless migration before asking to forget anything",function()
    local files, legacy = {}, {}
    for i=0,4095 do legacy[i]=true end
    for i=1,30 do
      files[F.path(i)] = H.encode({schema=1,generation=1,value=legacy})
    end
    local cells, m, net=F.setup(files)
    for _=1,6 do
      assert(cells.tick(net.time))
      equal(cells.retirement(),nil)
      net.time=net.time+10000
    end
    equal(cells.counts().dug,30*4096)
    for i=1,30 do
      for _,suffix in ipairs({"",".bak"}) do
        assert(#m.files[F.path(i)..suffix]<2048)
      end
    end
  end)

  test("dug retirement: keep survives reboot and asks again only after 50 percent growth", function()
    local cells, m, net = F.setup(nil, 500)
    assert(cells.tick(net.time))
    assert(cells.decideRetirement(cells.retirement().id, "keep"))
    equal(cells.retirement().text, "Kept. More server storage (sharding) is a future option.")
    local policy = m.env.SO.store.read("so-data/dug-policy").value
    equal(policy.choice, "keep")
    F.seed(m, 700, 501)
    cells, m, net = F.setup(m.files)
    net.time=net.time+60000
    assert(cells.tick(net.time))
    equal(cells.retirement(), nil)
    equal(cells.counts().dug, 700)
    F.seed(m, 800, 701)
    cells, m, net = F.setup(m.files)
    assert(cells.tick(net.time))
    equal(cells.retirement().status, "pending")
    equal(cells.counts().dug, 800)
  end)

  test("dug retirement: running job areas, open leases, reservations and recovery history stay protected", function()
    local cells, m, net = F.setup(nil, 500)
    local dim = "minecraft:overworld"
    saved(m, "so-data/mine/job", { running=true, dim=dim, home={x=1616,y=64,z=0,facing=1},
      bottom=0, length=16, mode="fast", turtles={}, progress={nextBranch=1,done=0} })
    saved(m, "so-data/lumber/job", { running=true, dim=dim, spots={}, ground=0,
      area={x1=1920,x2=1935,z1=0,z2=15} })
    m.env.SO.mods.mine=m.env.dofile("so-mod-mine.lua")
    m.env.SO.mods.lumber=m.env.dofile("so-mod-lumber.lua")
    local lease=m.env.dofile("so-mod-lease.lua") m.env.SO.mods.lease=lease
    assert(lease.send(8,{{op="forward"}},{pose={dim=dim,x=2080,y=0,z=0}}))
    assert(cells.reserve("holder", 2240, 0, 0))
    cells.rememberWorker(9, {dim=dim,x=2400,y=0,z=0}, {{dim=dim,x=2560,y=0,z=0}})
    assert(cells.tick(net.time))
    local request=assert(cells.retirement())
    -- The worker can be removed from its job, but its journal still contains
    -- the last 32 dug cells until a later report replaces them.
    assert(cells.decideRetirement(request.id,"allow"))
    for _,i in ipairs({1,20,30,40,50,60}) do equal(marked(cells,i),true) end
    equal(marked(cells,80),false)
    local reboot=F.setup(m.files)
    assert(reboot.tick(net.time))
    equal(marked(reboot,60),true)
  end)

  test("dug retirement: approval rechecks reservations and accesses without expanding the offer", function()
    local cells, m, net=F.setup(nil,500)
    assert(cells.tick(net.time))
    local request=cells.retirement()
    assert(cells.reserve("new",1616,0,0))
    equal(marked(cells,2),true)
    assert(cells.decideRetirement(request.id,"allow"))
    equal(marked(cells,1),true)
    equal(marked(cells,2),true)
    equal(marked(cells,3),false)
    equal(cells.counts().dug,500-request.count+2)
    equal(cells.decideRetirement(request.id,"allow"),false)
  end)

  test("dug retirement: uncertain protection blocks requests and later approvals", function()
    local cells, m, net=F.setup(nil,500)
    local lease=m.env.dofile("so-mod-lease.lua") m.env.SO.mods.lease=lease
    lease.handlers.hello({from=2,body={journal={id="unknown",uncertain=true}}})
    assert(cells.tick(net.time))
    equal(cells.retirement(),nil)
    lease.handlers.hello({from=2,body={journal={id="known",pose={x=0,y=0,z=0,f=0}}}})
    net.time=net.time+10000 assert(cells.tick(net.time))
    local request=assert(cells.retirement())
    assert(lease.send(2,{{op="forward"}}))
    assert(cells.decideRetirement(request.id,"allow"))
    equal(cells.counts().dug,500)
    assert(cells.retirement().text:find("0 old areas",1,true))
  end)

  test("dug retirement: failed consent saves and interrupted deletion never authorize extra pruning", function()
    local cells, m, net=F.setup(nil,500)
    assert(cells.tick(net.time))
    local request=cells.retirement()
    local open=m.env.fs.open
    m.env.fs.open=function(path,mode) if path=="so-data/dug-policy.tmp" and mode=="w" then return nil end return open(path,mode) end
    equal(cells.decideRetirement(request.id,"allow"),false)
    equal(cells.counts().dug,500)
    m.env.fs.open=open
    local remove=m.env.fs.delete
    m.env.fs.delete=function(path) if path==F.path(2) then error("power cut") end return remove(path) end
    assert(cells.decideRetirement(request.id,"allow"))
    local reboot=F.setup(m.files)
    equal(marked(reboot,1),false)
    equal(marked(reboot,2),true)
    equal(marked(reboot,3),true)
    equal(reboot.counts().dug,499)
    assert(reboot.tick(net.time))
    equal(reboot.retirement(),nil)
  end)

  test("dug retirement: persisted reads make a section newer than untouched sections", function()
    local cells, m, net=F.setup(nil,500)
    equal(marked(cells,1),true)
    assert(cells.tick(net.time))
    cells, m, net=F.setup(m.files)
    assert(cells.tick(net.time))
    assert(cells.decideRetirement(cells.retirement().id,"allow"))
    equal(marked(cells,1),true)
    equal(marked(cells,2),false)
  end)
end
