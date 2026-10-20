return function(test, read, mocks)
  -- Names checked against the mods this pack runs.
  -- CC:Tweaked mc-1.21.x getType and PeripheralType.ofAdditional("inventory").
  -- cc_ar getType is ar_controller (docs/gemini-review.md:90).
  -- Tom's GPU type is tm_gpu (docs/gemini-review.md:98).
  -- Advanced Peripherals dev/1.21.1 ChatBoxPeripheral.PERIPHERAL_TYPE is chat_box.
  local allowed = {
    modem = true, monitor = true, drive = true, workbench = true, inventory = true,
    ar_controller = true, tm_gpu = true, chat_box = true,
  }
  local renamed = {
    chatBox = "chat_box", geoScanner = "geo_scanner", playerDetector = "player_detector",
    arController = "ar_controller", environmentDetector = "environment_detector",
    inventoryManager = "inventory_manager", blockReader = "block_reader",
    energyDetector = "energy_detector", meBridge = "me_bridge", rsBridge = "rs_bridge",
    nbtStorage = "nbt_storage",
  }

  local function production()
    local names, pipe = {}, io.popen("ls -1 *.lua")
    for name in pipe:lines() do names[#names + 1] = name end
    pipe:close()
    table.sort(names)
    return names
  end

  local function lookups(code)
    local found = {}
    local function add(kind) found[#found + 1] = kind end
    for kind in code:gmatch('peripheral%.find%s*%(%s*"([%w_]+)"') do add(kind) end
    for kind in code:gmatch('peripheral%.hasType%s*%(%s*[^,\n]+,%s*"([%w_]+)"') do add(kind) end
    for kind in code:gmatch('getType%s*%b()%s*==%s*"([%w_]+)"') do add(kind) end
    return found
  end

  test("peripheral lookups use the registered type names", function()
    local bad = {}
    for _, name in ipairs(production()) do
      for _, kind in ipairs(lookups(read(name))) do
        if renamed[kind] then
          bad[#bad + 1] = name .. " looks up " .. kind .. ", registered name is " .. renamed[kind]
        elseif not allowed[kind] then
          bad[#bad + 1] = name .. " looks up unregistered type " .. kind
        end
      end
    end
    assert(#bad == 0, table.concat(bad, "\n"))
  end)

  test("buddy binds a chat_box and does not ask for chatBox", function()
    local m = mocks.new(false)
    local env = m.env
    local asked = {}
    local box = {}
    env.colours = env.colors
    env.http = {}
    env.write = function() end
    env.read = function() return "/quit" end
    env.term.clear = function() end
    env.term.setCursorPos = function() end
    env.term.isColour = function() return false end
    env.term.setTextColour = function() end
    env.turtle = { getFuelLevel = function() return 0 end }
    env.peripheral.find = function(kind)
      asked[#asked + 1] = kind
      if kind == "chat_box" then return box end
    end
    m.files["buddy.cfg"] = mocks.encode({
      name = "Buddy", servers = { "http://model.local/v1/" }, model = "auto",
      range = 32, personality = "plain", think = false,
    })
    m.start(read("buddy.lua"))
    local saw = {}
    for _, kind in ipairs(asked) do saw[kind] = true end
    assert(saw.chat_box, "buddy never called peripheral.find(\"chat_box\"), asked " .. table.concat(asked, ","))
    assert(not saw.chatBox, "buddy still calls peripheral.find(\"chatBox\")")
    local text = table.concat(m.output, "\n")
    assert(text:find("Talk here, or in chat:", 1, true), "chat box was not bound\n" .. text)
    assert(not text:find("Talk to me here.", 1, true), "chat box lookup missed the attached chat_box\n" .. text)
  end)
end
