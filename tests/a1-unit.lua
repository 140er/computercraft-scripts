-- Loaded by tests/run.lua. The sandbox driver loads tests/a1-checks.lua itself.
return function(test, equal)
  dofile("tests/a1-checks.lua")(test, equal)
end
