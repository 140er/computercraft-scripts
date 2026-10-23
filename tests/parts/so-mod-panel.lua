local ui3b, r3 = dofile("tests/ui/ui3b.lua"), dofile("tests/ui/r3pocket.lua")
return function(...) ui3b(...) r3(...) end
