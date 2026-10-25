local compare=dofile('tests/ui/size-compare.lua')
local _,failed=compare(assert(arg[1]))
os.exit(failed>0 and 1 or 0)
