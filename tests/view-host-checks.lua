return function(test,read,mocks)
  local code=assert(read("hub.lua"):match("^(.-)\nlocal SERVER_PROTOCOL"))
  local hosts={hub=99}
  local function boot(id,enabled,failure)
    local m=mocks.new(false)
    m.files["views.cfg"]=mocks.encode({enabled=enabled})
    m.env.os.getComputerID=function() return id end
    m.env.rednet.host=function(protocol,name)
      assert(protocol=="minearmy")
      if failure then error(failure,0) end
      if hosts[name] and hosts[name]~=id then error("Hostname in use",0) end
      hosts[name]=id
    end
    return pcall(assert(load(code,"=hub.lua","t",m.env)))
  end
  test("enabled view hubs coexist with the canonical hub",function()
    local ok,why=boot(7,true)
    assert(ok,why)
    ok,why=boot(8,true)
    assert(ok,why)
    assert(hosts.hub==99 and hosts["view-7"]==7 and hosts["view-8"]==8)
  end)
  test("view hostname fallback preserves legacy and unrelated errors",function()
    local ok,why=boot(9,false)
    assert(not ok and tostring(why):find("Hostname in use",1,true))
    ok,why=boot(10,true,"Modem unavailable")
    assert(not ok and tostring(why):find("Modem unavailable",1,true))
    assert(not hosts["view-9"] and not hosts["view-10"])
  end)
end
