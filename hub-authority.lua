local Hub = dofile("ssot-hub.lua")
local M = {}

local DISK = "hub.authority"
local PROTOCOL = "fleetserver"

function M.decide(here, there)
  return Hub.decide(here, there)
end

function M.issuing(s, holder)
  return Hub.issuing(s, holder)
end

function M.observe(memory, seen)
  memory.hit = memory.hit or 0
  memory.miss = memory.miss or 0
  if seen == nil then
    memory.hit = 0
    memory.miss = memory.miss + 1
    return nil
  end
  if seen ~= memory.id then
    memory.id = seen
    memory.hit = 1
    memory.miss = 0
    return nil
  end
  memory.hit = memory.hit + 1
  memory.miss = 0
  if memory.hit >= 2 then return seen end
  return nil
end

function M.pick(saved, seen)
  if saved then return saved end
  return seen
end

function M.next(here, target, remote)
  if target and not remote then return "wait" end
  return M.decide(here, remote)
end

local function count(map)
  if type(map) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(map) do n = n + 1 end
  return n
end

function M.view(node)
  local st = node.state()
  local authority = type(st.authority) == "table" and st.authority or {}
  local handover = type(st.handover) == "table" and st.handover or {}
  local records = count(st.plans) + count(st.fixtures) + count(st.bots) + count(st.codes) + count(st.leases)
  return {
    phase = handover.phase or "idle",
    kind = authority.kind,
    frozen = authority.frozen == true,
    epoch = authority.epoch or 0,
    holder = authority.holder,
    canIssue = M.issuing(st, node.holder),
    records = records,
    authority = authority,
  }
end

local function failed(result)
  return type(result) ~= "table" or result.ok ~= true
end

function M.migrate(hub, server, opts)
  opts = opts or {}
  local function crashed()
    if not opts.crash then return end
    if type(hub.reboot) == "function" then hub = hub.reboot() end
    if type(server.reboot) == "function" then server = server.reboot() end
  end
  for _ = 1, 64 do
    local action = M.decide(M.view(hub), M.view(server))
    if action == "issue" or action == "follow" or action == "wait" or action == "client" then
      return action, hub, server
    end
    if action == "freeze" then
      if failed(hub.req("hub-freeze")) then return "wait", hub, server end
      crashed()
    elseif action == "export" then
      local cursor, manifest = 0, nil
      repeat
        local page = hub.req("hub-export", { cursor = cursor })
        if failed(page) then return "wait", hub, server end
        crashed()
        manifest = page.manifest
        if failed(server.req("hub-import", { records = page.records, manifest = page.manifest })) then
          return "wait", hub, server
        end
        crashed()
        cursor = page.next
        if page.done then break end
      until false
      local taken = server.req("hub-take")
      if failed(taken) then return "wait", hub, server end
      crashed()
      hub.pendingAdopt = { authority = taken.authority, hash = manifest and manifest.hash }
    elseif action == "adopt" then
      local pending = hub.pendingAdopt
      if type(pending) ~= "table" then
        local saved = hub.state()
        local manifest = type(saved.handover) == "table" and saved.handover.manifest
        pending = { authority = M.view(server).authority, hash = manifest and manifest.hash }
      end
      if failed(hub.req("hub-adopt", { authority = pending.authority, hash = pending.hash })) then
        return "wait", hub, server
      end
      crashed()
    elseif action == "reissue" then
      if failed(server.req("hub-reissue")) then return "wait", hub, server end
      crashed()
      return "client", hub, server
    else
      return "wait", hub, server
    end
  end
  return "wait", hub, server
end

local function readDisk()
  if not (fs and fs.exists and fs.exists(DISK) and fs.open) then return {} end
  local handle = fs.open(DISK, "r")
  if not handle then return {} end
  local ok, parsed = pcall(textutils.unserialize, handle.readAll())
  handle.close()
  if ok and type(parsed) == "table" then return parsed end
  return {}
end

local function writeDisk(disk)
  if not (fs and fs.open and textutils) then return false end
  local body = textutils.serialize(disk)
  if fs.exists("atomic.lua") then
    local ok, atomic = pcall(dofile, "atomic.lua")
    if ok and type(atomic) == "table" and type(atomic.replaceBytes) == "function" then
      local saved = atomic.replaceBytes(DISK, body, function(text)
        local parsedOk, parsed = pcall(textutils.unserialize, text)
        return parsedOk and type(parsed) == "table" and parsed.v == 1
      end)
      if saved then return true end
    end
  end
  local handle = fs.open(DISK, "w")
  if not handle then return false end
  handle.write(body)
  handle.close()
  return true
end

local function message(op, fields, counter, secret)
  local m = {}
  if type(fields) == "table" then
    for key, value in pairs(fields) do m[key] = value end
  end
  m.v, m.type, m.expect, m.op = 1, "ssot", "ssot_reply", op
  m.boot, m.rid, m.counter = "hub-authority", "ha:" .. counter, counter
  m.secret = secret
  return m
end

function M.overlay()
  if not (fs and fs.exists and fs.exists("planner-tools.lua")) then return nil end
  local ok, tools = pcall(dofile, "planner-tools.lua")
  if not ok or type(tools) ~= "table" or type(tools.host) ~= "function" then return nil end
  local api = tools.host("hub")
  local cfg = api.config()
  if type(tools.discover) == "function" then cfg = tools.discover(cfg) end
  local w, h = 51, 19
  if term and term.getSize then w, h = term.getSize() end
  local opts = {
    enabled = cfg.enabled, server = cfg.server, screen = { w = w, h = h },
    origin = cfg.server ~= false and cfg.server or (os and os.getComputerID and os.getComputerID()) or 0,
  }
  if cfg.server == false then opts.hubOnly = true end
  local session, err = api.open(opts)
  if not session then
    return {
      draw = function(target)
        if target and target.write then target.write(tostring(err)) end
      end,
      handle = function(ev, ch) return not (ev == "char" and ch == "q") end,
      tick = function() end,
      close = function() end,
      state = {},
    }
  end
  return {
    draw = function(target) api.draw(session, target) end,
    handle = function(ev, a, b, c)
      if ev == "char" and a == "q" then return false end
      local decoded = api.fromCC(ev, a, b, c)
      if decoded then
        local nextSession = api.input(session, decoded)
        if type(nextSession) == "table" then session = nextSession end
      end
      return true
    end,
    tick = function() end,
    close = function() end,
    state = {},
  }
end

local function copyControllers(raw)
  local controllers = {}
  if type(raw.controllers) == "table" then
    for id, key in pairs(raw.controllers) do controllers[id] = key end
  end
  raw.controllers = controllers
  return raw
end

local function loadConfig()
  local raw = { controllers = {} }
  if fs.exists("ssot.cfg") and fs.exists("atomic.lua") then
    local ok, atomic = pcall(dofile, "atomic.lua")
    if ok and type(atomic) == "table" and type(atomic.read) == "function" then
      local parsed = atomic.read("ssot.cfg")
      if type(parsed) == "table" then
        for key, value in pairs(parsed) do raw[key] = value end
        copyControllers(raw)
      end
    end
  end
  return raw
end

function M.open()
  local function idle()
    while true do os.pullEvent("fleet_auth_idle") end
  end
  local armed = settings and settings.get and settings.get("hub.authority") == true
  if not armed or not (rednet and os and fs) then
    return { overlay = M.overlay, loop = idle }
  end
  local disk = readDisk()
  local memory = { id = disk.server, hit = disk.server and 2 or 0, miss = 0 }
  local hosted = false
  local serving = false
  local store
  local secret

  local function selfId()
    return os.getComputerID()
  end

  local function remember(serverId)
    if disk.server == serverId and disk.v == 1 then return end
    disk.v = 1
    disk.server = serverId
    writeDisk(disk)
    memory.id = serverId
    memory.hit = 2
  end

  local function bump()
    disk.counter = (disk.counter or 0) + 1
    disk.v = 1
    writeDisk(disk)
    return disk.counter
  end

  local function callRemote(id, op, fields)
    local counter = bump()
    local m = message(op, fields, counter, secret)
    local pending = { id = id, rid = m.rid }
    rednet.send(id, m, PROTOCOL)
    local timer = os.startTimer(2)
    while true do
      local ev, a, b, c = os.pullEvent()
      if ev == "rednet_message" and a == id and c == PROTOCOL and type(b) == "table" and b.rid == m.rid then
        os.cancelTimer(timer)
        return b
      elseif ev == "timer" and a == timer then
        return nil
      end
    end
  end

  local function ensure()
    if store or not fs.exists("ssot.lua") then return store end
    local openedOk, opened = pcall(function()
      local SSOT = dofile("ssot.lua")
      local raw = loadConfig()
      local id = tostring(selfId())
      if type(raw.controllers[id]) ~= "string" or #raw.controllers[id] < 16 then
        raw.controllers[id] = disk.secret or "hub-authority-local"
        disk.secret = raw.controllers[id]
        disk.v = 1
        writeDisk(disk)
      end
      secret = raw.controllers[id]
      raw.profile = "hub"
      raw.hubProfile = true
      raw.holder = selfId()
      local cfg = SSOT.config(raw)
      cfg.profile = "hub"
      cfg.holder = selfId()
      return SSOT.open(cfg)
    end)
    if openedOk and type(opened) == "table" then store = opened end
    return store
  end

  local function hubNode()
    return {
      holder = selfId(),
      state = function() return store.state() end,
      req = function(op, fields)
        local counter = bump()
        return store.handle(selfId(), message(op, fields, counter, secret))
      end,
    }
  end

  local function serverNode(id)
    local shadow = {
      authority = { v = 1, holder = id, epoch = 0, kind = "server", frozen = false, since = 0 },
      handover = { phase = "idle" },
      plans = {}, fixtures = {}, bots = {}, codes = {}, leases = {},
    }
    local node = { holder = id, state = function() return shadow end }
    function node.req(op, fields)
      local result = callRemote(id, op, fields)
      if type(result) == "table" and result.ok then
        if op == "authority" and type(result.authority) == "table" then
          shadow.authority = result.authority
          shadow.handover.phase = result.phase or shadow.handover.phase
          node.holder = result.authority.holder or node.holder
        elseif op == "hub-import" and type(fields) == "table" then
          shadow.handover.phase = "importing"
          shadow.handover.manifest = fields.manifest
        elseif op == "hub-take" and type(result.authority) == "table" then
          shadow.authority = result.authority
          shadow.handover.phase = "taken"
          node.holder = result.authority.holder or node.holder
        end
      end
      return result
    end
    return node
  end

  local function lookup()
    if hosted and rednet.unhost then
      pcall(rednet.unhost, PROTOCOL, "server")
      hosted = false
    end
    local id = rednet.lookup(PROTOCOL, "server")
    if id == selfId() then return nil end
    return id
  end

  local function host(on)
    if on and not hosted and rednet.host then
      pcall(rednet.host, PROTOCOL, "server")
      hosted = true
    elseif not on and hosted and rednet.unhost then
      pcall(rednet.unhost, PROTOCOL, "server")
      hosted = false
    end
  end

  local function step()
    if disk.done then
      serving = false
      host(false)
      return
    end
    local seen = lookup()
    local stable = M.observe(memory, seen)
    local saved = disk.server
    if store then
      local phase = M.view(hubNode()).phase
      if phase == "frozen" or phase == "client" then saved = saved or memory.id end
    end
    local target = M.pick(saved, stable)
    local remoteNode = target and serverNode(target) or nil
    local remote
    if remoteNode and secret then
      local reply = remoteNode.req("authority")
      if type(reply) == "table" and reply.ok then remote = M.view(remoteNode) end
    elseif remoteNode and not secret then
      ensure()
      if secret then
        local reply = remoteNode.req("authority")
        if type(reply) == "table" and reply.ok then remote = M.view(remoteNode) end
      end
    end
    local resume = fs.exists("ssot.state") or fs.exists("ssot.state.bak") or fs.exists("ssot.state.tmp")
    if not store and (resume or (target == nil and (memory.miss or 0) >= 2) or (remote and remote.epoch == 0)) then
      ensure()
    end
    local here
    if store then
      here = M.view(hubNode())
    else
      here = { phase = "idle", kind = "hub", epoch = 1, frozen = false, canIssue = true, records = 0 }
    end
    local action = M.next(here, target, remote)
    if action == "issue" then
      if not store then ensure() end
      serving = store ~= nil
      host(serving)
      return
    end
    serving = false
    host(false)
    if not store or not remoteNode or not remote then return end
    if action == "freeze" or action == "export" or action == "adopt" or action == "reissue" then
      remember(target)
      if M.migrate(hubNode(), remoteNode) == "client" then
        disk.done = true
        disk.v = 1
        writeDisk(disk)
      end
    end
  end

  return {
    overlay = M.overlay,
    loop = function()
      local timer = os.startTimer(3)
      while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "timer" and a == timer then
          pcall(step)
          timer = os.startTimer(3)
        elseif serving and ev == "rednet_message" and c == PROTOCOL and type(b) == "table"
          and b.type == "ssot" and store then
          local reply = store.handle(a, b)
          if type(reply) == "table" then rednet.send(a, reply, PROTOCOL) end
        end
      end
    end,
  }
end

return M
