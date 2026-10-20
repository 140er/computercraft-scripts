-- sandbox-verified with CraftOS-PC 2.8.3. These are counterexamples, not fixes.
local results = {}
local function record(k, v) results[k] = v end
local anchor = { x = 0, y = 64, z = 0 }
local ok, err = pcall(textutils.serialize, { anchors = { hub = anchor }, turtles = { [12] = { hub = anchor } } })
assert(not ok and tostring(err):find('repeated'))
record('doc2_shared_anchor_error', tostring(err))
local circular = {}; circular.self = circular
assert(not pcall(textutils.serialize, circular))
assert(not pcall(textutils.serialize, { fn = function() end }))
-- Doc2 requestMoveLock's final response handling, timeout counterexample.
local function response(res)
  if res and res.type == 'LOCK_RESPONSE' then return res.granted, res.reason end
  return true -- Fallback if packet dropped
end
assert(response(nil) == true)
record('doc2_timeout_grants_move', true)
local cells = {}
for x = 1, 1000 do
  cells[x .. ',64,0'] = { x = x, y = 64, z = 0, state = 'AIR', name = 'minecraft:air', updatedBy = 12, ts = 1792450000000 }
end
record('1000_cells_default_bytes', #textutils.serialize(cells))
record('1000_cells_compact_bytes', #textutils.serialize(cells, { compact = true }))
local out = assert(fs.open('review-results.txt', 'w'))
out.write(textutils.serialize(results)); out.close()
print('Review probes PASS')
sleep(1)
os.shutdown()
