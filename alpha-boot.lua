-- Boots the alpha features that default on. Explicit false in the host
-- config stays off. A missing peripheral prints one line and returns.

local M = {}

local function say(text)
  if type(print) == "function" then pcall(print, text) end
end

local function exists(path)
  return type(fs) == "table" and type(fs.exists) == "function" and fs.exists(path) == true
end

local function wanted(value)
  return value == nil or value == true
end

local function findWireless()
  if type(peripheral) ~= "table" or type(peripheral.find) ~= "function" then return nil end
  local ok, found = pcall(function()
    return peripheral.find("modem", function(_, modem)
      return type(modem) == "table" and type(modem.isWireless) == "function" and modem.isWireless() == true
    end)
  end)
  if ok then return found end
  return nil
end

function M.goggles(ctx)
  ctx = ctx or {}
  if ctx.noted or ctx.enabled == false or ctx.ar then return end
  say("No AR controller. Goggles stay blank.")
end

function M.gpu(cfg)
  if type(cfg) ~= "table" or cfg.enabled == false then return end
  local present = false
  if type(cfg.gpu) == "string" and type(peripheral) == "table" and type(peripheral.isPresent) == "function" then
    local ok, yes = pcall(peripheral.isPresent, cfg.gpu)
    present = ok and yes == true
  end
  if not present then say("No GPU. The text view stays on.") end
end

function M.planner(ctx)
  ctx = ctx or {}
  local cfg = type(ctx.cfg) == "table" and ctx.cfg or {}
  if not wanted(cfg.arPlanner) then return nil end
  if not exists("ar-planner.lua") then
    say("AR planner did not start.")
    return nil
  end
  local ok, planner = pcall(dofile, "ar-planner.lua")
  if not ok or type(planner) ~= "table" or type(planner.open) ~= "function" then
    say("AR planner did not start.")
    return nil
  end
  local detector
  if type(peripheral) == "table" and type(peripheral.find) == "function" then
    local fine, found = pcall(peripheral.find, "player_detector")
    if fine then detector = found end
  end
  if detector == nil then
    say("No player detector. AR planner is not drawing.")
    return nil
  end
  local session, why = planner.open({
    cfg = cfg,
    detector = detector,
    dimension = type(ctx.dimension) == "string" and ctx.dimension or "minecraft:overworld",
    ar = ctx.ar,
  })
  if not session then
    say("AR planner did not start.")
    return nil, why
  end
  return session
end

function M.strata(ctx)
  ctx = ctx or {}
  local cfg = type(ctx.cfg) == "table" and ctx.cfg or {}
  if not wanted(cfg.strata) then return nil end
  for _, path in ipairs({
    "strata.lua", "lib/stubs/h4b2_h1.lua", "lib/stubs/h4b2_h4b1.lua", "lib/stubs/h4b2_b1.lua",
  }) do
    if not exists(path) then
      say("Strata did not start.")
      return nil
    end
  end
  local ok, store = pcall(dofile, "strata.lua")
  if not ok or type(store) ~= "table" or type(store.new) ~= "function" then
    say("Strata did not start.")
    return nil
  end
  local flag = {}
  if cfg.strata ~= nil then flag.strata = cfg.strata end
  local made, err = pcall(store.new, flag)
  if not made then
    say("Strata did not start.")
    return nil, err
  end
  return err
end

function M.storage(ctx)
  ctx = ctx or {}
  local cfg = type(ctx.cfg) == "table" and ctx.cfg or {}
  if not wanted(cfg.storageHost) then return nil end
  if not findWireless() then say("No ender modem. Storage host keeps local books.") end
  if not exists("storage-host.lua") then
    say("Storage host did not start.")
    return nil
  end
  local ok, hostMod = pcall(dofile, "storage-host.lua")
  if not ok or type(hostMod) ~= "table" or type(hostMod.create) ~= "function" then
    say("Storage host did not start.")
    return nil
  end
  local host, err = hostMod.create({ enabled = true, fs = fs })
  if not host then
    say("Storage host did not start.")
    return nil, err
  end
  return host
end

function M.peers(ctx)
  ctx = ctx or {}
  local cfg = type(ctx.cfg) == "table" and ctx.cfg or {}
  if not wanted(cfg.peerStorage) then return nil end
  if not exists("storage-peer.lua") then
    say("Peer storage did not start.")
    return nil
  end
  local ok, peer = pcall(dofile, "storage-peer.lua")
  if not ok or type(peer) ~= "table" or type(peer.server) ~= "function" then
    say("Peer storage did not start.")
    return nil
  end
  local mac
  if exists("lib/stubs/h4d_dep.lua") then
    local loaded, deps = pcall(dofile, "lib/stubs/h4d_dep.lua")
    if loaded and type(deps) == "table" and type(deps.h1) == "table" and type(deps.h1.mac) == "function" then
      local made, fn = pcall(deps.h1.mac)
      if made and type(fn) == "function" then mac = fn end
    end
  end
  local path = exists("disk/h4d-storage.key") and "disk/h4d-storage.key" or nil
  if type(mac) ~= "function" then say("No storage mac. Peer storage is not sealing.") end
  if not path then say("No floppy key. Peer storage is not sealing.") end
  if type(mac) ~= "function" or not path then return nil end
  local serverOk, server = pcall(peer.server, {
    peerStorage = true, mac = mac, macKind = "blake3",
  })
  if not serverOk or type(server) ~= "table" then
    say("Peer storage did not start.")
    return nil
  end
  local exported = server.exportKey(fs, path)
  if not exported then
    say("No floppy key. Peer storage is not sealing.")
    return nil
  end
  local enabled = server.enable()
  if not enabled then say("Peer storage did not start.") return nil end
  return server
end

function M.hub(ctx)
  ctx = ctx or {}
  M.goggles(ctx)
  return { planner = M.planner(ctx) }
end

function M.server(ctx)
  ctx = ctx or {}
  M.goggles(ctx)
  return {
    planner = M.planner(ctx),
    strata = M.strata(ctx),
    storage = M.storage(ctx),
    peers = M.peers(ctx),
  }
end

return M
