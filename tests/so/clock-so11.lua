local suite = dofile("tests/so/so11.lua")
return function(test, equal)
  suite(function(name, fn) test(name .. " at 4x", function() return fn() end) end, equal, nil, nil, 4)
end
