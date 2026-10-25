local dependencies = {
  'tests/ui/size-coverage.json',
  'tests/ui/size-coverage.py',
  'tests/ui/size-render.lua',
  'tests/ui/size-compare.lua',
  'tests/ui/size-actions.lua',
  'tests/ui/size-scene.txt',
  'tests/evidence/ui-size-coverage.txt',
  'tests/ui/size-adapters.lua',
  'docs/ui/schematic/ar.py',
  'docs/ui/schematic/cc.py',
  'docs/ui/schematic/ccfont.py',
  'docs/ui/schematic/jobs.py',
  'docs/ui/schematic/kit.py',
  'docs/ui/schematic/mapdraw.py',
  'docs/ui/schematic/mapscreen.py',
  'docs/ui/schematic/other.py',
  'docs/ui/schematic/panel.py',
  'docs/ui/schematic/pocket.py',
  'docs/ui/schematic/scene.py',
  'docs/ui/schematic/screens.py',
  'docs/ui/schematic/shop.py',
  'docs/ui/schematic/size_adapters.py',
  'docs/ui/schematic/status.py',
  'docs/ui/schematic/system.py',
}
return function(test, equal)
  dofile('tests/ui/size-interactions.lua')(function(name, fn)
    test(name, function() return fn() end)
  end, equal)
  test('UB-28 independent twins agree at required sizes and layout boundaries', function()
    for _,path in ipairs(dependencies) do
      if path~='tests/evidence/ui-size-coverage.txt' then local file=assert(io.open(path,'rb')) file:close() end
    end
    local python = package.config:byte(1)==92 and 'python' or 'python3'
    local allowed,ok,why,code=pcall(os.execute,python..' tests/ui/size-coverage.py')
    if not allowed then
      assert(tostring(ok):find('part tests cannot start host processes',1,true),ok)
      local _,failed=dofile('tests/ui/size-compare.lua')('tests/evidence/ui-size-coverage.txt')
      assert(failed==0,'size-coverage parity failed')
    else
      assert(ok==true or ok==0,'size-coverage failed '..tostring(why)..' '..tostring(code))
    end
  end)
end
