local P = dofile("probe.lua")
local _ENV = setmetatable({}, {__index = _ENV})
require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
package.path = "vendor/?.lua;vendor/?/init.lua;" .. package.path
local config = require("ccryptolib.config")
config.usePeripherals(false)
sleep(0)
local random = require("ccryptolib.random")
random.init("P0 public benchmark seed. Never use for pairing.")
sleep(0)
local b3 = require("ccryptolib.blake3")
local sha = require("ccryptolib.sha256")
sleep(0)
local x = require("ccryptolib.x25519")
sleep(0)
local ed = require("ccryptolib.ed25519")
sleep(0)
local key = ("k"):rep(32)
local sk = P.unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
local pk = P.unhex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
local esk = P.unhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
local epk = P.unhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
local sig = P.unhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" ..
  "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
local cases = {}
for _, size in ipairs({1024, 8192, 37888}) do
  local payload = ("p"):rep(size)
  cases[#cases + 1] = {name = "blake3-keyed-" .. size, bytes = size, run = function()
    local out = b3.digestKeyed(key, payload)
    assert(#out == 32)
    return P.hex(out)
  end}
end
for _, size in ipairs({963, 12288, 37888}) do
  local payload = ("p"):rep(size)
  cases[#cases + 1] = {name = "sha256-section-" .. size, bytes = size, run = function()
    local out = sha.digest(payload)
    assert(#out == 32)
    return P.hex(out)
  end}
end
cases[#cases + 1] = {name = "x25519-keygen", bytes = 32, run = function()
  assert(x.publicKey(sk) == pk, "RFC 7748 public key mismatch")
  return "RFC 7748 public key matched"
end}
cases[#cases + 1] = {name = "x25519-exchange", bytes = 64, run = function()
  local out = x.exchange(
    P.unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
    P.unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"))
  assert(P.hex(out) == "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
  return "RFC 7748 exchange matched"
end}
cases[#cases + 1] = {name = "ed25519-sign", bytes = 0, run = function()
  local out = ed.sign(esk, epk, "")
  assert(#out == 64)
  return P.hex(out)
end, check = function(out) assert(ed.verify(epk, "", P.unhex(out)), "generated signature rejected") end}
cases[#cases + 1] = {name = "ed25519-verify", bytes = 0, run = function()
  assert(ed.verify(epk, "", sig), "RFC 8032 verification failed")
  return true
end}
cases[#cases + 1] = {name = "ed25519-reject", bytes = 1, run = function()
  assert(not ed.verify(epk, "x", sig), "modified message accepted")
  return "modified message rejected"
end}
local manifest = ("m"):rep(8192)
local manifestSig = ed.sign(esk, epk, manifest)
sleep(0)
cases[#cases + 1] = {name = "ed25519-sign-8192", bytes = 8192, run = function()
  local out = ed.sign(esk, epk, manifest)
  assert(#out == 64)
  return P.hex(out)
end, check = function(out) assert(ed.verify(epk, manifest, P.unhex(out)), "generated manifest signature rejected") end}
cases[#cases + 1] = {name = "ed25519-verify-8192", bytes = 8192, run = function()
  assert(ed.verify(epk, manifest, manifestSig))
  return true
end}
assert(P.hex(sha.digest("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
assert(P.hex(b3.digest("")) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
assert(P.hex(b3.digestKeyed("whats the Elvish word for friend", "")) ==
  "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26")
local result = {v = 1, runtime = _HOST, computer = os.getComputerID(), softwareOnly = true,
  watchdogMs = 7000, seed = "public deterministic fixture, no entropy claim",
  samples = {}, successful = 0, failed = 0, rejections = 0}
for round = 1, 5 do
  for _, case in ipairs(cases) do
    P.save("crypto-progress", {round = round, next = case.name})
    sleep(0)
    local sample = P.measure(case.run)
    if sample.ok and case.check then
      sleep(0)
      local checked, why = pcall(case.check, sample.value)
      sample.outputChecked = checked
      if not checked then sample.ok, sample.error = false, tostring(why) end
    end
    sample.name, sample.bytes, sample.round = case.name, case.bytes, round
    result.samples[#result.samples + 1] = sample
    if sample.ok then
      result.successful = result.successful + 1
      if case.name == "ed25519-reject" then result.rejections = result.rejections + 1 end
    else result.failed = result.failed + 1 end
    result.ok = result.failed == 0
    P.save("crypto", result)
    P.save(case.name, sample)
  end
end
return result
