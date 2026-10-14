-- buddy.lua - an AI companion turtle (CC: Tweaked)
--
-- Chat with your turtle and let it do small jobs around your base: walk somewhere,
-- look at blocks, pick up or drop items, place or break a block, come back home.
-- It is not a miner: big jobs are left to the Mine Army.
--
-- The brain is any OpenAI-style chat API with tool calling: your own model server
-- (vLLM, SGLang, Ollama, LM Studio, ...) or xAI's Grok.
--
-- One-time setup (see README):
--   buddy server <url> [url2 ...]  use your own model server(s), e.g. buddy server http://my-gpu-box:8000
--                                  more than one: the next is used when the first can't be reached
--   buddy server grok              use xAI's Grok instead (needs: buddy key <your xAI API key>)
--   buddy key <key>                saves an API key in api.key on this turtle (never in the repo)
--   buddy setup [name]             names the turtle, writes startup.lua, this spot = home
-- Then:
--   buddy                 start chatting (type at the turtle, or in game chat with a chat box)
--   buddy model <id>      pick the model (auto = the first one the server offers)
--   buddy models          list the models the server offers
--   buddy think on|off    let a reasoning model think before answering (default off = fast)
--   buddy home            after putting it back on its home spot by hand: reset position
--   buddy update          fetch the latest buddy.lua from GitHub
--
-- While chatting: /reset forgets the conversation, /quit stops.
-- Needs: http enabled in the CC config. Optional: a Chat Box (Advanced Peripherals)
-- equipped on the turtle, so you can talk to it in Minecraft chat ("buddy, come here").

local CFG_FILE, STATE_FILE, KEY_FILE = "buddy.cfg", "buddy.state", "api.key"
local MEMORY_FILE = "buddy.memory"  -- remembered places and notes
local GROK = "https://api.x.ai/v1/"

local MAX_STEPS = 16     -- blocks per move command
local MAX_HISTORY = 30   -- messages kept in the conversation
local TIMEOUT = 60       -- seconds to wait for an answer (CC allows at most 60)

-- Blocks it refuses to break, whatever it is told
local PROTECTED = { "chest", "barrel", "shulker", "computer", "turtle", "monitor", "modem",
  "furnace", "smoker", "hopper", "spawner", "bed", "door", "sign", "beacon", "anvil" }

-- ---------------------------------------------------------------- config / state

local function readFile(path)
  if not fs.exists(path) then return nil end
  local fh = fs.open(path, "r")
  local text = fh.readAll()
  fh.close()
  return text
end

local function writeFile(path, text)
  local fh = fs.open(path, "w")
  fh.write(text)
  fh.close()
end

local cfg = {
  name = os.getComputerLabel() or "Buddy",
  servers = { GROK },   -- OpenAI-style API base URLs, tried in this order
  model = "grok-4",     -- "auto" = the first model the server offers
  range = 32,          -- never further than this many blocks from home (any axis)
  personality = "Cheerful, a little cheeky, loves helping out.",
  think = false,        -- own server: let reasoning models (GLM, Qwen, ...) think first. Slower.
}
do
  local saved = textutils.unserialize(readFile(CFG_FILE) or "")
  if type(saved) == "table" then for k, v in pairs(saved) do cfg[k] = v end end
end
local function saveCfg() writeFile(CFG_FILE, textutils.serialize(cfg)) end

-- Position relative to home: x = right, z = forward, y = up, as seen from home.
-- facing 0 = the way it faced at home, 1 = right of that, 2 = back, 3 = left.
-- path = the blocks walked from home (loops cut out), so go_home can retrace them.
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }
local FACING_NAME = { [0] = "the way you face at home", "right of that", "back towards where you came from", "left of that" }

local state = { facing = 0, path = { { x = 0, y = 0, z = 0 } } }
do
  local saved = textutils.unserialize(readFile(STATE_FILE) or "")
  if type(saved) == "table" and saved.path and #saved.path > 0 then state = saved end
end
local function saveState() writeFile(STATE_FILE, textutils.serialize(state)) end

-- places[name] = { path = path from home, facing = ..., note = ... }; notes = things to remember
local memory = { places = {}, notes = {} }
do
  local saved = textutils.unserialize(readFile(MEMORY_FILE) or "")
  if type(saved) == "table" then
    memory.places = saved.places or {}
    memory.notes = saved.notes or {}
  end
end
local function saveMemory() writeFile(MEMORY_FILE, textutils.serialize(memory)) end
local function pos() return state.path[#state.path] end

-- ---------------------------------------------------------------- text helpers

-- The screen and CC's JSON only do plain ASCII
local function ascii(s)
  s = tostring(s or "")
  s = s:gsub("\226\128[\152\153]", "'"):gsub("\226\128[\156\157]", '"')
       :gsub("\226\128[\147\148]", "-"):gsub("\226\128\166", "...")
  return (s:gsub("[\128-\255]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function short(name) return (tostring(name or "?"):gsub("^minecraft:", "")) end

local function say(who, text, colour)
  if term.isColour() then term.setTextColour(colour or colours.white) end
  write(who .. ": ")
  if term.isColour() then term.setTextColour(colours.white) end
  print(text)
end

-- ---------------------------------------------------------------- movement

local function turn(right)
  if right then turtle.turnRight() else turtle.turnLeft() end
  state.facing = (state.facing + (right and 1 or 3)) % 4
  saveState()
end

local function face(f)
  local diff = (f - state.facing) % 4
  if diff == 1 then turn(true)
  elseif diff == 2 then turn(true); turn(true)
  elseif diff == 3 then turn(false) end
end

local function outOfRange(p)
  return math.abs(p.x) > cfg.range or math.abs(p.y) > cfg.range or math.abs(p.z) > cfg.range
end

-- Record a step to p; walking back onto the path cuts the loop out
local function arrive(p)
  for i = #state.path, 1, -1 do
    local q = state.path[i]
    if q.x == p.x and q.y == p.y and q.z == p.z then
      for j = #state.path, i + 1, -1 do state.path[j] = nil end
      saveState()
      return
    end
  end
  state.path[#state.path + 1] = p
  saveState()
end

local function inspectName(dir)
  local fn = ({ front = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown })[dir]
  local ok, data = fn()
  if ok then return short(data.name) end
  return nil
end

-- One step: "forward", "back", "up" or "down". Waits a moment if something
-- (a player, a mob) is in the way. Returns true, or false and a reason.
local function step(dir)
  if turtle.getFuelLevel() == 0 then return false, "out of fuel" end
  local p = pos()
  local dx, dy, dz = 0, 0, 0
  if dir == "up" then dy = 1
  elseif dir == "down" then dy = -1
  elseif dir == "forward" then dx, dz = DX[state.facing], DZ[state.facing]
  else dx, dz = -DX[state.facing], -DZ[state.facing] end
  local np = { x = p.x + dx, y = p.y + dy, z = p.z + dz }
  if outOfRange(np) then return false, "that is further than " .. cfg.range .. " blocks from home" end
  local move = ({ forward = turtle.forward, back = turtle.back, up = turtle.up, down = turtle.down })[dir]
  for _ = 1, 3 do
    if move() then arrive(np); return true end
    local look = ({ forward = "front", up = "up", down = "down" })[dir]
    local block = look and inspectName(look)
    if block then return false, "blocked by " .. block end
    sleep(1) -- probably a player or mob, give it a moment
  end
  return false, "something is in the way"
end

local function where()
  local p = pos()
  local parts = {}
  if p.z ~= 0 then parts[#parts + 1] = math.abs(p.z) .. (p.z > 0 and " forward" or " back") end
  if p.x ~= 0 then parts[#parts + 1] = math.abs(p.x) .. (p.x > 0 and " right" or " left") end
  if p.y ~= 0 then parts[#parts + 1] = math.abs(p.y) .. (p.y > 0 and " up" or " down") end
  local at = #parts == 0 and "at home" or (table.concat(parts, ", ") .. " from home")
  return at .. ", facing " .. FACING_NAME[state.facing]
end

local function samePos(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

-- One step to the neighbouring block t
local function stepTo(t)
  local p = pos()
  if t.y > p.y then return step("up") end
  if t.y < p.y then return step("down") end
  local f
  for i = 0, 3 do if DX[i] == t.x - p.x and DZ[i] == t.z - p.z then f = i end end
  if not f then return false, "lost track of the way, put me back home by hand and run: buddy home" end
  if f == (state.facing + 2) % 4 and turtle.back() then
    arrive({ x = t.x, y = t.y, z = t.z })
    return true
  end
  face(f)
  return step("forward")
end

-- Walk to a spot given by its path from home: back along the current path to
-- where the two paths split, then out along the target path. Only known-clear blocks.
local function goTo(target, facing, label)
  local k = 1
  while k < #state.path and k < #target and samePos(state.path[k + 1], target[k + 1]) do k = k + 1 end
  while #state.path > k do
    local ok, why = stepTo(state.path[#state.path - 1])
    if not ok then return false, "stuck on the way to " .. label .. " (" .. why .. "), " .. where() end
  end
  for i = k + 1, #target do
    local ok, why = stepTo(target[i])
    if not ok then return false, "stuck on the way to " .. label .. " (" .. why .. "), " .. where() end
  end
  face(facing or 0)
  return true, "arrived at " .. label
end

local function goHome() return goTo({ { x = 0, y = 0, z = 0 } }, 0, "home") end

-- ---------------------------------------------------------------- inventory

local function findSlots(item)
  local slots = {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and (not item or d.name:find(item:lower(), 1, true)) then slots[#slots + 1] = s end
  end
  return slots
end

local function inventory()
  local lines = {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then lines[#lines + 1] = "slot " .. s .. ": " .. d.count .. "x " .. short(d.name) end
  end
  return #lines == 0 and "inventory is empty" or table.concat(lines, "\n")
end

local function fuelText()
  local f = turtle.getFuelLevel()
  return f == "unlimited" and "unlimited" or tostring(f)
end

-- ---------------------------------------------------------------- tools for the model

-- a fresh table each time: CC's JSON refuses a table that appears twice
local function SIDE() return { type = "string", enum = { "front", "up", "down" }, description = "front = the block in front of you" } end
local SIDE_FN = {
  dig = { front = turtle.dig, up = turtle.digUp, down = turtle.digDown },
  place = { front = turtle.place, up = turtle.placeUp, down = turtle.placeDown },
  drop = { front = turtle.drop, up = turtle.dropUp, down = turtle.dropDown },
  suck = { front = turtle.suck, up = turtle.suckUp, down = turtle.suckDown },
}

local tools, toolFns = {}, {}
local function tool(name, description, props, required, fn)
  local params = { type = "object", properties = props or {} }
  if required then params.required = required end
  tools[#tools + 1] = { type = "function", ["function"] = { name = name, description = description, parameters = params } }
  toolFns[name] = fn
end

tool("move", "Move in a straight line. Stops at the first block in the way. Does not dig.", {
  direction = { type = "string", enum = { "forward", "back", "up", "down" } },
  blocks = { type = "integer", description = "how many blocks, 1-" .. MAX_STEPS },
}, { "direction" }, function(a)
  local n = math.max(1, math.min(MAX_STEPS, math.floor(tonumber(a.blocks) or 1)))
  for i = 1, n do
    local ok, why = step(a.direction)
    if not ok then return "moved " .. (i - 1) .. " of " .. n .. ", then " .. why .. ". Now " .. where() end
  end
  return "moved " .. n .. ". Now " .. where()
end)

tool("turn", "Turn on the spot.", {
  direction = { type = "string", enum = { "left", "right", "around" } },
}, { "direction" }, function(a)
  if a.direction == "around" then turn(true); turn(true) else turn(a.direction == "right") end
  return "turned. Now " .. where()
end)

tool("look", "See which blocks are in front of, above and below you.", nil, nil, function()
  local out = {}
  for _, dir in ipairs({ "front", "up", "down" }) do
    out[#out + 1] = dir .. ": " .. (inspectName(dir) or "air")
  end
  return table.concat(out, ", ")
end)

tool("status", "Your fuel, where you are compared to home, and what you carry.", nil, nil, function()
  return "fuel " .. fuelText() .. ", " .. where() .. "\n" .. inventory()
end)

tool("dig", "Break one block next to you and pick it up. Only when the player asked for it.", {
  side = SIDE(),
}, { "side" }, function(a)
  local block = inspectName(a.side)
  if not block then return "there is nothing there" end
  for _, p in ipairs(PROTECTED) do
    if block:find(p, 1, true) then return "refused: " .. block .. " looks like part of the base" end
  end
  local ok, why = SIDE_FN.dig[a.side]()
  return ok and ("broke " .. block) or ("could not break " .. block .. ": " .. tostring(why))
end)

tool("place", "Place a block from your inventory next to you.", {
  side = SIDE(),
  item = { type = "string", description = "part of the item name, e.g. torch or cobblestone. Leave out for the selected slot." },
}, { "side" }, function(a)
  if a.item then
    local slots = findSlots(a.item)
    if #slots == 0 then return "you have no " .. a.item end
    turtle.select(slots[1])
  end
  local d = turtle.getItemDetail()
  if not d then return "nothing selected to place" end
  local ok, why = SIDE_FN.place[a.side]()
  return ok and ("placed " .. short(d.name)) or ("could not place " .. short(d.name) .. ": " .. tostring(why))
end)

tool("drop", "Drop items: into a chest/container on that side, or on the ground.", {
  side = SIDE(),
  item = { type = "string", description = "part of the item name; leave out to drop everything" },
  count = { type = "integer", description = "how many; leave out for all of them" },
}, { "side" }, function(a)
  local want = tonumber(a.count)
  local dropped = 0
  for _, s in ipairs(findSlots(a.item)) do
    if want and dropped >= want then break end
    turtle.select(s)
    local before = turtle.getItemCount(s)
    SIDE_FN.drop[a.side](want and math.min(before, want - dropped) or nil)
    dropped = dropped + before - turtle.getItemCount(s)
  end
  turtle.select(1)
  if dropped == 0 then return a.item and ("dropped nothing (no " .. a.item .. " or the container is full)") or "dropped nothing" end
  return "dropped " .. dropped .. " items"
end)

local function itemTotal()
  local n = 0
  for s = 1, 16 do n = n + turtle.getItemCount(s) end
  return n
end

tool("pick_up", "Take items from a chest/container on that side, or pick up items lying there.", {
  side = SIDE(),
  count = { type = "integer", description = "max items; leave out to take as much as you can carry" },
}, { "side" }, function(a)
  local want = tonumber(a.count)
  local before = itemTotal()
  turtle.select(1)
  while true do
    local got = itemTotal() - before
    if want and got >= want then break end
    if not SIDE_FN.suck[a.side](want and math.max(1, math.min(64, want - got)) or nil) then break end
  end
  local got = itemTotal() - before
  if got == 0 then return "nothing to pick up there (or my inventory is full)" end
  local full = #findSlots() == 16
  return "picked up " .. got .. " items" .. (full and ", my inventory is full now" or "")
end)

tool("refuel", "Burn fuel items you carry (coal, charcoal, planks, lava bucket, ...).", {
  item = { type = "string", description = "part of the item name; leave out to try anything" },
  count = { type = "integer", description = "how many items to burn; leave out for one stack" },
}, nil, function(a)
  local before = turtle.getFuelLevel()
  for _, s in ipairs(findSlots(a.item)) do
    turtle.select(s)
    if turtle.refuel(0) then
      turtle.refuel(tonumber(a.count))
      break
    end
  end
  turtle.select(1)
  return "fuel " .. tostring(before) .. " -> " .. fuelText()
end)

tool("go_home", "Walk back home along the way you came.", nil, nil, function()
  local _, msg = goHome()
  return msg
end)

tool("set_home", "Make the spot where you are now (and your current facing) your new home. "
  .. "This forgets all remembered places, because they are stored as routes from home.", nil, nil, function()
  state = { facing = 0, path = { { x = 0, y = 0, z = 0 } } }
  saveState()
  memory.places = {}
  saveMemory()
  return "this is home now (places forgotten)"
end)

tool("remember_place", "Remember the spot where you are now, and the way you face, under a name "
  .. "(e.g. 'sorter drop chest'). Stand so the thing it is about is in front of, above or below you.", {
  name = { type = "string" },
  note = { type = "string", description = "optional, e.g. 'chest is below me'" },
}, { "name" }, function(a)
  local name = ascii(a.name):lower()
  if name == "" then return "a place needs a name" end
  local path = {}
  for i, p in ipairs(state.path) do path[i] = { x = p.x, y = p.y, z = p.z } end
  memory.places[name] = { path = path, facing = state.facing, note = a.note and ascii(a.note) or nil }
  saveMemory()
  return "remembered '" .. name .. "' (" .. where() .. ")"
end)

tool("go_to", "Walk to a remembered place (or 'home') along routes you have walked before, "
  .. "and face the way you faced when you remembered it.", {
  place = { type = "string" },
}, { "place" }, function(a)
  local name = ascii(a.place):lower()
  if name == "home" then local _, msg = goHome() return msg end
  local spot = memory.places[name]
  if not spot then
    for n, p in pairs(memory.places) do if n:find(name, 1, true) then name, spot = n, p break end end
  end
  if not spot then return "I don't know a place called '" .. a.place .. "'" end
  local _, msg = goTo(spot.path, spot.facing, name)
  return msg .. (spot.note and (". Note: " .. spot.note) or "")
end)

tool("forget_place", "Forget a remembered place.", { name = { type = "string" } }, { "name" }, function(a)
  local name = ascii(a.name):lower()
  if not memory.places[name] then return "no place called '" .. name .. "'" end
  memory.places[name] = nil
  saveMemory()
  return "forgot '" .. name .. "'"
end)

tool("remember", "Write down something to remember for later (stays after a restart), "
  .. "e.g. 'the miner chests are the 4 chests north of home'.", {
  note = { type = "string" },
}, { "note" }, function(a)
  local note = ascii(a.note)
  if note == "" then return "nothing to remember" end
  table.insert(memory.notes, note)
  while #memory.notes > 40 do table.remove(memory.notes, 1) end
  saveMemory()
  return "noted"
end)

tool("forget", "Forget notes that contain this text.", { text = { type = "string" } }, { "text" }, function(a)
  local text, gone = ascii(a.text):lower(), 0
  for i = #memory.notes, 1, -1 do
    if memory.notes[i]:lower():find(text, 1, true) then table.remove(memory.notes, i); gone = gone + 1 end
  end
  saveMemory()
  return "forgot " .. gone .. " note(s)"
end)

if turtle.craft then
  tool("craft", "Craft with the items in your inventory laid out like a crafting grid (slots 1-3, 5-7, 9-11).", {
    count = { type = "integer", description = "how many times, leave out for as many as possible" },
  }, nil, function(a)
    local ok, why = turtle.craft(tonumber(a.count))
    return ok and "crafted" or ("could not craft: " .. tostring(why))
  end)
end

local function runTool(name, argText)
  local fn = toolFns[name]
  if not fn then return "unknown tool " .. tostring(name) end
  local args = textutils.unserializeJSON(argText or "{}") or {}
  local ok, result = pcall(fn, args)
  if not ok then return "error: " .. tostring(result) end
  return tostring(result)
end

-- ---------------------------------------------------------------- model API

local function apiKey()
  local key = readFile(KEY_FILE)
  return key and key:gsub("%s+", "") or nil
end

local function usesGrok()
  for _, url in ipairs(cfg.servers) do if url == GROK then return true end end
  return false
end

-- "my-gpu-box:8000" -> "http://my-gpu-box:8000/v1/"
local function baseUrl(url)
  if not url:find("^https?://") then url = "http://" .. url end
  url = url:gsub("/+$", "")
  if not url:find("/v1$") then url = url .. "/v1" end
  return url .. "/"
end

local function requestOne(server, method, path, body)
  local headers = { ["Content-Type"] = "application/json" }
  local key = apiKey()
  if key then headers["Authorization"] = "Bearer " .. key end
  local req = { url = server .. path, method = method, body = body, headers = headers, timeout = TIMEOUT }
  local res, err, errRes
  if body then res, err, errRes = http.post(req) else res, err, errRes = http.get(req) end
  if not res then
    if not errRes then -- no answer at all: unreachable, blocked or timed out
      if tostring(err):find("not permitted") then
        err = err .. " (allow this address in the http rules of computercraft-server.toml, see README)"
      end
      return nil, ascii(err), true
    end
    local detail = errRes.readAll() or ""
    errRes.close()
    local data = textutils.unserializeJSON(detail)
    if type(data) == "table" then detail = data.error and (data.error.message or data.error) or data.message or detail end
    return nil, ascii(tostring(err) .. " " .. tostring(detail)):sub(1, 300)
  end
  local text = res.readAll()
  res.close()
  local data = textutils.unserializeJSON(text)
  if not data then data = textutils.unserializeJSON(text:match("^%s*(.-)%s*$")) end
  if not data and text:find("^%s*data:") then data = { streamed = text } end
  if not data then return nil, "could not read the server's answer" end
  return data
end

-- A streamed answer ("data: {...}" lines) glued back together into one message.
-- Streaming keeps the connection busy while the model thinks, so CC's
-- 60 second limit (time without any data) is only hit when the server stalls.
local function joinStream(text)
  local msg, calls = { content = "" }, {}
  for line in text:gmatch("[^\n]+") do
    local json = line:match("^data:%s*(.+)")
    local chunk = json and json ~= "[DONE]" and textutils.unserializeJSON(json)
    local delta = chunk and chunk.choices and chunk.choices[1] and chunk.choices[1].delta
    if delta then
      if type(delta.content) == "string" then msg.content = msg.content .. delta.content end
      for _, tc in ipairs(delta.tool_calls or {}) do
        local i = (tonumber(tc.index) or #calls) + 1
        local call = calls[i]
        if not call then
          call = { id = tc.id, type = "function", ["function"] = { name = "", arguments = "" } }
          calls[i] = call
        end
        if tc.id then call.id = tc.id end
        local fn = tc["function"] or {}
        if fn.name then call["function"].name = call["function"].name .. fn.name end
        if fn.arguments then call["function"].arguments = call["function"].arguments .. fn.arguments end
      end
    end
  end
  local list = {}
  for i = 1, #calls + 8 do if calls[i] then list[#list + 1] = calls[i] end end
  for i, call in ipairs(list) do
    call.id = call.id or ("call" .. i)
    if call["function"].arguments == "" then call["function"].arguments = "{}" end
  end
  if #list > 0 then msg.tool_calls = list end
  return msg
end

-- Tries the servers in order; one that answers moves to the front for next time
local servers = {}
for i, url in ipairs(cfg.servers) do servers[i] = url end

local function request(method, path, body)
  local errs = {}
  for i, server in ipairs(servers) do
    local data, err, unreachable = requestOne(server, method, path, body)
    if data or not unreachable then
      if data and i > 1 then table.insert(servers, 1, table.remove(servers, i)) end
      return data, err
    end
    errs[#errs + 1] = server .. ": " .. err
  end
  return nil, table.concat(errs, "; ")
end

local model = cfg.model
local function resolveModel()
  if model ~= "auto" then return model end
  local data, err = request("GET", "models")
  if not data then return nil, err end
  local first = data.data and data.data[1]
  if not first then return nil, "the server offers no models" end
  model = first.id
  return model
end

-- Reasoning models may put their thinking in the answer
local function stripThinking(s)
  s = tostring(s or ""):gsub("<think>.-</think>", "")
  return (s:gsub("^.*</think>", ""))
end

local function placeList()
  local names = {}
  for name, p in pairs(memory.places) do names[#names + 1] = name .. (p.note and (" (" .. p.note .. ")") or "") end
  table.sort(names)
  return #names == 0 and "none yet" or table.concat(names, "; ")
end

local function noteList()
  return #memory.notes == 0 and "none" or ("\n- " .. table.concat(memory.notes, "\n- "))
end

local function systemPrompt(who)
  return ("You are %s, a small robot (a ComputerCraft turtle) who lives in %s's Minecraft base as a companion. "
    .. "You chat with them and do small jobs around the base with your tools. %s\n"
    .. "Rules:\n"
    .. "- Your replies show on a tiny screen and in game chat: 1-3 short sentences, plain text, no markdown, no emoji.\n"
    .. "- You are not a miner. Politely turn down big jobs (mining, tunnels, clearing areas, building whole structures) "
    .. "and suggest the mining turtles instead.\n"
    .. "- Only break or place blocks when the player asks for it. Never break chests, machines or other base blocks.\n"
    .. "- Directions are your own: forward, back, left, right, up, down. You cannot see the player; "
    .. "if they say 'come here', ask where they are relative to you. Use look when unsure what is around you.\n"
    .. "- You stay within %d blocks of home. go_home walks back the way you came.\n"
    .. "- When the player shows you a spot (a chest, a machine, a door), remember it with remember_place, "
    .. "and later use go_to to get there. Use remember for other facts worth keeping.\n"
    .. "- Moving items between chests: go_to the first, pick_up, go_to the second, drop. "
    .. "Repeat until the first is empty if your inventory filled up.\n"
    .. "- After doing something, say briefly what you did or what went wrong.\n"
    .. "Places you know: %s\n"
    .. "Notes: %s\n"
    .. "Right now: Minecraft time %s on day %d, fuel %s, %s.")
    :format(cfg.name, who or "the player", cfg.personality, cfg.range,
      placeList(), noteList(), textutils.formatTime(os.time(), true), os.day(), fuelText(), where())
end

local history = {}

local function trimHistory()
  while #history > MAX_HISTORY do
    table.remove(history, 1)
    -- never start in the middle of a tool exchange
    while history[1] and history[1].role ~= "user" do table.remove(history, 1) end
  end
end

-- Send one player message to the model, run the tools it asks for, return its answer
local function chat(text, who, onAction)
  local useModel, err = resolveModel()
  if not useModel then return nil, err end
  local start = #history
  history[#history + 1] = { role = "user", content = ascii(text) }
  while true do -- keeps going until the model answers without asking for tools
    local messages = { { role = "system", content = systemPrompt(who) } }
    for _, m in ipairs(history) do messages[#messages + 1] = m end
    local data
    local body = { model = useModel, messages = messages, tools = tools, stream = true }
    if not usesGrok() and not cfg.think then body.chat_template_kwargs = { enable_thinking = false } end
    data, err = request("POST", "chat/completions", textutils.serializeJSON(body))
    if not data then
      -- forget this message and what came of it, so a retry starts clean
      for i = #history, start + 1, -1 do history[i] = nil end
      if err:lower():find("model") then err = err .. " (try: buddy models)" end
      return nil, err
    end
    local msg = data.streamed and joinStream(data.streamed)
      or (data.choices and data.choices[1] and data.choices[1].message)
    if not msg then return nil, "empty answer from the model" end
    local calls = msg.tool_calls
    if not calls or #calls == 0 then
      local answer = ascii(stripThinking(msg.content))
      history[#history + 1] = { role = "assistant", content = answer }
      trimHistory()
      return answer
    end
    history[#history + 1] = { role = "assistant", content = ascii(stripThinking(msg.content)), tool_calls = calls }
    for _, call in ipairs(calls) do
      local fn = call["function"] or {}
      if onAction then onAction(fn.name, fn.arguments) end
      history[#history + 1] = { role = "tool", tool_call_id = call.id, content = ascii(runTool(fn.name, fn.arguments)) }
    end
  end
end

-- ---------------------------------------------------------------- commands

local args = { ... }
local cmd = args[1]

if args[1] == "update" then
  -- latest version from GitHub (update.lua does the work, fetched here if missing)
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
  end
  shell.run("update")
  return
end

if cmd == "server" then
  if args[2] == "grok" then
    cfg.servers, cfg.model = { GROK }, "grok-4"
  elseif args[2] then
    cfg.servers = {}
    for i = 2, #args do cfg.servers[#cfg.servers + 1] = baseUrl(args[i]) end
    cfg.model = "auto"
  end
  saveCfg()
  for _, url in ipairs(cfg.servers) do print("Server: " .. url) end
  print("Model: " .. cfg.model)
  return
elseif cmd == "key" then
  if not args[2] then print("Usage: buddy key <API key>") return end
  writeFile(KEY_FILE, args[2])
  print("Key saved in " .. KEY_FILE .. ". Keep that file to yourself.")
  return
elseif cmd == "setup" then
  if args[2] then cfg.name = args[2] end
  os.setComputerLabel(cfg.name)
  saveCfg()
  state = { facing = 0, path = { { x = 0, y = 0, z = 0 } } }
  saveState()
  memory.places = {} -- they were routes from the old home
  saveMemory()
  writeFile("startup.lua", 'shell.run("buddy")\n')
  print(cfg.name .. " is set up and this spot is home. It starts by itself from now on.")
  if usesGrok() and not apiKey() then print("Still needed: buddy server <your model server>, or buddy key <xAI key> for Grok") end
  return
elseif cmd == "home" then
  state = { facing = 0, path = { { x = 0, y = 0, z = 0 } } }
  saveState()
  print("Position reset: home, facing the home direction.")
  return
elseif cmd == "model" then
  if args[2] then cfg.model = args[2]; saveCfg() end
  print("Model: " .. cfg.model)
  return
elseif cmd == "think" then
  if args[2] then cfg.think = args[2] == "on"; saveCfg() end
  print("Thinking: " .. (cfg.think and "on (smarter, slower)" or "off (fast)"))
  return
elseif cmd == "name" and args[2] then
  cfg.name = args[2]
  os.setComputerLabel(cfg.name)
  saveCfg()
  print("Name: " .. cfg.name)
  return
end

if not http then print("http is disabled in the ComputerCraft config.") return end
if usesGrok() and not apiKey() then
  print("No model server set. Your own: buddy server http://<host>:<port>")
  print("Or Grok: get a key at console.x.ai, then buddy key <key>")
  return
end

if cmd == "models" then
  local data, err = request("GET", "models")
  if not data then print("Error: " .. err) return end
  for _, m in ipairs(data.data or {}) do print(m.id) end
  print("Pick one with: buddy model <id>")
  return
end

-- ---------------------------------------------------------------- main loop

local chatBox = peripheral.find("chatBox")
local busy = false

local function handle(text, who, reply)
  if busy then reply("Hang on, I'm still busy with the last thing.") return end
  busy = true
  local ok, answer, err = pcall(chat, text, who, function(name, argText)
    if term.isColour() then term.setTextColour(colours.grey) end
    print("  [" .. tostring(name) .. " " .. ascii(argText or "") .. "]")
    if term.isColour() then term.setTextColour(colours.white) end
  end)
  busy = false
  if not ok then reply("Oops, something broke: " .. ascii(answer)) return end
  if not answer then reply("I can't think right now: " .. err) return end
  reply(answer)
end

local function terminalLoop()
  while true do
    if term.isColour() then term.setTextColour(colours.yellow) end
    write("> ")
    if term.isColour() then term.setTextColour(colours.white) end
    local line = read()
    if line == "/quit" then return
    elseif line == "/reset" then history = {}; print("(conversation forgotten)")
    elseif line:find("%S") then
      handle(line, nil, function(text) say(cfg.name, text, colours.lime) end)
    end
  end
end

local function chatLoop()
  if not chatBox then while true do os.pullEvent("chat_never") end end
  local trigger = cfg.name:lower()
  while true do
    local _, user, message = os.pullEvent("chat")
    local text = tostring(message or "")
    -- only messages that start with its name: "buddy, come here" / "Buddy: hi"
    if text:lower():sub(1, #trigger) == trigger then
      text = text:sub(#trigger + 1):gsub("^[%s,:!]+", "")
      say(user, text, colours.lightBlue)
      handle(text ~= "" and text or "hi", user, function(answer)
        say(cfg.name, answer, colours.lime)
        -- game chat cuts long lines and has a cooldown
        for i = 1, #answer, 200 do
          pcall(chatBox.sendMessage, answer:sub(i, i + 199), cfg.name)
          sleep(1.1)
        end
      end)
    end
  end
end

-- Pocket control panel (panel.lua): chat, status and quick trips over a wireless or
-- ender modem. Without a modem these just wait forever.
local netJobs = {}
local function radioLoop()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then while true do os.pullEvent("buddy_never") end end
  rednet.open(peripheral.getName(modem))
  rednet.host("buddy", cfg.name)
  while true do
    local id, m = rednet.receive("buddy")
    if type(m) == "table" then
      local job = (m.cmd == "chat" and type(m.text) == "string" and m.text:find("%S"))
        or m.cmd == "home" or m.cmd == "update" or (m.cmd == "goto" and memory.places[m.place or ""])
      if job then
        netJobs[#netJobs + 1] = { id = id, m = m }
        os.queueEvent("buddy_net")
      end
      local places = {}
      for name in pairs(memory.places) do places[#places + 1] = name end
      table.sort(places)
      local p = pos()
      rednet.send(id, { type = "buddy_state", rid = m.rid, name = cfg.name, model = cfg.model,
        fuel = turtle.getFuelLevel(), busy = busy or #netJobs > 0, places = places,
        pos = { x = p.x, y = p.y, z = p.z } }, "buddy")
    end
  end
end

local function radioJobLoop()
  while true do
    os.pullEvent("buddy_net")
    while #netJobs > 0 do
      local job = table.remove(netJobs, 1)
      local function answer(text)
        say(cfg.name, text, colours.lime)
        rednet.send(job.id, { type = "buddy_answer", text = text }, "buddy")
      end
      if job.m.cmd == "chat" then
        say("Pocket", job.m.text, colours.lightBlue)
        handle(job.m.text, nil, answer)
      elseif job.m.cmd == "update" then
        -- panel's Update all: finish the current job first, then fetch the latest buddy.lua
        while busy do sleep(1) end
        answer("Updating from GitHub...")
        shell.run("update") -- reboots when there's a new version
        answer("Already up to date.")
      elseif busy then
        answer("Hang on, I'm still busy with the last thing.")
      else
        busy = true
        local place = job.m.cmd == "goto" and memory.places[job.m.place]
        local ok, ok2, msg = pcall(function()
          if place then return goTo(place.path, place.facing, job.m.place) end
          return goHome()
        end)
        busy = false
        answer(ok and (ok2 and ("Done: " .. msg) or ("Hmm, " .. tostring(msg))) or ("Oops: " .. ascii(ok2)))
      end
    end
  end
end

term.clear()
term.setCursorPos(1, 1)
print(cfg.name .. " (model: " .. cfg.model .. ") - fuel " .. fuelText())
print(chatBox and ("Talk here, or in chat: \"" .. cfg.name .. ", ...\"") or "Talk to me here.")
print("/reset forgets the chat, /quit stops.")
parallel.waitForAny(terminalLoop, chatLoop, radioLoop, radioJobLoop)
