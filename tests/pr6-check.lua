local function read(p) local f=assert(io.open(p));local s=f:read('*a');f:close();return s end
for _,file in ipairs({'tests/chat-checks.lua','tests/install-checks.lua'}) do
 dofile(file)(function(n,f) f();print('PASS '..n) end,read,dofile('tests/mocks.lua'))
end
