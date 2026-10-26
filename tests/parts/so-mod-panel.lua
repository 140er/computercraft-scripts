local ui3b, r3, ra2, b5u = dofile("tests/ui/ui3b.lua"), dofile("tests/ui/r3pocket.lua"), dofile("tests/ui/panel.lua"), dofile("tests/ui/panel-delivery.lua")
return function(...) ui3b(...) r3(...) ra2(...) b5u(...) end
