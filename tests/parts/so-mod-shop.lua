local ui2c, touch = dofile("tests/ui/ui2c.lua"), dofile("tests/ui/shop-touch.lua")
return function(test, equal, ...) ui2c(test, equal, ...) touch.run(test, equal) end
