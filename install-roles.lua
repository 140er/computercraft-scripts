-- Role bundles for the installer. One list per machine. The mirror role (H4a)
-- serves these bundles. This module does not call the network, the terminal,
-- or GPS.

local M = {}

local KIT = {
  "install.lua", "update.lua", "install-roles.lua",
  "install-core.lua", "install-keys.lua", "install-shell.lua",
  "install-touch.lua",
}

local ROLES = {
  { id = "miner", name = "Mining turtle", on = "turtle", boot = "miner",
    files = { "miner.lua", "atomic.lua", "b1-nav.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h4c.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "mining.lua", "nav.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "position.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "view-source.lua", "warehouse-tasks.lua", "warehouse.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-wizard.lua" } },
  { id = "hub", name = "Mine Army hub", on = "computer", boot = "hub",
    files = { "hub.lua", "alpha-boot.lua", "ar-hud.lua", "ar-planner.lua", "atomic.lua", "chat-control.lua", "dead.lua", "directview.lua", "enrol.lua", "fleetview.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/h4b2_b1.lua", "lib/stubs/h4b2_h1.lua", "lib/stubs/h4b2_h4b1.lua", "lib/stubs/h4c_dep.lua", "lib/stubs/h4d_dep.lua", "lib/stubs/layout_dep.lua", "lib/stubs/t2_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-hub.lua", "planner-ops.lua", "planner-settings.lua", "planner-tools.lua", "plug.lua", "roles.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "shelf.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "storage-buffer.lua", "storage-host.lua", "storage-ledger.lua", "storage-peer.lua", "storage-view.lua", "strata.lua", "update.lua", "view-scene.lua", "view-source.lua", "views.lua", "warehouse-tasks.lua", "wh2-ar.lua", "wh2-board.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dev.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-recipes.lua", "wh2-wizard-adapter.lua", "wh2-wizard-host.lua", "wh2-wizard.lua" } },
  { id = "relay", name = "Radio relay", on = "computer", boot = "relay",
    files = { "relay.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "roomsorter", name = "Storage Room turtle", on = "turtle", boot = "roomsorter",
    files = { "roomsorter.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "nav.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "position.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "store.lua", "update.lua", "warehouse-tasks.lua", "warehouse.lua", "wh2-board.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard-adapter.lua", "wh2-wizard-host.lua", "wh2-wizard.lua" } },
  { id = "roomclient", name = "Storage order computer", on = "computer",
    files = { "roomsorter.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "nav.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "position.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "store.lua", "update.lua", "warehouse-tasks.lua", "warehouse.lua", "wh2-board.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard-adapter.lua", "wh2-wizard-host.lua", "wh2-wizard.lua" } },
  { id = "sorter", name = "Sorter & Smelter", on = "any", boot = "sorter",
    files = { "sorter.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "nav.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "position.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "store.lua", "update.lua", "warehouse-tasks.lua", "warehouse.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "lumber", name = "Lumberjack", on = "turtle", boot = "lumber",
    files = { "lumber.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "farmer", name = "Farmer", on = "turtle", boot = "farmer",
    files = { "farmer.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "lava", name = "Lava runner", on = "turtle", boot = "lava",
    files = { "lava.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "builder", name = "Builder", on = "turtle", boot = "builder",
    files = { "builder.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "buddy", name = "Buddy", on = "turtle", boot = "buddy",
    files = { "buddy.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "factory", name = "Turtle factory", on = "turtle", boot = "factory",
    files = { "factory.lua", "atomic.lua", "b1-nav.lua", "craft.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h4c.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/craft_dep.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "miner.lua", "mining.lua", "nav.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "position.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "view-source.lua", "warehouse-tasks.lua", "warehouse.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "gpshost", name = "GPS host", on = "computer",
    files = { "gpshost.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "server", name = "Fleet server", on = "computer", boot = "server",
    files = { "server.lua", "alpha-boot.lua", "ar-hud.lua", "ar-planner.lua", "atomic.lua", "chat-control.lua", "dead.lua", "enrol.lua", "fleetview.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/h4b2_b1.lua", "lib/stubs/h4b2_h1.lua", "lib/stubs/h4b2_h4b1.lua", "lib/stubs/h4c_dep.lua", "lib/stubs/h4d_dep.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-host.lua", "planner-map.lua", "planner-ops.lua", "planner-settings.lua", "planner-view.lua", "plug.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "storage-buffer.lua", "storage-host.lua", "storage-ledger.lua", "storage-peer.lua", "storage-view.lua", "strata.lua", "update.lua", "warehouse-tasks.lua", "wh2-ar.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dev.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-recipes.lua", "wh2-wizard.lua" } },
  { id = "panel", name = "Pocket panel", on = "pocket", boot = "panel",
    files = { "panel.lua", "atomic.lua", "dead.lua", "enrol.lua", "fleetview.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "lib/stubs/t2_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-panel.lua", "planner-settings.lua", "planner-tools.lua", "plug.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "wh2-ar.lua", "wh2-board.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dev.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard-adapter.lua", "wh2-wizard-host.lua", "wh2-wizard.lua" } },
  { id = "smartmine", name = "Simple tunnel miner", on = "turtle",
    files = { "smartmine.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-program.lua", "wh2-wizard.lua" } },
  { id = "store", name = "SSOT warehouse turtle", on = "turtle",
    files = { "store.lua", "atomic.lua", "dead.lua", "enrol.lua", "journal.lua", "lease.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_w1.lua", "lib/stubs/layout_dep.lua", "mapsection.lua", "mapstore.lua", "mine-tasks.lua", "nav.lua", "planner-core.lua", "planner-enrol.lua", "planner-ops.lua", "planner-settings.lua", "plug.lua", "position.lua", "s1_b1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_t1.lua", "ssot-client.lua", "ssot-hub.lua", "ssot.lua", "update.lua", "warehouse-tasks.lua", "warehouse.lua", "wh2-client.lua", "wh2-craft.lua", "wh2-dispatch.lua", "wh2-fleet.lua", "wh2-layout.lua", "wh2-locations.lua", "wh2-wizard.lua" } },
}

M.kit = KIT

function M.hash(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

function M.list()
  local out = {}
  for i, role in ipairs(ROLES) do out[i] = role end
  return out
end

function M.get(id)
  for _, role in ipairs(ROLES) do if role.id == id then return role end end
end

function M.fits(role, kind)
  return role.on == kind or (role.on == "any" and kind ~= "pocket")
end

function M.catalog()
  local out = {}
  for _, role in ipairs(ROLES) do
    out[#out + 1] = { id = role.id, name = role.name, on = role.on, boot = role.boot or false }
  end
  return out
end

function M.files(id)
  local role = M.get(id)
  if not role then return nil end
  local out = {}
  for i, name in ipairs(role.files) do out[i] = name end
  return out
end

function M.manifest(id, hashes)
  local names = M.files(id)
  if not names then return nil end
  local lines = {}
  for _, name in ipairs(names) do
    lines[#lines + 1] = name .. " " .. (hashes and hashes[name] or "")
  end
  return M.hash(table.concat(lines, "\n"))
end

function M.updateFiles(id)
  local names = M.files(id)
  if not names then return nil end
  local seen, out = {}, {}
  local function add(name)
    if not seen[name] then seen[name] = true out[#out + 1] = name end
  end
  for _, name in ipairs(names) do add(name) end
  for _, name in ipairs(KIT) do add(name) end
  table.sort(out)
  return out
end

function M.keep(id)
  local set = { ["startup.lua"] = true }
  for _, name in ipairs(M.updateFiles(id) or {}) do set[name] = true end
  return set
end

function M.pruneNames(id, names)
  local keep = M.keep(id)
  local drop = {}
  for _, name in ipairs(names) do
    if type(name) == "string" and name:match("%.lua$") and not keep[name] then
      drop[#drop + 1] = name
    end
  end
  table.sort(drop)
  return drop
end

local function literal(v, seen)
  local kind = type(v)
  if kind == "string" then return string.format("%q", v) end
  if kind == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("bad number") end
    if v % 1 == 0 and math.abs(v) < 2 ^ 53 then return string.format("%.0f", v) end
    return string.format("%.17g", v)
  end
  if kind == "boolean" then return v and "true" or "false" end
  if kind ~= "table" then error("bad value") end
  if seen[v] then error("cycle") end
  seen[v] = true
  local keys = {}
  for key in pairs(v) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  local parts = {}
  for _, key in ipairs(keys) do
    local shown
    if type(key) == "string" and key:match("^[%a_][%w_]*$") then shown = key
    else shown = "[" .. literal(key, seen) .. "]" end
    parts[#parts + 1] = shown .. "=" .. literal(v[key], seen)
  end
  seen[v] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.literal(v)
  return literal(v, {})
end

local function cost(n) return math.max(500, n) end

-- bundle[name] is a string, or { text = string, expect = hash }.
-- free is a byte count or "unlimited". A new file costs at least 500 bytes.
function M.apply(fsapi, root, id, bundle, free)
  local role = M.get(id)
  if not role then return nil, "unknown_role" end
  local function path(name)
    if root == nil or root == "" or root == "/" then return name end
    return root .. "/" .. name
  end
  local function listRoot()
    if root == nil or root == "" or root == "/" then return fsapi.list("/") end
    return fsapi.list(root)
  end
  local names = listRoot()
  local disk = {}
  local function readText(where)
    if not fsapi.exists(where) or (fsapi.isDir and fsapi.isDir(where)) then return nil end
    local h = fsapi.open(where, "r")
    local text = h.readAll()
    h.close()
    return text
  end
  for _, name in ipairs(names) do
    local text = readText(path(name))
    if text then disk[name] = text end
  end
  for _, name in ipairs(role.files) do
    local text = readText(path(name))
    if text then disk[name] = text end
  end
  local incoming = {}
  for name, body in pairs(bundle) do
    local text, expect = body, nil
    if type(body) == "table" then text, expect = body.text, body.expect end
    if type(text) ~= "string" then return nil, "hash_mismatch" end
    local hash = M.hash(text)
    if expect and expect ~= hash then return nil, "hash_mismatch" end
    incoming[name] = { text = text, hash = hash }
  end
  local writes, need = {}, 0
  for _, name in ipairs(role.files) do
    local got = incoming[name]
    if not got then return nil, "missing" end
    if disk[name] == nil then
      writes[#writes + 1] = name
      need = need + cost(#got.text)
    elseif M.hash(disk[name]) ~= got.hash then
      writes[#writes + 1] = name
    end
  end
  if type(free) == "number" and need > free then return nil, "disk_full" end
  local function ensureDir(dir)
    if not dir or dir == "" or not fsapi.makeDir then return end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then ensureDir(parent) end
    if not fsapi.exists(dir) then fsapi.makeDir(dir) end
  end
  for _, name in ipairs(writes) do
    local where = path(name)
    ensureDir(where:match("^(.*)/[^/]+$"))
    local tmp = where .. ".new"
    local h = assert(fsapi.open(tmp, "w"), "open failed")
    h.write(incoming[name].text)
    h.close()
    if fsapi.exists(where) then fsapi.delete(where) end
    fsapi.move(tmp, where)
  end
  local drop = M.pruneNames(id, names)
  for _, name in ipairs(drop) do fsapi.delete(path(name)) end
  local hashes = {}
  for _, name in ipairs(role.files) do hashes[name] = incoming[name].hash end
  return { wrote = writes, dropped = drop, manifest = M.manifest(id, hashes) }
end

return M
