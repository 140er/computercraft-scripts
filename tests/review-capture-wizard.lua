local function mark(value)
  local h = assert(fs.open("capture-progress.txt", "w"))
  h.write(value) h.close()
end
local view = ...
local ok, err = pcall(function()
mark("startup")
local Wizard = dofile("wh2-wizard.lua")
local state = { wh2 = { schema = 1 } }
local context = { now = os.epoch("utc"), epoch = 1, config = { enabled = true, operators = {["4"]=true} } }
for _, item in ipairs({"example:raw_tin", "example:raw_silver"}) do
  assert(Wizard.run(state, 1, {op="wh2-unknown", body={wh2=1,item=item,sampleLocationId="input"}}, context).ok)
end
local board = require("wh2-board").open({enabled=true, computerId=4, recipeIndex={
  getUsesOf=function() return {pages=1,recipes={{id="example:tin_smelting"}}} end,
  getRecipe=function() return {id="example:tin_smelting",type="minecraft:smelting",inputs={{item="example:raw_tin",count=1}},outputs={{item="example:tin_ingot",count=1,chance=1}}} end,
}, client={call=function(op, body)
  return Wizard.run(state, 4, {op=op,body=body}, context)
end}})
board.tick()
assert(not board.state.failure, board.state.status)
assert(#board.state.queue == 2, "capture fixture did not load both questions")
mark("loaded")
if view == "answer" then
  board.handle("key", keys.down)
  board.handle("key", keys.enter)
  for _ = 1,4 do board.tick() end
  assert(board.state.view == "answer" and board.state.draft, "capture did not open an answer")
end
assert(not board.state.failure, board.state.status)
board.draw()
mark("drawn")
local width, height = term.getSize()
local report = assert(fs.open("capture-result.json", "w"))
report.write(textutils.serializeJSON({ok=true,fixture="UI only, in-process wizard service",view=board.state.view,
  width=width,height=height,capacity=fs.getCapacity("/"),free=fs.getFreeSpace("/"),
  questions=#board.state.queue,revision=board.state.revision,route=board.state.draft and board.state.draft.route or false}))
report.close()
sleep(1)
term.screenshot()
sleep(1)
os.shutdown()
end)
if not ok then
  local h = assert(fs.open("capture-error.txt", "w"))
  h.write(tostring(err)) h.close()
  error(err, 0)
end
