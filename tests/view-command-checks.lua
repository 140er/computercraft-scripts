return function(test,read,mocks)
  local function fixture(enabled)
    local dim="minecraft:overworld"
    local m=mocks.miner({home={x=0,y=65,z=0},facing=1,spine=2,viewsControl=enabled,
      ssot={server=0,dimension=dim,secret="test-secret-123456"},
      nav={bounds={min={dim=dim,x=-8,y=60,z=-8},max={dim=dim,x=8,y=70,z=8}}}})
    m.env.dofile=function(path) return assert(loadfile(path,"t",m.env))() end
    local source=assert(read("miner.lua"):match("^(.*)\nopenModem%(%)"))
    local api=assert(load(source.."\nreturn {C=C,cfg=cfg,pos=pos,listener=listener}","=miner.lua","t",m.env))()
    local calls={}
    api.C.nav={
      pose=function() return {dim=dim,x=m.pos.x,y=m.pos.y,z=m.pos.z,h=1} end,
      stopped=function() return false end,
      control=function(kind,epoch,cid)
        if kind~="view_move" or epoch~=1 or type(cid)~="number" then return false,"invalid command" end
        if calls.cid and cid<=calls.cid then return false,"stale command" end
        calls.cid=cid return true
      end,
    }
    api.C.viewReady=true
    local packet={type="view_move",target=m.env.os.getComputerID(),point={dim=dim,x=1,y=65,z=0},
      commandAuth="test-secret-123456",commandEpoch="1",cid=1}
    return api,m,packet,calls
  end
  test("view movement is opt-in and rejects forged, distant and invalid commands",function()
    local api,m,p,calls=fixture(false)
    assert(type(api.C.queueViewMove)=="function","view movement queue missing")
    assert(not api.C.queueViewMove(0,p) and not calls.cid)
    api.cfg.viewsControl=true
    assert(not api.C.queueViewMove(9,p))
    p.commandAuth="forged" assert(not api.C.queueViewMove(0,p))
    p.commandAuth="test-secret-123456"
    p.point.x=9 assert(not api.C.queueViewMove(0,p))
    p.point.x=0/0 assert(not api.C.queueViewMove(0,p))
    p.point.x=1 p.point.dim="minecraft:the_nether" assert(not api.C.queueViewMove(0,p))
    p.point.dim="minecraft:overworld" p.point.y=71 assert(not api.C.queueViewMove(0,p))
    p.point.y=65
    assert(not calls.cid and not api.C.viewPending)
    assert(api.C.queueViewMove(0,p))
    p.point.x=6
    assert(api.C.viewPending.x==1,"queued coordinates alias packet")
    assert(m.pos.x==0,"listener performed physical movement")
    api.C.viewPending=nil
    assert(not api.C.queueViewMove(0,p),"replayed move accepted")
  end)
  test("view movement rejects another command while its worker owns navigation",function()
    local api,m,p,calls=fixture(true)
    api.C.viewBusy=true
    assert(not api.C.queueViewMove(0,p) and not calls.cid)
    api.C.viewBusy=false api.C.viewReady=false
    assert(not api.C.queueViewMove(0,p) and not calls.cid)
    api.C.viewReady=true api.C.estop=true
    assert(not api.C.queueViewMove(0,p) and not calls.cid)
  end)
end
