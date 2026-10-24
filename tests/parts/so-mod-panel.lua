local ui3b, r3, ra2 = dofile("tests/ui/ui3b.lua"), dofile("tests/ui/r3pocket.lua"), dofile("tests/ui/panel.lua")
return function(...) ui3b(...) r3(...) ra2(...) end
