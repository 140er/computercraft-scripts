local palette = {}
for i, name in ipairs({ "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
  "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }) do palette[name] = 2 ^ (i - 1) end
local env = setmetatable({ colors = palette }, { __index = _G })
local V = assert(loadfile("fleetview.lua", "t", env))()
local function check(width, height, measured)
  local gpu, synced, texts = {}, 0, {}
  local gl = setmetatable({}, { __index = function() return function() end end })
  function gpu.refreshSize() end
  function gpu.setSize(n) assert(n == 64) end
  function gpu.getSize() return width, height end
  function gpu.createWindow3D() return gl end
  if measured then
    function gpu.getTextLength(text, size, padding) return #text * (5 + (padding or 1)) * (size or 1) end
  end
  function gpu.filledRectangle(x, y, w, h)
    assert(x >= 1 and y >= 1 and x <= width and y <= height, "Tom rectangle origin outside canvas")
    assert(w > 0 and h > 0, "empty rectangle")
  end
  function gpu.drawText(x, y, text, fg, bg, size, padding)
    local length = gpu.getTextLength and gpu.getTextLength(text, size, padding) or #text * 6 * (size or 1)
    assert(x >= 1 and x - 1 + length <= width, "Tom text outside canvas")
    assert(y >= 1 and y - 1 + 8 * (size or 1) <= height, "Tom text below canvas")
    texts[#texts + 1] = text
  end
  function gpu.sync() synced = synced + 1 end
  local g = assert(V.gpuOpen(gpu))
  V.gpuDraw(g, { { id = 1, name = string.rep("Miner", 40), kind = "miner", state = "idle", x = 0, y = 64, z = 0 } },
    { title = string.rep("Fleet title ", 30) })
  assert(synced == 1 and #g.buttons == 9, "all nine controls remain available")
  local actions = { "left", "right", "up", "down", "in", "out", "auto", "reset", "flip" }
  for i, button in ipairs(g.buttons) do
    assert(button[1] >= 1 and button[2] <= width and button[1] <= button[2], "button fits monitor")
    assert(button[3] == actions[i], "button keeps action")
    if i > 1 then assert(button[1] > g.buttons[i - 1][2], "controls do not overlap") end
    assert(V.gpuTouch(g, button[1], height - 8) == actions[i], "drawn button invokes its action")
  end
  if width == 640 then
    assert(g.buttons[1][1] == 4 and g.buttons[1][2] == 31, "wide control layout preserved")
    local full = false
    for _, text in ipairs(texts) do if text == "RESET" then full = true end end
    assert(full, "wide controls retain full labels")
  end
end
check(64, 64, true)
check(640, 192, true)
check(64, 64, false)
check(640, 192, false)
print("Tom narrow and wide monitor controls passed")
