local D = dofile("depth-result.lua")
local Craft = dofile("wh2-craft.lua")
local Recipes = dofile("wh2-recipes.lua")
local Warehouse = dofile("warehouse-tasks.lua")
local checks = {}

local function check(name, ok, err)
  D.check(checks, name, ok, err)
  if not ok then error(name .. ": " .. tostring(err), 0) end
end

local function ctx(now, extra)
  local context = {
    now = now or 10000, epoch = 3,
    config = { enabled = true, operators = { ["17"] = true }, recipeHubId = 5 },
    settings = { crafting = true },
  }
  if extra then
    for key, value in pairs(extra) do context[key] = value end
  end
  return context
end

local function call(state, sender, op, body, context)
  return Craft.run(state, sender, { op = op, body = body }, context or ctx())
end

local function step(id, item, recipe, needs)
  return {
    id = id, recipeId = recipe or ("minecraft:" .. item:match(":(.+)$")),
    type = "minecraft:smelting", batches = 1, machineLocationId = false,
    needs = needs or {}, state = "pending", outputItem = item, pattern = false,
    ingredients = {
      { item = "minecraft:sand", nbt = false, perBatch = 1, orderKey = false, line = false },
    },
  }
end

local function recipe(id, typeName, inputs, output, count, chance)
  return {
    id = id, type = typeName, inputs = inputs,
    outputs = { { item = output, count = count or 1, chance = chance or 1 } },
    pattern = false,
  }
end

local function findMissing(rows, item)
  for _, row in ipairs(rows or {}) do
    if row.item == item then return row end
  end
end

local function findStep(steps, item)
  for _, row in ipairs(steps or {}) do
    if row.outputItem == item then return row end
  end
end

local function phase()
  if not fs.exists("craft-phase") then return "" end
  local handle = fs.open("craft-phase", "r")
  local text = handle.readAll()
  handle.close()
  return text
end

local function setPhase(text)
  local handle = fs.open("craft-phase", "w")
  handle.write(text)
  handle.close()
end

local catalog = {
  generation = "hub:5:boot:cat",
  tags = { ["minecraft:planks"] = { "minecraft:birch_planks", "minecraft:oak_planks" } },
  recipes = {
    ["minecraft:glass"] = recipe("minecraft:glass", "minecraft:smelting",
      { { count = 1, item = "minecraft:sand" } }, "minecraft:glass"),
    ["minecraft:red_stained_glass"] = recipe("minecraft:red_stained_glass", "minecraft:crafting", {
      { count = 8, item = "minecraft:glass" },
      { count = 1, item = "minecraft:red_dye" },
    }, "minecraft:red_stained_glass", 8),
    ["minecraft:red_stained_glass_pane"] = recipe("minecraft:red_stained_glass_pane", "minecraft:crafting",
      { { count = 6, item = "minecraft:red_stained_glass" } }, "minecraft:red_stained_glass_pane", 16),
    ["minecraft:a_glass"] = recipe("minecraft:a_glass", "minecraft:smelting",
      { { count = 1, item = "minecraft:sand" } }, "minecraft:choice_glass"),
    ["minecraft:b_glass"] = recipe("minecraft:b_glass", "minecraft:smelting",
      { { count = 2, item = "minecraft:sand" } }, "minecraft:choice_glass"),
    ["minecraft:oak_planks"] = recipe("minecraft:oak_planks", "minecraft:crafting",
      { { count = 1, item = "minecraft:oak_log" } }, "minecraft:oak_planks", 4),
    ["minecraft:stick"] = recipe("minecraft:stick", "minecraft:crafting",
      { { count = 2, tag = "minecraft:planks" } }, "minecraft:stick", 4),
    ["minecraft:loop_a"] = recipe("minecraft:loop_a", "minecraft:crafting",
      { { count = 1, item = "minecraft:loop_b" } }, "minecraft:loop_a"),
    ["minecraft:loop_b"] = recipe("minecraft:loop_b", "minecraft:crafting",
      { { count = 1, item = "minecraft:loop_a" } }, "minecraft:loop_b"),
    ["minecraft:lucky"] = recipe("minecraft:lucky", "minecraft:smelting",
      { { count = 1, item = "minecraft:gravel" } }, "minecraft:flint", 1, 0.1),
    ["create:mix"] = recipe("create:mix", "create:mixing",
      { { count = 1, item = "minecraft:sand" } }, "create:mixed"),
    ["createaddition:rolling"] = recipe("createaddition:rolling", "createaddition:rolling",
      { { count = 1, item = "minecraft:iron_ingot" } }, "createaddition:iron_rod"),
    ["mekanism:enriching"] = recipe("mekanism:enriching", "mekanism:enriching",
      { { count = 1, item = "mekanism:dust_iron" } }, "mekanism:enriched_iron"),
  },
}

local function plan(output, count, stock, choices, adapters)
  return Recipes.plan({
    output = { item = output, count = count, nbt = false },
    catalog = catalog, stock = stock or {}, recipeChoices = choices or {}, adapters = adapters,
  })
end

if phase() ~= "reboot" then
  check("craft limits replace the old caps", Craft.limits.jobs == 98304 and Craft.limits.plan == 65536 and Craft.limits.steps == 128,
    "jobs " .. tostring(Craft.limits.jobs))
  local panes = plan("minecraft:red_stained_glass_pane", 32, { ["minecraft:sand"] = 64, ["minecraft:red_dye"] = 64 })
  local missingDye = findMissing(panes.missing, "minecraft:red_dye")
  check("panes with sand and dye have no missing dye", missingDye == nil, missingDye and missingDye.count)
  local short = plan("minecraft:red_stained_glass_pane", 32, { ["minecraft:sand"] = 1000 })
  local dye = findMissing(short.missing, "minecraft:red_dye")
  check("missing red dye is reported", dye and dye.count == 2, dye and dye.count)
  local picked = plan("minecraft:choice_glass", 1, { ["minecraft:sand"] = 5 })
  local pickedStep = findStep(picked.steps, "minecraft:choice_glass")
  check("two recipes select a_glass", pickedStep and pickedStep.recipeId == "minecraft:a_glass", pickedStep and pickedStep.recipeId)
  local chosen = plan("minecraft:choice_glass", 1, { ["minecraft:sand"] = 5 },
    { ["minecraft:choice_glass"] = "minecraft:b_glass" })
  local chosenStep = findStep(chosen.steps, "minecraft:choice_glass")
  check("selected recipe id is recorded", chosenStep and chosenStep.recipeId == "minecraft:b_glass", chosenStep and chosenStep.recipeId)
  local tagged = plan("minecraft:stick", 4, { ["minecraft:oak_planks"] = 10, ["minecraft:birch_planks"] = 10 })
  local tagStep = findStep(tagged.steps, "minecraft:stick")
  check("stocked tag member is selected", tagStep and tagStep.ingredients[1].item == "minecraft:birch_planks",
    tagStep and tagStep.ingredients[1].item)
  local chance = plan("minecraft:flint", 1, { ["minecraft:gravel"] = 8 })
  check("chance_only blocks", chance.unresolved[1] and chance.unresolved[1].code == "chance_only",
    chance.unresolved[1] and chance.unresolved[1].code)
  local cycle = plan("minecraft:loop_a", 1, {})
  check("cycle reports its path", cycle.unresolved[1] and cycle.unresolved[1].code == "cycle"
    and cycle.unresolved[1].path and cycle.unresolved[1].path[1].kind == "item",
    cycle.unresolved[1] and cycle.unresolved[1].code)
  local createMix = plan("create:mixed", 1, { ["minecraft:sand"] = 4 })
  check("create mix is unsupported", createMix.unresolved[1] and createMix.unresolved[1].code == "adapter_unsupported",
    createMix.unresolved[1] and createMix.unresolved[1].code)
  local rod = plan("createaddition:iron_rod", 1, {})
  check("create addition reports the missing ingot", findMissing(rod.missing, "minecraft:iron_ingot") ~= nil,
    "iron ingot was not listed")
  local enriched = plan("mekanism:enriched_iron", 1, { ["mekanism:dust_iron"] = 4 })
  check("mekanism enriching plans from stocked dust", findStep(enriched.steps, "mekanism:enriched_iron") ~= nil
    and #(enriched.unresolved or {}) == 0, enriched.unresolved[1] and enriched.unresolved[1].code)

  local state = {}
  local created = call(state, 17, "wh2-craft", {
    action = "create", key = "board:17:panes",
    output = { item = "minecraft:red_stained_glass_pane", count = 32 },
    outputLocationId = "warehouse-out",
  })
  check("pane job created", created.ok == true, created.error)
  local steps = {}
  for n = 1, 9 do
    steps[n] = step(n, "minecraft:glass", "minecraft:glass", n > 1 and { n - 1 } or {})
    steps[n].outputItem = n == 9 and "minecraft:red_stained_glass_pane" or "minecraft:glass"
  end
  local uploaded = call(state, 5, "wh2-craft", {
    action = "plan", jobId = created.job.id, baseRevision = created.job.revision,
    generation = "hub:5:boot:cat", offset = 0, final = true, steps = steps,
  })
  check("nine step plan is admitted", uploaded.ok == true and uploaded.job and #uploaded.job.steps == 9, uploaded.error)
  local admitted = #textutils.serialize(uploaded.job)
  local claim = call(state, 21, "wh2-craft", { action = "claim", jobId = uploaded.job.id, boot = "boot:21" })
  check("worker claims the job", claim.ok == true, claim.error)
  local progress = call(state, 21, "wh2-craft", {
    action = "progress", jobId = uploaded.job.id, token = claim.token, epoch = claim.epoch,
    boot = "boot:21", eventId = "cp:21:1", seq = 1, stepId = 1, state = "running",
    observed = { locationId = "furnace-1", item = "minecraft:glass", count = 6, delivered = 0, stockRevision = 8 },
  })
  check("first progress is stored", progress.ok == true, progress.error)
  local produced = progress.job.produced
  local delivered = progress.job.delivered

  local function pose() return true end
  local warehouse = { sites = {}, orders = {}, locks = {}, raised = true }
  for n = 1, 33 do
    warehouse.sites["source-" .. n] = {
      kind = "source", side = "front", pose = { x = n, y = 65, z = 0, h = 0 },
    }
  end
  warehouse.sites["drop-main"] = { kind = "drop", side = "front", pose = { x = 0, y = 65, z = 2, h = 0 } }
  local lines = {}
  for n = 1, 9 do
    lines[n] = { item = "minecraft:sand", source = "source-1", wanted = 1, count = 0, picked = 0, delivered = 0, nbt = "fp-" .. n }
  end
  for n = 1, 33 do
    warehouse.orders["order-" .. n] = {
      key = "order-" .. n, drop = "drop-main", status = "open", lines = lines,
    }
  end
  check("33 sites, 33 orders, and 9 lines are admitted", Warehouse.valid(warehouse, pose) == true, "warehouse load rejected")
  local warehouseBytes = #textutils.serialize(warehouse)
  local record = {
    panes = 32, admitted = admitted, warehouseBytes = warehouseBytes,
    selected = chosenStep.recipeId, fingerprint = textutils.serialize(chosenStep, { compact = true }),
    produced = produced, delivered = delivered, transport = 1,
  }
  local handle = fs.open("craft-record.json", "w")
  handle.write(textutils.serializeJSON(record))
  handle.close()
  handle = fs.open("craft-state", "w")
  handle.write(textutils.serialize(state))
  handle.close()
  setPhase("reboot")
  handle = fs.open("craft-ready", "w")
  handle.write("reboot")
  handle.close()
  return
end

local handle = fs.open("craft-state", "r")
local state = textutils.unserialize(handle.readAll())
handle.close()
handle = fs.open("craft-record.json", "r")
local record = textutils.unserializeJSON(handle.readAll())
handle.close()
local jobId = nil
for id in pairs(state.wh2.craft.jobs) do jobId = id break end
local job = state.wh2.craft.jobs[jobId]
local again = call(state, 21, "wh2-craft", {
  action = "progress", jobId = jobId, token = job.token, epoch = job.epoch,
  boot = "boot:21", eventId = "cp:21:1", seq = 1, stepId = 1, state = "running",
  observed = { locationId = "furnace-1", item = "minecraft:glass", count = 6, delivered = 0, stockRevision = 8 },
})
record.transport = record.transport + 1
check("reboot keeps produced and delivered", again.duplicate == true
  and again.job.produced == record.produced and again.job.delivered == record.delivered
  and record.transport == 2, again.error or "totals changed")
handle = fs.open("craft-record.json", "w")
handle.write(textutils.serializeJSON(record))
handle.close()
handle = fs.open("expected-panes.txt", "w")
handle.write("32")
handle.close()
D.finish(checks)
