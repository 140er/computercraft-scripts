-- buddy.lua - a Grok-powered companion turtle (CC: Tweaked)
--
-- Chat with your turtle and let it do small jobs around your base: walk somewhere,
-- look at blocks, pick up or drop items, place or break a block, come back home.
-- It is not a miner: big jobs are left to the Mine Army.
--
-- One-time setup (see README):
--   buddy key <your xAI API key>   saves the key in grok.key on this turtle (never in the repo)
--   buddy setup [name]             names the turtle, writes startup.lua, this spot = home
-- Then:
--   buddy                 start chatting (type at the turtle, or in game chat with a chat box)
--   buddy model <id>      pick the Grok model (default grok-4)
--   buddy models          list the models your key can use
--   buddy home            after putting it back on its home spot by hand: reset position
--
-- While chatting: /reset forgets the conversation, /quit stops.
-- Needs: http enabled in the CC config. Optional: a Chat Box (Advanced Peripherals)
-- equipped on the turtle, so you can talk to it in Minecraft chat ("buddy, come here").

local CFG_FILE, STATE_FILE, KEY_FILE = "buddy.cfg", "buddy.state", "grok.key"
local API = "https://api.x.ai/v1/"

local MAX_ROUNDS = 10    -- tool-call rounds per message before it has to answer
local MAX_STEPS = 16     -- blocks per move command
local MAX_HISTORY = 30   -- messages kept in the conversation
local TIMEOUT = 120      -- seconds to wait for Grok

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
  model = "grok-4",
  range = 32,          -- never further than this many blocks from home (any axis)
  personality = "Cheerful, a little cheeky, loves helping out.",
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

local function goHome()
  while #state.path > 1 do
    local p, t = pos(), state.path[#state.path - 1]
    local ok, why
    if t.y > p.y then ok, why = step("up")
    elseif t.y < p.y then ok, why = step("down")
    else
      local f
      for i = 0, 3 do if DX[i] == t.x - p.x and DZ[i] == t.z - p.z then f = i end end
      if not f then return false, "lost track of the way home, put me back by hand and run: buddy home" end
      if f == (state.facing + 2) % 4 and turtle.back() then
        arrive(t); ok = true
      else
        face(f)
        ok, why = step("forward")
      end
    end
    if not ok then return false, "stuck on the way home (" .. why .. "), " .. where() end
  end
  face(0)
  return true, "home"
end

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

-- ---------------------------------------------------------------- tools for Grok

local SIDE = { type = "string", enum = { "front", "up", "down" }, description = "front = the block in front of you" }
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
  side = SIDE,
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
  side = SIDE,
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
  side = SIDE,
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

tool("pick_up", "Take items from a chest/container on that side, or pick up items lying there.", {
  side = SIDE,
  count = { type = "integer", description = "max items, leave out for a full stack" },
}, { "side" }, function(a)
  local before = 0
  for s = 1, 16 do before = before + turtle.getItemCount(s) end
  local n = tonumber(a.count)
  local ok = SIDE_FN.suck[a.side](n and math.max(1, math.min(64, n)) or nil)
  local after = 0
  for s = 1, 16 do after = after + turtle.getItemCount(s) end
  return ok and ("picked up " .. (after - before) .. " items") or "nothing to pick up there"
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

tool("set_home", "Make the spot where you are now (and your current facing) your new home.", nil, nil, function()
  state = { facing = 0, path = { { x = 0, y = 0, z = 0 } } }
  saveState()
  return "this is home now"
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

-- ---------------------------------------------------------------- Grok API

local function apiKey()
  local key = readFile(KEY_FILE)
  return key and key:gsub("%s+", "") or nil
end

local function request(method, path, body)
  local req = {
    url = API .. path,
    method = method,
    body = body,
    headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. apiKey() },
    timeout = TIMEOUT,
  }
  local res, err, errRes
  if body then res, err, errRes = http.post(req) else res, err, errRes = http.get(req) end
  if not res then
    local detail = errRes and errRes.readAll() or ""
    if errRes then errRes.close() end
    local data = textutils.unserializeJSON(detail)
    if type(data) == "table" then detail = data.error and (data.error.message or data.error) or data.message or detail end
    return nil, ascii(tostring(err) .. " " .. tostring(detail)):sub(1, 300)
  end
  local text = res.readAll()
  res.close()
  local data = textutils.unserializeJSON(text)
  if not data then return nil, "could not read Grok's answer" end
  return data
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
    .. "- After doing something, say briefly what you did or what went wrong.\n"
    .. "Right now: Minecraft time %s on day %d, fuel %s, %s.")
    :format(cfg.name, who or "the player", cfg.personality, cfg.range,
      textutils.formatTime(os.time(), true), os.day(), fuelText(), where())
end

local history = {}

local function trimHistory()
  while #history > MAX_HISTORY do
    table.remove(history, 1)
    -- never start in the middle of a tool exchange
    while history[1] and history[1].role ~= "user" do table.remove(history, 1) end
  end
end

-- Send one player message to Grok, run the tools it asks for, return its answer
local function chat(text, who, onAction)
  history[#history + 1] = { role = "user", content = ascii(text) }
  for _ = 1, MAX_ROUNDS do
    local messages = { { role = "system", content = systemPrompt(who) } }
    for _, m in ipairs(history) do messages[#messages + 1] = m end
    local data, err = request("POST", "chat/completions", textutils.serializeJSON({
      model = cfg.model, messages = messages, tools = tools,
    }))
    if not data then
      table.remove(history) -- forget the message so a retry starts clean
      if err:lower():find("model") then err = err .. " (try: buddy models)" end
      return nil, err
    end
    local msg = data.choices and data.choices[1] and data.choices[1].message
    if not msg then return nil, "empty answer from Grok" end
    local calls = msg.tool_calls
    if not calls or #calls == 0 then
      local answer = ascii(msg.content)
      history[#history + 1] = { role = "assistant", content = answer }
      trimHistory()
      return answer
    end
    history[#history + 1] = { role = "assistant", content = ascii(msg.content), tool_calls = calls }
    for _, call in ipairs(calls) do
      local fn = call["function"] or {}
      if onAction then onAction(fn.name, fn.arguments) end
      history[#history + 1] = { role = "tool", tool_call_id = call.id, content = ascii(runTool(fn.name, fn.arguments)) }
    end
  end
  history[#history + 1] = { role = "assistant", content = "(I did a lot of things in a row, so I stopped to check in.)" }
  trimHistory()
  return "I did a lot of things in a row, so I stopped. Want me to keep going?"
end

-- ---------------------------------------------------------------- commands

local args = { ... }
local cmd = args[1]

if cmd == "key" then
  if not args[2] then print("Usage: buddy key <your xAI API key>") return end
  writeFile(KEY_FILE, args[2])
  print("Key saved in " .. KEY_FILE .. ". Keep that file to yourself.")
  return
elseif cmd == "setup" then
  if args[2] then cfg.name = args[2] end
  os.setComputerLabel(cfg.name)
  saveCfg()
  state = { facing = 0, path = { { x = 0, y = 0, z = 0 } } }
  saveState()
  writeFile("startup.lua", 'shell.run("buddy")\n')
  print(cfg.name .. " is set up and this spot is home. It starts by itself from now on.")
  if not apiKey() then print("Still needed: buddy key <your xAI API key>") end
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
elseif cmd == "name" and args[2] then
  cfg.name = args[2]
  os.setComputerLabel(cfg.name)
  saveCfg()
  print("Name: " .. cfg.name)
  return
end

if not http then print("http is disabled in the ComputerCraft config.") return end
if not apiKey() then print("No API key yet. Get one at console.x.ai, then: buddy key <key>") return end

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
  if not answer then reply("I can't reach Grok right now: " .. err) return end
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

term.clear()
term.setCursorPos(1, 1)
print(cfg.name .. " (Grok: " .. cfg.model .. ") - fuel " .. fuelText())
print(chatBox and ("Talk here, or in chat: \"" .. cfg.name .. ", ...\"") or "Talk to me here.")
print("/reset forgets the chat, /quit stops.")
parallel.waitForAny(terminalLoop, chatLoop)
