local P = dofile("probe.lua")
local _ENV = setmetatable({}, {__index = _ENV})
require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
package.path = "vendor/?.lua;vendor/?/init.lua;" .. package.path
local result = {v = 1, runtime = _HOST, sources = {}, ok = true}
local function fresh(hardware)
  package.loaded["ccryptolib.random"] = nil
  package.loaded["ccryptolib.internal.hw"] = nil
  require("ccryptolib.config").usePeripherals(hardware)
  return require("ccryptolib.random")
end
local cases = {
  {name = "uninitialized", run = function()
    local r = fresh(false)
    local ok = pcall(r.random, 32)
    assert(not ok, "uninitialized generator accepted")
    return {rejected = true}
  end},
  {name = "supplied-seed", run = function()
    local r = fresh(false)
    r.init("P0 public benchmark seed. Never use for pairing.")
    local bytes = r.random(32)
    assert(#bytes == 32 and r.isInit())
    return {generatedBytes = #bytes, entropy = "caller supplied; fixture has no secret entropy"}
  end},
  {name = "vm-timing", run = function()
    local r = fresh(false)
    r.initWithTiming()
    local bytes = r.random(32)
    assert(#bytes == 32 and r.isInit())
    return {generatedBytes = #bytes, entropy = "VM instruction timing; upstream warns this is riskier"}
  end},
  {name = "krist-http", run = function()
    local r = fresh(false)
    local h = assert(http.post("https://krist.dev/ws/start", "", nil, false))
    local data = textutils.unserializeJSON(h.readAll())
    h.close()
    assert(data and type(data.url) == "string", "Krist response has no token URL")
    r.init(data.url)
    local socket = assert(http.websocket(data.url))
    socket.close()
    assert(#r.random(32) == 32 and r.isInit())
    return {generatedBytes = 32, entropy = "Krist socket token received over HTTPS", tokenSaved = false}
  end},
  {name = "crypto-peripheral", run = function()
    local names = {peripheral.find("cryptographic_accelerator")}
    assert(#names > 0, "no cryptographic_accelerator attached")
    local r = fresh(true)
    r.initAuto()
    assert(#r.random(32) == 32 and r.isInit())
    return {generatedBytes = 32, attached = #names, entropy = "Classic Peripherals randomBytes"}
  end},
}
for _, case in ipairs(cases) do
  P.save("randomness-progress", {next = case.name})
  sleep(0)
  local row = P.measure(case.run)
  row.name = case.name
  result.sources[#result.sources + 1] = row
  P.save("randomness-" .. case.name, row)
  P.save("randomness", result)
end
return result
